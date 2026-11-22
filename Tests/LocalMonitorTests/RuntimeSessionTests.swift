import Foundation
import XCTest
@testable import LocalMonitor

final class RuntimeSessionTests: XCTestCase {
    private let runtimeSessionsKey = "runtimeSessionsV1"

    func testKeepsSessionStartWhenListenerPIDChangesWithinGrace() {
        let sessionStartedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let previousLastSeen = sessionStartedAt.addingTimeInterval(7_200)
        let now = previousLastSeen.addingTimeInterval(15)
        let newProcessStartedAt = previousLastSeen.addingTimeInterval(8)

        var state = ProjectRuntimeState(
            status: .running,
            pid: 100,
            startedAt: sessionStartedAt,
            processStartedAt: sessionStartedAt.addingTimeInterval(5),
            lastSeenRunningAt: previousLastSeen,
            lastMessage: nil,
            observedPort: 3000
        )

        state.syncSession(
            with: port(pid: 200, startedAt: newProcessStartedAt),
            now: now,
            continuityGrace: 120
        )

        XCTAssertEqual(state.startedAt, sessionStartedAt)
        XCTAssertEqual(state.processStartedAt, newProcessStartedAt)
        XCTAssertEqual(state.lastSeenRunningAt, now)
    }

    func testCorrectsFallbackSessionToOlderProcessStart() {
        let actualProcessStartedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let fallbackStartedAt = actualProcessStartedAt.addingTimeInterval(3_600)
        let now = fallbackStartedAt.addingTimeInterval(30)

        var state = ProjectRuntimeState(
            status: .running,
            pid: 100,
            startedAt: fallbackStartedAt,
            processStartedAt: nil,
            lastSeenRunningAt: now.addingTimeInterval(-15),
            lastMessage: nil,
            observedPort: 3000
        )

        state.syncSession(
            with: port(pid: 100, startedAt: actualProcessStartedAt),
            now: now,
            continuityGrace: 120
        )

        XCTAssertEqual(state.startedAt, actualProcessStartedAt)
        XCTAssertEqual(state.processStartedAt, actualProcessStartedAt)
    }

    func testStartsNewSessionWhenSavedSessionIsStaleAndProcessStartedLater() {
        let savedSessionStartedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let savedLastSeen = savedSessionStartedAt.addingTimeInterval(600)
        let newProcessStartedAt = savedLastSeen.addingTimeInterval(3_600)
        let now = newProcessStartedAt.addingTimeInterval(90)

        var state = ProjectRuntimeState(
            status: .stopped,
            pid: 100,
            startedAt: savedSessionStartedAt,
            processStartedAt: savedSessionStartedAt.addingTimeInterval(5),
            lastSeenRunningAt: savedLastSeen,
            lastMessage: nil,
            observedPort: 3000
        )

        state.syncSession(
            with: port(pid: 200, startedAt: newProcessStartedAt),
            now: now,
            continuityGrace: 120
        )

        XCTAssertEqual(state.startedAt, newProcessStartedAt)
        XCTAssertEqual(state.processStartedAt, newProcessStartedAt)
    }

    func testMissingProcessStartOnlyFallsBackToNowAfterGraceExpires() {
        let sessionStartedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let lastSeen = sessionStartedAt.addingTimeInterval(600)
        let now = lastSeen.addingTimeInterval(300)

        var state = ProjectRuntimeState(
            status: .running,
            pid: 100,
            startedAt: sessionStartedAt,
            processStartedAt: nil,
            lastSeenRunningAt: lastSeen,
            lastMessage: nil,
            observedPort: 3000
        )

        state.syncSession(
            with: port(pid: 200, startedAt: nil),
            now: now,
            continuityGrace: 120
        )

        XCTAssertEqual(state.startedAt, now)
        XCTAssertNil(state.processStartedAt)
    }

    func testReadsCurrentMacBootSession() throws {
        XCTAssertNotNil(SystemBootSession.current.id)
        XCTAssertLessThanOrEqual(try XCTUnwrap(SystemBootSession.current.startedAt), Date())
    }

    @MainActor
    func testRebootClearsSavedSessionEvenWithRecentListenerAndReusedPID() throws {
        try withSavedProject { store, project, defaults in
            let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let oldStart = now.addingTimeInterval(-3_600)
            let oldBoot = SystemBootSession(id: UUID(), startedAt: oldStart.addingTimeInterval(-60))
            let model = LocalMonitorModel(store: store, userDefaults: defaults, bootSession: oldBoot)
            model.markRunning(project, owner: port(pid: 100, startedAt: oldStart))

            // Overlapping wall-clock times must not override a change in boot identity.
            let newBoot = SystemBootSession(id: UUID(), startedAt: oldBoot.startedAt)
            let reopened = LocalMonitorModel(store: store, userDefaults: defaults, bootSession: newBoot)
            XCTAssertEqual(reopened.runtimeState(for: project), .stopped)
            reopened.reconcileRunningStates(now: now.addingTimeInterval(5))
            XCTAssertEqual(reopened.runtimeState(for: project), .stopped)

            reopened.markRunning(project, owner: port(pid: 100, startedAt: now))
            XCTAssertEqual(reopened.runtimeState(for: project).startedAt, now)
        }
    }

    @MainActor
    func testSameBootRelaunchKeepsUptimeButMissingListenerShowsStoppedImmediately() throws {
        try withSavedProject { store, project, defaults in
            let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let startedAt = now.addingTimeInterval(-3_600)
            let boot = SystemBootSession(id: UUID(), startedAt: startedAt.addingTimeInterval(-60))
            let first = LocalMonitorModel(store: store, userDefaults: defaults, bootSession: boot)
            first.markRunning(project, owner: port(pid: 100, startedAt: startedAt))

            let reopened = LocalMonitorModel(store: store, healthChecksEnabled: false, userDefaults: defaults, bootSession: boot)
            XCTAssertEqual(reopened.runtimeState(for: project).startedAt, startedAt)
            reopened.markRunning(project, owner: port(pid: 100, startedAt: startedAt))
            XCTAssertEqual(reopened.runtimeState(for: project).status, .running)
            XCTAssertEqual(reopened.runtimeState(for: project).startedAt, startedAt)

            reopened.reconcileRunningStates(now: now.addingTimeInterval(5))
            let stopped = reopened.runtimeState(for: project)
            XCTAssertEqual(stopped.status, .stopped)
            XCTAssertNil(stopped.pid)
            XCTAssertNil(stopped.observedPort)

            reopened.markRunning(project, owner: port(pid: 200, startedAt: now))
            XCTAssertEqual(reopened.runtimeState(for: project).startedAt, startedAt)
            reopened.reconcileRunningStates(now: now.addingTimeInterval(125))
            XCTAssertNil(reopened.runtimeState(for: project).startedAt)
        }
    }

    @MainActor
    func testLegacySessionIsRestoredOnlyIfItStartedDuringThisBoot() throws {
        try withSavedProject { store, project, defaults in
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            try saveLegacySession(for: project, startedAt: start, defaults: defaults)
            let sameBoot = SystemBootSession(id: UUID(), startedAt: start.addingTimeInterval(-10))
            let model = LocalMonitorModel(store: store, userDefaults: defaults, bootSession: sameBoot)
            XCTAssertEqual(model.runtimeState(for: project).startedAt, start)

            let newBoot = SystemBootSession(id: UUID(), startedAt: start.addingTimeInterval(32))
            let reopened = LocalMonitorModel(store: store, userDefaults: defaults, bootSession: newBoot)
            reopened.reconcileRunningStates(now: start.addingTimeInterval(35))
            XCTAssertEqual(reopened.runtimeState(for: project), .stopped)
        }
    }

    @MainActor
    func testStopAllProjectsPreservesUnownedRuntimeSessions() throws {
        try withSavedProject { store, project, defaults in
            let start = Date(timeIntervalSince1970: 1_780_000_000)
            try saveLegacySession(for: project, startedAt: start, defaults: defaults)
            let boot = SystemBootSession(id: UUID(), startedAt: start.addingTimeInterval(-60))
            let model = LocalMonitorModel(store: store, userDefaults: defaults, bootSession: boot)
            model.stopAllProjects()

            XCTAssertNotNil(defaults.data(forKey: runtimeSessionsKey))
            XCTAssertEqual(model.runtimeState(for: project).status, .stopped)
        }
    }

    @MainActor
    private func withSavedProject(_ body: (ProjectStore, LocalProject, UserDefaults) throws -> Void) throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.cleanup() }
        let suiteName = "LocalMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var project = fixture.project()
        project.port = 3000
        let store = ProjectStore(storageDirectoryURL: fixture.root)
        store.save(ProjectLibrary(projects: [project], groups: []))
        try body(store, project, defaults)
    }

    private func saveLegacySession(for project: LocalProject, startedAt: Date, defaults: UserDefaults) throws {
        let snapshot = RuntimeSessionTestSnapshot(
            startedAt: startedAt,
            processStartedAt: startedAt,
            lastSeenRunningAt: startedAt.addingTimeInterval(30),
            pid: 12345,
            observedPort: project.port
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode([project.id.uuidString: snapshot]), forKey: runtimeSessionsKey)
    }

    private func port(pid: Int32, startedAt: Date?) -> DiscoveredPort {
        DiscoveredPort(
            port: 3000,
            pid: pid,
            command: "node",
            user: "burak",
            endpoint: "*:3000",
            workingDirectory: "/Users/burakerenoglu/Documents/Projects/meetcase/web",
            inferredProjectName: "meetcase",
            commandLine: "next-server",
            startedAt: startedAt,
            pinnedName: nil,
            isIgnored: false,
            isManaged: false,
            projectId: nil,
            projectName: "meetcase"
        )
    }
}

private struct RuntimeSessionTestSnapshot: Codable {
    let startedAt: Date
    let processStartedAt: Date?
    let lastSeenRunningAt: Date?
    let pid: Int32?
    let observedPort: Int?
}
