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
    func stop(pid: Int32) async throws {
        let term = try await Shell.run("/bin/kill", arguments: ["-TERM", "\(pid)"])
        if term.status != 0 {
            let message = term.stderr.nilIfBlank ?? term.stdout.nilIfBlank ?? "kill exited with \(term.status)"
            if message.localizedCaseInsensitiveContains("No such process") {
                return
            }
            throw PortKillerError.failed(pid: pid, message: message)
        }

        try? await Task.sleep(nanoseconds: 800_000_000)

        let probe = try await Shell.run("/bin/kill", arguments: ["-0", "\(pid)"])
        guard probe.status == 0 else { return }

        let kill = try await Shell.run("/bin/kill", arguments: ["-KILL", "\(pid)"])
        if kill.status != 0 {
            let message = kill.stderr.nilIfBlank ?? kill.stdout.nilIfBlank ?? "kill exited with \(kill.status)"
            throw PortKillerError.failed(pid: pid, message: message)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
