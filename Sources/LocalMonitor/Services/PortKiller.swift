import Darwin
import Foundation

enum PortKillerError: LocalizedError {
    case failed(pid: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .failed(let pid, let message):
            return "Could not stop PID \(pid): \(message)"
        }
    }
}

struct PortKiller {
    func stop(pid: Int32, startedAt: Date) async throws {
        try signal(SIGTERM, pid: pid, startedAt: startedAt)
        try await Task.sleep(for: .milliseconds(800))
        try signal(SIGKILL, pid: pid, startedAt: startedAt)
    }

    private func signal(_ signal: Int32, pid: Int32, startedAt: Date) throws {
        guard ProcessTree.startDate(of: pid) == startedAt else { return }
        if Darwin.kill(pid, signal) != 0, errno != ESRCH {
            throw PortKillerError.failed(pid: pid, message: String(cString: strerror(errno)))
        }
    }
}
