import Foundation
import Testing
@testable import LocalMonitor

extension Tag {
    @Tag static var networking: Self
}

@MainActor
@Suite(.tags(.networking), .timeLimit(.minutes(1)))
struct ReadinessIntegrationTests {
    @Test func disabledHealthChecksNeverSendARequest() async throws {
        let checker = ScriptedHealthChecker(responses: [.unreachable("Timeout")])
        let fixture = try ReadinessFixture(checker: checker, enabled: false)
        defer { fixture.cleanup() }
        await fixture.model.checkReadiness(for: fixture.project, force: true)
        #expect(await checker.callCount == 0)
        #expect(fixture.state.status == .running)
        #expect(fixture.model.healthStates[fixture.project.id] == .unknown)
    }

    @Test func preparingAndDelayedProjectsStayOnlineUntilFailureIsConfirmed() async throws {
        let checker = ScriptedHealthChecker(responses: [
            .healthy(code: 200, milliseconds: 140),
            .unreachable("Timeout"), .unreachable("Timeout"), .unreachable("Timeout"),
            .healthy(code: 200, milliseconds: 60)
        ])
        let fixture = try ReadinessFixture(checker: checker)
        defer { fixture.cleanup() }
        #expect(fixture.state.status == .warmingUp)
        #expect(fixture.model.isProjectOnlineForGrouping(fixture.project))
        await fixture.model.checkReadiness(for: fixture.project, force: true)
        #expect(fixture.state.status == .running)
        for _ in 0..<2 {
            await fixture.model.checkReadiness(for: fixture.project, force: true)
            #expect(fixture.state.status == .responseDelayed)
            #expect(fixture.model.isProjectOnlineForGrouping(fixture.project))
            #expect(fixture.model.menuBarTitle.runningCount == 1)
            #expect(fixture.model.healthStates[fixture.project.id] == .checking)
            // Port scanning must not erase the pending failures.
            fixture.model.markRunning(fixture.project, owner: fixture.owner)
            #expect(fixture.state.status == .responseDelayed)
        }
        await fixture.model.checkReadiness(for: fixture.project, force: true)
        #expect(fixture.state.status == .noResponse)
        #expect(fixture.model.isProjectOnlineForGrouping(fixture.project) == false)
        await fixture.model.checkReadiness(for: fixture.project, force: true)
        #expect(fixture.state.status == .running)
    }

    @Test func disablingChecksClearsAnExistingHTTPFailure() async throws {
        let checker = ScriptedHealthChecker(responses: [
            .healthy(code: 200, milliseconds: 10),
            .unreachable("Timeout"), .unreachable("Timeout"), .unreachable("Timeout")
        ])
        let fixture = try ReadinessFixture(checker: checker)
        defer { fixture.cleanup() }
        for _ in 0..<4 {
            await fixture.model.checkReadiness(for: fixture.project, force: true)
        }
        try #require(fixture.state.status == .noResponse)
        await fixture.model.updateHealthChecks(enabled: false)
        await fixture.model.checkReadiness(for: fixture.project, force: true)
        #expect(await checker.callCount == 4)
        #expect(fixture.state.status == .running)
        #expect(fixture.state.readiness.consecutiveFailures == 0)
        #expect(fixture.model.healthStates[fixture.project.id] == .unknown)
    }

    @Test func disablingChecksDiscardsAnInFlightFailure() async throws {
        let checker = SuspendedHealthChecker()
        let fixture = try ReadinessFixture(checker: checker)
        defer { fixture.cleanup() }
        let task = Task { await fixture.model.checkReadiness(for: fixture.project, force: true) }
        await checker.waitUntilStarted()
        await fixture.model.updateHealthChecks(enabled: false)
        await checker.finish(with: .unreachable("Timeout"))
        await task.value
        #expect(fixture.state.status == .running)
        #expect(fixture.state.readiness.consecutiveFailures == 0)
        #expect(fixture.model.healthStates[fixture.project.id] == .unknown)
    }

    @Test func aNewListenerDoesNotInheritAnOldHTTPResult() async throws {
        let checker = SuspendedHealthChecker()
        let fixture = try ReadinessFixture(checker: checker)
        defer { fixture.cleanup() }
        let task = Task { await fixture.model.checkReadiness(for: fixture.project, force: true) }
        await checker.waitUntilStarted()
        let newOwner = fixture.makeOwner(pid: 987_655)
        fixture.model.markRunning(fixture.project, owner: newOwner)
        await checker.finish(with: .healthy(code: 200, milliseconds: 10))
        await task.value
        #expect(fixture.state.pid == newOwner.pid)
        #expect(fixture.state.status == .warmingUp)
        #expect(fixture.state.readiness.hasResponded == false)
    }

    @Test func overlappingRefreshesDoNotCountAsSeparateFailures() async throws {
        let checker = SuspendedHealthChecker()
        let fixture = try ReadinessFixture(checker: checker)
        defer { fixture.cleanup() }
        let task = Task { await fixture.model.checkReadiness(for: fixture.project, force: true) }
        await checker.waitUntilStarted()
        await fixture.model.checkReadiness(for: fixture.project, force: true)
        #expect(await checker.callCount == 1)
        await checker.finish(with: .unreachable("Timeout"))
        await task.value
        #expect(fixture.state.readiness.consecutiveFailures == 1)
        #expect(fixture.state.status == .warmingUp)
    }
}

private actor ScriptedHealthChecker: HealthChecking {
    private var responses: [HealthState]
    private(set) var callCount = 0

    init(responses: [HealthState]) { self.responses = responses }

    func check(_ project: LocalProject) async -> HealthState {
        callCount += 1
        guard !responses.isEmpty else {
            Issue.record("Unexpected extra HTTP check")
            return .unreachable("Unexpected check")
        }
        return responses.removeFirst()
    }
}

private actor SuspendedHealthChecker: HealthChecking {
    private var pending: CheckedContinuation<HealthState, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func check(_ project: LocalProject) async -> HealthState {
        callCount += 1
        return await withCheckedContinuation { continuation in
            pending = continuation
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func finish(with health: HealthState) {
        pending?.resume(returning: health)
        pending = nil
    }
}

@MainActor
private final class ReadinessFixture {
    let project: LocalProject
    let model: LocalMonitorModel
    private let directory: URL
    private let defaults: UserDefaults
    private let suiteName: String

    var state: ProjectRuntimeState { model.runtimeState(for: project) }
    var owner: DiscoveredPort { makeOwner(pid: 987_654) }

    init(checker: any HealthChecking, enabled: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = "ReadinessTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        project = LocalProject(name: "readiness-fixture", path: directory.path, kind: .nextjs,
                               packageManager: .pnpm, port: 3010, commandTemplate: "pnpm dev")
        let store = ProjectStore(storageDirectoryURL: directory)
        store.save(ProjectLibrary(projects: [project]))
        model = LocalMonitorModel(
            store: store,
            healthChecker: checker,
            healthChecksEnabled: enabled,
            notificationService: NotificationService(isEnabled: { false }),
            processManager: ProjectProcessManager(userDefaults: defaults, storageDirectoryURL: directory),
            userDefaults: defaults
        )
        model.markRunning(project, owner: owner)
    }

    func makeOwner(pid: Int32) -> DiscoveredPort {
        DiscoveredPort(port: project.port, pid: pid, command: "node", user: "fixture",
                       endpoint: "*:3010", workingDirectory: project.path,
                       startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                       isIgnored: false, isManaged: false, projectId: project.id)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
