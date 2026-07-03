import Foundation
import XCTest
@testable import LocalMonitor

final class RuntimeSessionTests: XCTestCase {
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
