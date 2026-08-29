import CryptoKit
import Darwin
import Foundation

enum ProjectProcessError: LocalizedError {
    case alreadyRunning
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Project is already running."
        case .launchFailed(let message):
            return "Project could not be started: \(message)"
        }
    }
}

enum ProjectProcessEvent {
    case started(projectId: UUID, pid: Int32)
    case exited(projectId: UUID, code: Int32)
}

struct ManagedProjectProcessRecord: Codable, Equatable {
    let projectId: UUID
    let rootPID: Int32
    let startedAt: Date
    let projectPath: String
    let commandFingerprint: String
    let logPath: String
}

@MainActor
final class ProjectProcessManager {
    var onEvent: ((ProjectProcessEvent) -> Void)?

    private var processes: [UUID: RunningProcess] = [:]
    private var records: [UUID: ManagedProjectProcessRecord]
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let storageDirectoryURL: URL
    private let encoder: JSONEncoder

    private static let recordsKey = "managedProjectProcesses"
    private static let maximumLogBytes: UInt64 = 10 * 1_024 * 1_024
    private static let logTailBytes: UInt64 = 256 * 1_024

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        storageDirectoryURL: URL? = nil
    ) {
        self.defaults = userDefaults
        self.fileManager = fileManager
        self.storageDirectoryURL = storageDirectoryURL
            ?? Self.defaultStorageDirectory(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.records = Self.loadRecords(from: userDefaults, decoder: decoder)
    }

    func reconcile(projects: [LocalProject]) {
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var didChange = false

        for (projectId, record) in Array(records) {
            guard
                let project = projectsByID[projectId],
                standardizedPath(record.projectPath) == standardizedPath(project.path),
                validatedPID(for: record) != nil
            else {
                records.removeValue(forKey: projectId)
                didChange = true
                continue
            }
        }

        if didChange {
            persistRecords()
        }
    }

    func isRunning(projectId: UUID) -> Bool {
        if let running = processes[projectId], running.process.isRunning {
            return true
        }

        guard let record = records[projectId] else { return false }
        guard validatedPID(for: record) != nil else {
            records.removeValue(forKey: projectId)
            persistRecords()
            return false
        }
        return true
    }

    func rootPID(for projectId: UUID) -> Int32? {
        if let running = processes[projectId], running.process.isRunning {
            return running.process.processIdentifier
        }

        guard let record = records[projectId] else { return nil }
        return validatedPID(for: record)
    }

    func projectId(containing pid: Int32) -> UUID? {
        managedProjectIDsByPID()[pid]
    }

    func managedProjectIDsByPID() -> [Int32: UUID] {
        var map: [Int32: UUID] = [:]
        var removedStaleRecord = false

        for (projectId, record) in Array(records) {
            guard let rootPID = validatedPID(for: record) else {
                records.removeValue(forKey: projectId)
                removedStaleRecord = true
                continue
            }

            map[rootPID] = projectId
            for childPID in ProcessTree.descendants(of: rootPID) {
                map[childPID] = projectId
            }
        }

        if removedStaleRecord {
            persistRecords()
        }
        return map
    }

    func start(project: LocalProject) throws {
        guard !isRunning(projectId: project.id) else {
            throw ProjectProcessError.alreadyRunning
        }

        records.removeValue(forKey: project.id)
        let logURL = try prepareLogFile(for: project.id)
        let logHandle = try openLogHandle(at: logURL)
        writeSessionMarker(project: project, to: logHandle)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \(project.resolvedCommand)"]
        process.currentDirectoryURL = project.folderURL
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.environment = environment(for: project)

        process.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            Task { @MainActor in
                self?.handleTermination(projectId: project.id, process: terminated, code: code)
            }
        }

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw ProjectProcessError.launchFailed(error.localizedDescription)
        }

        let startedAt = ProcessTree.startDate(of: process.processIdentifier) ?? Date()
        records[project.id] = ManagedProjectProcessRecord(
            projectId: project.id,
            rootPID: process.processIdentifier,
            startedAt: startedAt,
            projectPath: standardizedPath(project.path),
            commandFingerprint: commandFingerprint(project.resolvedCommand),
            logPath: logURL.path
        )
        processes[project.id] = RunningProcess(process: process, logHandle: logHandle)
        persistRecords()
        onEvent?(.started(projectId: project.id, pid: process.processIdentifier))
    }

    @discardableResult
    func stop(projectId: UUID) -> Bool {
        let running = processes.removeValue(forKey: projectId)
        let record = records.removeValue(forKey: projectId)
        let pid = running?.process.processIdentifier ?? record.flatMap(validatedPID(for:))

        try? running?.logHandle.close()
        persistRecords()

        guard let pid else { return false }
        ProcessTree.terminate(pid: pid)
        return true
    }

    @discardableResult
    func stopAll() -> Set<UUID> {
        var stoppedProjectIDs = Set<UUID>()
        var rootPIDs = Set<Int32>()

        for (projectId, running) in processes where running.process.isRunning {
            stoppedProjectIDs.insert(projectId)
            rootPIDs.insert(running.process.processIdentifier)
            try? running.logHandle.close()
        }

        for (projectId, record) in records {
            guard let pid = validatedPID(for: record) else { continue }
            stoppedProjectIDs.insert(projectId)
            rootPIDs.insert(pid)
        }

        processes.removeAll()
        records.removeAll()
        persistRecords()
        ProcessTree.terminate(pids: Array(rootPIDs))
        return stoppedProjectIDs
    }

    func hasLog(for projectId: UUID) -> Bool {
        fileManager.fileExists(atPath: logURL(for: projectId).path)
    }

    func maintainLogSize(for projectId: UUID) {
        let url = logURL(for: projectId)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > Self.maximumLogBytes else { return }

        let previousURL = url.deletingPathExtension().appendingPathExtension("previous.log")
        try? fileManager.removeItem(at: previousURL)
        do {
            try fileManager.copyItem(at: url, to: previousURL)
        } catch {
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: 0)
    }

    func logLines(for projectId: UUID, limit: Int = 200) -> [String] {
        let url = records[projectId].map { URL(fileURLWithPath: $0.logPath) }
            ?? logURL(for: projectId)
        guard
            let handle = try? FileHandle(forReadingFrom: url),
            let size = try? handle.seekToEnd()
        else {
            return []
        }
        defer { try? handle.close() }

        let offset = size > Self.logTailBytes ? size - Self.logTailBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return [] }

        var lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return Array(lines.suffix(max(1, limit)))
    }

    func appendLog(projectId: UUID, text: String) {
        guard hasLog(for: projectId), let handle = try? openLogHandle(at: logURL(for: projectId)) else {
            return
        }
        defer { try? handle.close() }

        let normalized = text.hasSuffix("\n") ? text : "\(text)\n"
        try? handle.write(contentsOf: Data(normalized.utf8))
    }

    func clearLog(for projectId: UUID) {
        let url = logURL(for: projectId)
        guard fileManager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: 0)
    }

    func removeLog(for projectId: UUID) {
        let url = logURL(for: projectId)
        let previousURL = url.deletingPathExtension().appendingPathExtension("previous.log")
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: previousURL)
    }

    private func handleTermination(projectId: UUID, process: Process, code: Int32) {
        guard
            let running = processes[projectId],
            running.process === process
        else {
            return
        }

        processes.removeValue(forKey: projectId)
        try? running.logHandle.close()
        if records[projectId]?.rootPID == process.processIdentifier {
            records.removeValue(forKey: projectId)
            persistRecords()
        }
        onEvent?(.exited(projectId: projectId, code: code))
    }

    private func validatedPID(for record: ManagedProjectProcessRecord) -> Int32? {
        guard ProcessTree.isAlive(record.rootPID) else { return nil }
        guard let actualStart = ProcessTree.startDate(of: record.rootPID) else { return nil }
        return abs(actualStart.timeIntervalSince(record.startedAt)) <= 5 ? record.rootPID : nil
    }

    private func prepareLogFile(for projectId: UUID) throws -> URL {
        try fileManager.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        let url = logURL(for: projectId)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        if size > Self.maximumLogBytes {
            let previousURL = url.deletingPathExtension().appendingPathExtension("previous.log")
            try? fileManager.removeItem(at: previousURL)
            try fileManager.moveItem(at: url, to: previousURL)
        }

        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw ProjectProcessError.launchFailed("Could not create log file at \(url.path).")
            }
        }
        return url
    }

    private func openLogHandle(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let message = String(cString: strerror(errno))
            throw ProjectProcessError.launchFailed("Could not open log file: \(message)")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func writeSessionMarker(project: LocalProject, to handle: FileHandle) {
        let marker = "\n[Local Monitor] Starting \(project.displayName) on localhost:\(project.port)\n"
        try? handle.write(contentsOf: Data(marker.utf8))
    }

    private func commandFingerprint(_ command: String) -> String {
        SHA256.hash(data: Data(command.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func logURL(for projectId: UUID) -> URL {
        storageDirectoryURL.appendingPathComponent("\(projectId.uuidString).log")
    }

    private func persistRecords() {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Self.recordsKey)
            return
        }
        let encodable = records.reduce(into: [String: ManagedProjectProcessRecord]()) { result, item in
            result[item.key.uuidString] = item.value
        }
        guard let data = try? encoder.encode(encodable) else { return }
        defaults.set(data, forKey: Self.recordsKey)
    }

    private static func loadRecords(
        from defaults: UserDefaults,
        decoder: JSONDecoder
    ) -> [UUID: ManagedProjectProcessRecord] {
        guard
            let data = defaults.data(forKey: recordsKey),
            let decoded = try? decoder.decode([String: ManagedProjectProcessRecord].self, from: data)
        else {
            return [:]
        }

        return decoded.reduce(into: [:]) { result, item in
            guard let id = UUID(uuidString: item.key) else { return }
            result[id] = item.value
        }
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Local Monitor", isDirectory: true)
            .appendingPathComponent("Managed Processes", isDirectory: true)
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func environment(for project: LocalProject) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = "\(project.port)"
        environment["LOCALMONITOR"] = "1"

        let currentPath = environment["PATH"] ?? ""
        let fallbackPath = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")

        environment["PATH"] = currentPath.isEmpty ? fallbackPath : "\(currentPath):\(fallbackPath)"
        return environment
    }
}

private struct RunningProcess {
    let process: Process
    let logHandle: FileHandle
}
