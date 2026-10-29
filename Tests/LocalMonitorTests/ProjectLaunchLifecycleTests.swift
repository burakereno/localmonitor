import Foundation
import Testing
@testable import LocalMonitor

struct ProjectLaunchLifecycleTests {
    @Test @MainActor func stopDuringRestartPreventsTheLaterStart() async throws {
        let fixture = try LaunchLifecycleFixture(delay: 0); defer { fixture.cleanup() }
        let project = fixture.project()
        let model = fixture.model(projects: [project]); defer { model.stopAllProjects() }
        let restart = Task { await model.restartProject(project) }
        let deadline = Date().addingTimeInterval(4)
        while model.maintenanceRequests[project.id] == nil, Date() < deadline { await Task.yield() }
        try #require(model.maintenanceRequests[project.id] != nil)
        model.stopProject(project)
        await restart.value
        #expect(!fixture.started)
        #expect(model.runtimeState(for: project).status == .stopped)
        #expect(model.cleanRestartStates[project.id] == nil)
    }

    @Test @MainActor func installCannotRaceAProjectPreflightInTheSameWorkspace() async throws {
        let fixture = try LaunchLifecycleFixture(); defer { fixture.cleanup() }
        let one = fixture.project(), sibling = fixture.project()
        let model = fixture.model(projects: [one, sibling]); defer { model.stopAllProjects() }
        let launch = Task { await model.startProject(one) }
        try await fixture.waitForProbe()
        await model.installDependencies(for: sibling)
        if case .failed(let message) = model.installationStates[sibling.id] {
            #expect(message.contains("Stop projects sharing"))
        } else { Issue.record("An active preflight must prevent shared dependency installation") }
        model.stopAllProjects()
        await launch.value
        #expect(!fixture.started)
    }

    @Test(arguments: ["stop", "remove", "stopAll", "edit"])
    @MainActor func cancelledPreflightCannotStartAProcess(_ action: String) async throws {
        let fixture = try LaunchLifecycleFixture(); defer { fixture.cleanup() }
        let project = fixture.project()
        let model = fixture.model(projects: [project])
        defer { model.stopAllProjects() }
        let launch = Task { await model.startProject(project) }
        try await fixture.waitForProbe()
        switch action {
        case "stop": model.stopProject(project)
        case "remove": model.removeProject(project)
        case "stopAll": model.stopAllProjects()
        default: model.updateCommandTemplate(for: project, command: "/bin/sleep 20")
        }
        await launch.value
        #expect(!fixture.started)
        #expect(!model.processManager.isRunning(projectId: project.id))
        #expect(model.projectLaunchRequests.isEmpty)
        if action == "remove" { #expect(model.runtimeStates[project.id] == nil) }
    }

    @Test @MainActor func stopAllAlsoCancelsTheRestOfABatch() async throws {
        let fixture = try LaunchLifecycleFixture(); defer { fixture.cleanup() }
        let one = fixture.project(), two = fixture.project()
        let model = fixture.model(projects: [one, two]); defer { model.stopAllProjects() }
        let batch = Task { await model.startAllProjects() }
        try await fixture.waitForProbe()
        model.stopAllProjects()
        await batch.value
        #expect(!fixture.started)
        #expect(!model.processManager.isRunning(projectId: one.id))
        #expect(!model.processManager.isRunning(projectId: two.id))
    }

    @Test(arguments: [false, true]) @MainActor func stoppingADependencyCancelsItsPendingParentChain(_ cancelCaller: Bool) async throws {
        let fixture = try LaunchLifecycleFixture(); defer { fixture.cleanup() }
        let api = fixture.project()
        var web = fixture.project()
        web.reliability.dependencyProjectIDs = [api.id]
        let model = fixture.model(projects: [web, api]); defer { model.stopAllProjects() }
        let launch = Task { await model.startProject(web) }
        try await fixture.waitForProbe()
        if cancelCaller { launch.cancel() } else { model.stopProject(api) }
        await launch.value
        #expect(!fixture.started)
        #expect(model.runtimeState(for: web).status == .stopped)
        #expect(model.dependencyLaunchTasks.isEmpty)
    }

    @Test @MainActor func oldStopVerificationCannotOverwriteANewerStart() async throws {
        let fixture = try LaunchLifecycleFixture(delay: 0); defer { fixture.cleanup() }
        let project = fixture.project()
        let model = fixture.model(projects: [project]); defer { model.stopAllProjects() }
        model.stopProject(project)
        await model.startProject(project)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.processManager.isRunning(projectId: project.id))
        #expect(model.runtimeState(for: project).status != .stopped)
        #expect(model.stopVerificationTasks.isEmpty)
    }
}

@MainActor
private final class LaunchLifecycleFixture {
    let files: ReliabilityFixture
    let defaults: UserDefaults
    let suite = "LaunchReview-\(UUID().uuidString)"
    let bin: URL

    init(delay: Double = 0.5) throws {
        files = try ReliabilityFixture()
        defaults = try #require(UserDefaults(suiteName: suite))
        bin = files.root.appendingPathComponent("tools")
        try files.write("package.json", "{}")
        try files.write(".node-version", "24\n")
        let info = try JSONSerialization.data(withJSONObject: ["version": "24.21.0", "executable": bin.appendingPathComponent("node").path])
        try files.write("tools/node", """
        #!/bin/sh
        /usr/bin/touch \(ProjectNodeRuntime.quote(files.root.appendingPathComponent("probing").path))
        /bin/sleep \(delay)
        printf '%s\\n' \(ProjectNodeRuntime.quote(String(decoding: info, as: UTF8.self)))

        """, executable: true)
    }

    func project() -> LocalProject {
        var project = files.project()
        project.kind = .supabase
        project.commandTemplate = "/usr/bin/touch \(ProjectNodeRuntime.quote(files.root.appendingPathComponent("started").path)); exec /bin/sleep 30"
        return project
    }

    func model(projects: [LocalProject]) -> LocalMonitorModel {
        let store = ProjectStore(storageDirectoryURL: files.root.appendingPathComponent("projects"))
        store.save(.init(projects: projects))
        let checker = PreflightChecker(nodeRuntimeResolver: .init(candidateDirectories: [bin]))
        let manager = ProjectProcessManager(userDefaults: defaults, storageDirectoryURL: files.root.appendingPathComponent("logs"))
        return LocalMonitorModel(store: store, preflightChecker: checker, healthChecksEnabled: false,
                                 processManager: manager, userDefaults: defaults)
    }

    var started: Bool { FileManager.default.fileExists(atPath: files.root.appendingPathComponent("started").path) }

    func waitForProbe() async throws {
        let deadline = Date().addingTimeInterval(4)
        while !FileManager.default.fileExists(atPath: files.root.appendingPathComponent("probing").path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: files.root.appendingPathComponent("probing").path))
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite); files.cleanup() }
}
