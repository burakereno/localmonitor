import Foundation
import Testing
@testable import LocalMonitor

struct ProjectServiceDependencyTests {
    @Test func ordersSharedDependenciesOnceAndRejectsCyclesAndRemovedProjects() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let database = fixture.project()
        var api = fixture.project(), frontend = fixture.project()
        api.reliability.dependencyProjectIDs = [database.id]
        frontend.reliability.dependencyProjectIDs = [api.id, database.id]
        let ordered = try ProjectDependencyGraph.order(for: frontend, projects: [frontend, api, database])
        #expect(ordered.map(\.id) == [database.id, api.id, frontend.id])
        api.reliability.dependencyProjectIDs = [frontend.id]
        #expect(throws: ProjectReliabilityError.self) { try ProjectDependencyGraph.order(for: frontend, projects: [frontend, api, database]) }
        #expect(throws: ProjectReliabilityError.self) { try ProjectDependencyGraph.order(for: frontend, projects: [frontend]) }
    }

    @Test func waitsForActualReadinessAndHasADeadline() async throws {
        var attempts = 0
        try await ProjectDependencyGraph.waitUntilReady(timeout: 1, interval: .milliseconds(5)) { attempts += 1; return attempts >= 3 }
        #expect(attempts == 3)
        await #expect(throws: ProjectReliabilityError.self) {
            try await ProjectDependencyGraph.waitUntilReady(timeout: 0.02, interval: .milliseconds(5)) { false }
        }
    }

    @Test func readinessWaitCanBeCancelled() async throws {
        let task = Task { try await ProjectDependencyGraph.waitUntilReady(timeout: 30, interval: .milliseconds(10)) { false } }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { #expect(task.isCancelled) }
    }

    @Test func composeRequiresDeclaredHealthyServices() throws {
        let good = Data(#"{"services":{"db":{"healthcheck":{"test":["CMD","pg_isready"]}},"redis":{}}}"#.utf8)
        try ProjectComposeServices().validate(configuration: good, services: ["db"])
        #expect(throws: ProjectReliabilityError.self) { try ProjectComposeServices().validate(configuration: good, services: ["redis"]) }
        #expect(throws: ProjectReliabilityError.self) { try ProjectComposeServices().validate(configuration: good, services: ["missing"]) }
        let disabled = Data(#"{"services":{"db":{"healthcheck":{"disable":true,"test":["NONE"]}}}}"#.utf8)
        #expect(throws: ProjectReliabilityError.self) { try ProjectComposeServices().validate(configuration: disabled, services: ["db"]) }
    }

    @Test @MainActor func startsBackendAndWaitsForReadinessBeforeFrontend() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write("api/package.json", "{}")
        try fixture.write("web/package.json", "{}")
        let ready = fixture.root.appendingPathComponent("api-ready")
        var api = fixture.project(), web = fixture.project()
        api.name = "api"; api.kind = .supabase; api.path = fixture.root.appendingPathComponent("api").path
        web.name = "web"; web.kind = .supabase; web.path = fixture.root.appendingPathComponent("web").path
        let script = "import time,pathlib;time.sleep(1.5);pathlib.Path(\(String(reflecting: ready.path))).touch();time.sleep(30)"
        api.commandTemplate = "/usr/bin/python3 -u -c \(ProjectNodeRuntime.quote(script))"
        web.commandTemplate = "if [ -f \(ProjectNodeRuntime.quote(ready.path)) ]; then echo FRONT_READY; else exit 13; fi"
        web.reliability.dependencyProjectIDs = [api.id]
        let store = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("projects"))
        store.save(.init(projects: [web, api]))
        let suite = "ServiceOrder-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProjectProcessManager(userDefaults: defaults, storageDirectoryURL: fixture.root.appendingPathComponent("logs"))
        let model = LocalMonitorModel(store: store, healthChecker: MarkerHealth(ready: ready), healthChecksEnabled: false,
                                      processManager: manager, userDefaults: defaults)
        defer { model.stopAllProjects() }
        await model.startProject(web)
        #expect(FileManager.default.fileExists(atPath: ready.path))
        #expect(manager.logLines(for: web.id).contains("FRONT_READY"))
        #expect(manager.isRunning(projectId: api.id))
    }
}

private struct MarkerHealth: HealthChecking {
    let ready: URL
    func check(_ project: LocalProject) async -> HealthState {
        FileManager.default.fileExists(atPath: ready.path) ? .healthy(code: 200, milliseconds: 1) : .unreachable("Preparing")
    }
}
