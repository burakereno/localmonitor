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

    @MainActor
    func testStopAllProjectsClearsPersistedRuntimeSessions() throws {
        let suiteName = "LocalMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let projectID = UUID()
        let project = LocalProject(
            id: projectID,
            name: "meetcase",
            path: tempURL.appendingPathComponent("meetcase/web", isDirectory: true).path,
            kind: .nextjs,
            packageManager: .pnpm,
            port: 3000,
            commandTemplate: "pnpm dev -p {port}"
        )
        let store = ProjectStore(storageDirectoryURL: tempURL)
        store.save(ProjectLibrary(projects: [project], groups: []))

        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = RuntimeSessionTestSnapshot(
            startedAt: startedAt,
            processStartedAt: startedAt,
            lastSeenRunningAt: startedAt.addingTimeInterval(30),
            pid: 12345,
            observedPort: 3000
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode([projectID.uuidString: snapshot]),
            forKey: runtimeSessionsKey
        )

        let model = LocalMonitorModel(store: store, userDefaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: runtimeSessionsKey))

        model.stopAllProjects()

        XCTAssertNil(defaults.data(forKey: runtimeSessionsKey))
        XCTAssertEqual(model.runtimeState(for: project).status, .stopped)
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
