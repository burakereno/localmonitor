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
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 8,
                    directory: URL? = nil, environment: [String: String]? = nil,
                    maximumOutputBytes: Int = 262_144) async throws -> ShellResult {
        let cancellation = ShellCancellationFlag()
        return try await withTaskCancellationHandler {
            let result: ShellResult = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try execute(executable, arguments: arguments, timeout: timeout,
                            directory: directory, environment: environment, maximumOutputBytes: maximumOutputBytes,
                            cancellation: cancellation))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func runSync(_ executable: String, arguments: [String], timeout: TimeInterval = 8,
                        directory: URL? = nil, environment: [String: String]? = nil,
                        maximumOutputBytes: Int = 262_144) throws -> ShellResult {
        try execute(executable, arguments: arguments, timeout: timeout, directory: directory,
                    environment: environment, maximumOutputBytes: maximumOutputBytes, cancellation: nil)
    }

    private static func execute(_ executable: String, arguments: [String], timeout: TimeInterval,
                                directory: URL?, environment: [String: String]?, maximumOutputBytes: Int,
                                cancellation: ShellCancellationFlag?) throws -> ShellResult {
        if cancellation?.isCancelled == true { throw CancellationError() }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        do { try process.run() } catch { throw ShellError.launchFailed(error.localizedDescription) }
        let limit = min(2_097_152, max(1_024, maximumOutputBytes))
        var outputs = [Data(), Data()]
        var truncated = [false, false]
        var buffer = [UInt8](repeating: 0, count: 8_192)
        func drain() {
            for (index, descriptor) in descriptors.enumerated() {
                // Bound work per poll even when a child continuously writes output.
                for _ in 0..<32 {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count <= 0 { break }
                    let kept = min(count, max(0, limit - outputs[index].count))
                    outputs[index].append(contentsOf: buffer.prefix(kept))
                    if kept < count { truncated[index] = true }
                }
            }
        }
        let deadline = Date().addingTimeInterval(max(0.05, timeout))
        while process.isRunning, Date() < deadline, cancellation?.isCancelled != true {
            drain()
            Thread.sleep(forTimeInterval: 0.01)
        }
        let cancelled = cancellation?.isCancelled == true
        let timedOut = process.isRunning && !cancelled
        if process.isRunning {
            let children = ProcessTree.descendants(of: process.processIdentifier)
            for pid in children.reversed() { _ = Darwin.kill(pid, SIGTERM) }
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < grace { drain(); Thread.sleep(forTimeInterval: 0.01) }
            for pid in children where ProcessTree.isAlive(pid) { _ = Darwin.kill(pid, SIGKILL) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        drain()
        var text = outputs.enumerated().map { index, data in
            String(decoding: data, as: UTF8.self) + (truncated[index] ? "\n[Output truncated]" : "")
        }
        if timedOut { text[1] += "\nCommand timed out after \(Int(timeout))s." }
        return ShellResult(status: cancelled ? 130 : timedOut ? 124 : process.terminationStatus,
                           stdout: text[0], stderr: text[1])
    }
}

/// The only shared state is a cancellation bit; every access is protected by this lock.
private final class ShellCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum ProcessTree {
    static func terminate(pid: Int32) {
        terminate(pids: [pid])
    }

    static func terminate(pids: [Int32]) {
        let roots = Array(Set(pids.filter { $0 > 1 }))
        let allPids = Array(Set(roots.flatMap { descendants(of: $0).reversed() + [$0] }))
        for childPID in allPids {
            _ = Darwin.kill(childPID, SIGTERM)
        }

        Thread.sleep(forTimeInterval: 0.8)

        for childPID in allPids where Darwin.kill(childPID, 0) == 0 {
            _ = Darwin.kill(childPID, SIGKILL)
        }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func startDate(of pid: Int32) -> Date? {
        guard
            let result = try? Shell.runSync(
                "/bin/ps",
                arguments: ["-p", "\(pid)", "-o", "lstart="],
                timeout: 2
            ),
            result.status == 0
        else {
            return nil
        }

        let normalized = result.stdout
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.isLenient = true
        return formatter.date(from: normalized)
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
