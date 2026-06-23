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
    case output(projectId: UUID, text: String)
    case exited(projectId: UUID, code: Int32)
}

@MainActor
final class ProjectProcessManager {
    var onEvent: ((ProjectProcessEvent) -> Void)?

    private var processes: [UUID: RunningProcess] = [:]

    func isRunning(projectId: UUID) -> Bool {
        guard let running = processes[projectId] else { return false }
        return running.process.isRunning
    }

    func rootPID(for projectId: UUID) -> Int32? {
        guard let running = processes[projectId], running.process.isRunning else { return nil }
        return running.process.processIdentifier
    }

    func projectId(containing pid: Int32) -> UUID? {
        for (projectId, running) in processes where running.process.isRunning {
            let rootPID = running.process.processIdentifier
            if pid == rootPID || ProcessTree.isDescendant(pid, of: rootPID) {
                return projectId
            }
        }

        return nil
    }

    func managedProjectIDsByPID() -> [Int32: UUID] {
        var map: [Int32: UUID] = [:]

        for (projectId, running) in processes where running.process.isRunning {
            let rootPID = running.process.processIdentifier
            map[rootPID] = projectId

            for childPID in ProcessTree.descendants(of: rootPID) {
                map[childPID] = projectId
            }
        }

        return map
    }

    func start(project: LocalProject) throws {
        guard processes[project.id] == nil else {
            throw ProjectProcessError.alreadyRunning
        }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \(project.resolvedCommand)"]
        process.currentDirectoryURL = project.folderURL
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = environment(for: project)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.onEvent?(.output(projectId: project.id, text: text))
            }
        }

        process.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            Task { @MainActor in
                self?.handleTermination(projectId: project.id, code: code)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ProjectProcessError.launchFailed(error.localizedDescription)
        }

        processes[project.id] = RunningProcess(process: process, pipe: pipe)
        onEvent?(.started(projectId: project.id, pid: process.processIdentifier))
    }

    func stop(projectId: UUID) {
        guard let running = processes.removeValue(forKey: projectId) else { return }
        running.pipe.fileHandleForReading.readabilityHandler = nil
        ProcessTree.terminate(pid: running.process.processIdentifier)
    }

    func stopAll() {
        for projectId in Array(processes.keys) {
            stop(projectId: projectId)
        }
    }

    private func handleTermination(projectId: UUID, code: Int32) {
        guard let running = processes.removeValue(forKey: projectId) else { return }
        running.pipe.fileHandleForReading.readabilityHandler = nil
        onEvent?(.exited(projectId: projectId, code: code))
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
    let pipe: Pipe
}
