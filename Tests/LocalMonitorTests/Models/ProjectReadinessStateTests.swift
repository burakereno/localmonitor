import Foundation
import Testing
@testable import LocalMonitor

struct ProjectReadinessStateTests {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let timeout = HealthState.unreachable("The request timed out.")
    private let success = HealthState.healthy(code: 200, milliseconds: 140)

    @Test func firstCompilationCanFinishAfterAnInitialTimeout() {
        var readiness = ProjectReadinessState()
        readiness.begin(at: start)
        #expect(readiness.record(timeout, at: start.addingTimeInterval(5)) == .warmingUp)
        #expect(readiness.record(success, at: start.addingTimeInterval(20)) == .running)
        #expect(readiness.consecutiveFailures == 0)
    }

    @Test func startupGraceDoesNotHideAPersistentFailure() {
        var readiness = ProjectReadinessState()
        readiness.begin(at: start)
        for seconds in [5.0, 15.0, 29.9] {
            #expect(readiness.record(timeout, at: start.addingTimeInterval(seconds)) == .warmingUp)
        }
        #expect(readiness.record(timeout, at: start.addingTimeInterval(30)) == .noResponse)
    }

    @Test func expiredGraceStillRequiresThreeFailures() {
        var readiness = ProjectReadinessState()
        readiness.begin(at: start)
        #expect(readiness.record(timeout, at: start.addingTimeInterval(30)) == .responseDelayed)
        #expect(readiness.record(timeout, at: start.addingTimeInterval(45)) == .responseDelayed)
        #expect(readiness.record(timeout, at: start.addingTimeInterval(60)) == .noResponse)
    }

    @Test func healthyServerNeedsThreeConsecutiveFailures() {
        var readiness = ProjectReadinessState()
        #expect(readiness.record(success, at: start) == .running)
        for seconds in [15.0, 30.0] {
            #expect(readiness.record(timeout, at: start.addingTimeInterval(seconds)) == .responseDelayed)
        }
        #expect(readiness.record(timeout, at: start.addingTimeInterval(45)) == .noResponse)
    }

    @Test(arguments: [HealthState.healthy(code: 200, milliseconds: 60), .warning(code: 503, milliseconds: 60)])
    func anyHTTPResponseBreaksTheFailureStreak(response: HealthState) {
        var readiness = ProjectReadinessState()
        _ = readiness.record(success, at: start)
        _ = readiness.record(timeout, at: start.addingTimeInterval(15))
        _ = readiness.record(timeout, at: start.addingTimeInterval(30))
        #expect(readiness.record(response, at: start.addingTimeInterval(45)) == .running)
        #expect(readiness.record(timeout, at: start.addingTimeInterval(60)) == .responseDelayed)
        #expect(readiness.consecutiveFailures == 1)
    }

    @Test func oneSuccessfulResponseRestoresReadiness() {
        var readiness = ProjectReadinessState()
        _ = readiness.record(success, at: start)
        for seconds in [15.0, 30.0, 45.0] {
            _ = readiness.record(timeout, at: start.addingTimeInterval(seconds))
        }
        #expect(readiness.record(success, at: start.addingTimeInterval(60)) == .running)
        #expect(readiness.consecutiveFailures == 0)
    }

    @Test(arguments: [HealthState.unknown, .checking])
    func incompleteChecksDoNotCountAsFailures(health: HealthState) {
        var readiness = ProjectReadinessState()
        #expect(readiness.record(health, at: start) == nil)
        #expect(readiness.consecutiveFailures == 0)
        #expect(readiness.startedAt == nil)
    }
}
