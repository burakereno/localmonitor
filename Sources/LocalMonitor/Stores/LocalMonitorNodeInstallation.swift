import Foundation

enum ProjectNodeInstallationState: Equatable {
    case running, succeeded(String), cancelled, failed(String)

    var isRunning: Bool { self == .running }

    var message: String {
        switch self {
        case .running: return "Installing Node.js…"
        case .succeeded(let version): return "Node.js \(version) installed and verified."
        case .cancelled: return "Node.js installation cancelled."
        case .failed(let message): return message
        }
    }
}

extension LocalMonitorModel {
    func isInstallingNode(for project: LocalProject) -> Bool {
        nodeInstallationTasks[project.id] != nil
    }

    func installNode(for project: LocalProject) async {
        guard !Task.isCancelled, projects.contains(where: { $0.id == project.id }),
              let requirement = preflightResults[project.id]?.missingNodeRequirement,
              nodeInstallationTasks.isEmpty, !checkingProjects.contains(project.id),
              !isInstallingDependencies(for: project), maintenanceRequests[project.id] == nil,
              [.stopped, .crashed, .portBusy].contains(runtimeState(for: project).status),
              !processManager.isRunning(projectId: project.id) else { return }

        let installer = nodeInstaller
        let resolver = preflightChecker.nodeRuntimeResolver
        nodeInstallationStates[project.id] = .running
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.nodeInstallationTasks.removeValue(forKey: project.id) }
            do {
                let runtime = try await installer.install(requirement, in: project.folderURL, resolver: resolver)
                try Task.checkCancellation()
                guard self.projects.contains(where: { $0.id == project.id }) else { return }
                await self.checkRequirements(for: project)
                try Task.checkCancellation()
                guard self.projects.contains(where: { $0.id == project.id }) else { return }
                guard self.preflightResults[project.id]?.missingNodeRequirement == nil else {
                    throw ProjectReliabilityError.message("The Node.js requirement changed during installation. Install the version now shown on this project.")
                }
                self.nodeInstallationStates[project.id] = .succeeded(runtime.version.description)
                if self.preflightResults[project.id]?.isClear == true,
                   self.runtimeState(for: project).status == .crashed {
                    self.setState(for: project.id, status: .stopped, message: "Node.js installed. Ready to start.")
                }
            } catch {
                guard self.projects.contains(where: { $0.id == project.id }) else { return }
                self.nodeInstallationStates[project.id] = Task.isCancelled || error is CancellationError
                    ? .cancelled : .failed(error.localizedDescription)
                if !Task.isCancelled, !(error is CancellationError) {
                    await self.checkRequirements(for: project)
                }
            }
        }
        nodeInstallationTasks[project.id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancelNodeInstallation(for project: LocalProject) {
        nodeInstallationTasks[project.id]?.cancel()
    }
}
