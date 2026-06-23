import Foundation

struct ShellResult: Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ShellError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Command could not be launched: \(message)"
        }
    }
}

enum Shell {
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 8) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try runSync(executable, arguments: arguments, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runSync(_ executable: String, arguments: [String], timeout: TimeInterval = 8) throws -> ShellResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(error.localizedDescription)
        }

        let timeoutInterval = DispatchTimeInterval.milliseconds(max(1, Int(timeout * 1_000)))
        let timedOut = finished.wait(timeout: .now() + timeoutInterval) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.8) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.8)
            }
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        var errorText = String(data: errorData, encoding: .utf8) ?? ""

        if timedOut {
            let commandText = ([executable] + arguments).joined(separator: " ")
            let suffix = "Command timed out after \(Int(timeout))s: \(commandText)"
            errorText = errorText.isEmpty ? suffix : "\(errorText)\n\(suffix)"
        }

        return ShellResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: String(data: outputData, encoding: .utf8) ?? "",
            stderr: errorText
        )
    }
}

enum ProcessTree {
    static func terminate(pid: Int32) {
        let allPids = descendants(of: pid).reversed() + [pid]
        for childPID in allPids {
            _ = Darwin.kill(childPID, SIGTERM)
        }

        Thread.sleep(forTimeInterval: 0.8)

        for childPID in allPids where Darwin.kill(childPID, 0) == 0 {
            _ = Darwin.kill(childPID, SIGKILL)
        }
    }

    static func isDescendant(_ pid: Int32, of rootPID: Int32) -> Bool {
        descendants(of: rootPID).contains(pid)
    }

    static func descendants(of pid: Int32) -> [Int32] {
        let direct = childPIDs(of: pid)
        return direct + direct.flatMap { descendants(of: $0) }
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        guard
            let result = try? Shell.runSync("/usr/bin/pgrep", arguments: ["-P", "\(pid)"], timeout: 2),
            result.status == 0
        else {
            return []
        }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
