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
        // Assigning nil to NSTask.environment creates an empty child environment on macOS.
        // Preserve manager locations (FNM_DIR/NVM_DIR) and other inherited settings by default.
        process.environment = environment ?? ProcessInfo.processInfo.environment
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
        let birth = ProcessTree.startDate(of: process.processIdentifier)
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
            let targets = birth.map { ProcessTree.requestTermination(of: process.processIdentifier, startedAt: $0) } ?? [:]
            if targets.isEmpty, process.isRunning { process.terminate() }
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < grace { drain(); Thread.sleep(forTimeInterval: 0.01) }
            ProcessTree.finishTermination(of: targets)
            if targets.isEmpty, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
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
        guard let birth = startDate(of: pid) else { return }
        let targets = requestTermination(of: pid, startedAt: birth)
        guard !targets.isEmpty else { return }
        Thread.sleep(forTimeInterval: 0.8)
        finishTermination(of: targets)
    }

    static func requestTermination(of root: Int32, startedAt: Date) -> [Int32: Date] {
        guard startDate(of: root) == startedAt else { return [:] }
        var targets = [root: startedAt]
        var pending = [root]
        var order = [root]
        while let parent = pending.popLast() {
            guard let birth = targets[parent], startDate(of: parent) == birth else { continue }
            for child in childPIDs(of: parent) where targets[child] == nil {
                guard let info = processInfo(of: child), info.pbi_ppid == UInt32(parent),
                      startDate(of: parent) == birth else { continue }
                targets[child] = birthDate(info)
                pending.append(child)
                order.append(child)
            }
        }
        for pid in order.reversed() {
            if let birth = targets[pid], startDate(of: pid) == birth { _ = Darwin.kill(pid, SIGTERM) }
        }
        return targets
    }

    static func finishTermination(of targets: [Int32: Date]) {
        for (pid, birth) in targets where startDate(of: pid) == birth { _ = Darwin.kill(pid, SIGKILL) }
    }

    static func hasLiveProcess(in targets: [Int32: Date]) -> Bool {
        targets.contains { pid, birth in
            guard let info = processInfo(of: pid) else { return false }
            return info.pbi_status != SZOMB && birthDate(info) == birth
        }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func startDate(of pid: Int32) -> Date? {
        processInfo(of: pid).map(birthDate)
    }

    private static func processInfo(of pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func birthDate(_ info: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    static func isDescendant(_ pid: Int32, of rootPID: Int32) -> Bool {
        descendants(of: rootPID).contains(pid)
    }

    static func descendants(of pid: Int32) -> [Int32] {
        var pending = [pid]
        var visited: Set<Int32> = [pid]
        var descendants: [Int32] = []
        while let parent = pending.popLast() {
            for child in childPIDs(of: parent) where visited.insert(child).inserted {
                descendants.append(child)
                pending.append(child)
            }
        }
        return descendants
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        var children = [Int32](repeating: 0, count: 16)
        while true {
            let capacity = Int32(children.count * MemoryLayout<Int32>.stride)
            let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &children, capacity)
            guard bytes > 0 else { return [] }
            if bytes < capacity { return Array(children.prefix(Int(bytes) / MemoryLayout<Int32>.stride)) }
            children += Array(repeating: 0, count: children.count)
        }
    }
}
