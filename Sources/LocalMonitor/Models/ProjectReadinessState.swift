import Foundation

/// Tracks HTTP readiness independently of the lifetime of a listening process.
struct ProjectReadinessState: Equatable {
    static let startupGraceInterval: TimeInterval = 30
    static let failureThreshold = 3

    private(set) var startedAt: Date?
    private(set) var hasResponded = false
    private(set) var consecutiveFailures = 0

    mutating func begin(at date: Date) {
        if startedAt == nil {
            startedAt = date
        }
    }

    mutating func record(_ health: HealthState, at date: Date) -> ProjectRunStatus? {
        switch health {
        case .healthy, .warning:
            begin(at: date)
            hasResponded = true
            consecutiveFailures = 0
            return .running
        case .unreachable:
            begin(at: date)
            consecutiveFailures = min(consecutiveFailures + 1, Self.failureThreshold)
            if !hasResponded, let startedAt,
               date.timeIntervalSince(startedAt) < Self.startupGraceInterval {
                return .warmingUp
            }
            return consecutiveFailures < Self.failureThreshold ? .responseDelayed : .noResponse
        case .unknown, .checking:
            return nil
        }
    }
}
