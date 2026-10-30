import Foundation

enum ProjectInstallationState: Equatable {
    case running, succeeded, cancelled, failed(String)
    var message: String {
        switch self {
        case .running: return "Installing dependencies…"
        case .succeeded: return "Dependencies installed and verified."
        case .cancelled: return "Installation cancelled."
        case .failed(let text): return text
        }
    }
}

extension LocalMonitorModel {
    func isInstallingDependencies(for project: LocalProject) -> Bool {
        if installationTasks.isEmpty { return false }
        let root = dependencyInstallation.folder(for: project)
        return installationTasks.keys.contains { id in
            projects.first(where: { $0.id == id }).map { dependencyInstallation.folder(for: $0) == root } ?? false
        }
    }

    func checkRequirements(for project: LocalProject) async {
        guard checkingProjects.insert(project.id).inserted else { return }
        defer { checkingProjects.remove(project.id) }
        let result = await preflightChecker.check(project)
        guard projects.contains(where: { $0.id == project.id }), !Task.isCancelled else { return }
        preflightResults[project.id] = result
    }

    func installDependencies(for project: LocalProject) async {
        let store = dependencyInstallation
        let root = store.folder(for: project)
        guard !isInstallingDependencies(for: project) else { return }
        let activeSibling = projects.contains { other in
            guard store.folder(for: other) == root else { return false }
            return ![.stopped, .crashed, .portBusy].contains(runtimeState(for: other).status)
                || processManager.isRunning(projectId: other.id)
                || maintenanceRequests[other.id] != nil
        }
        if activeSibling {
            installationStates[project.id] = .failed("Stop projects sharing this workspace before reinstalling dependencies.")
            return
        }
        let state = runtimeState(for: project)
        guard [.stopped, .crashed, .portBusy].contains(state.status), !processManager.isRunning(projectId: project.id) else {
            installationStates[project.id] = .failed("Stop this project before reinstalling dependencies.")
            return
        }
        installationStates[project.id] = .running
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.installationTasks.removeValue(forKey: project.id) }
            do {
                let environment = try await ProjectLaunchEnvironment.prepare(project,
                    nodeResolver: self.preflightChecker.nodeRuntimeResolver,
                    packageResolver: self.preflightChecker.packageRuntimeResolver, allowDownload: true)
                let fingerprint = try store.fingerprint(project)
                let command = store.installCommand(for: project, environment: environment)
                var variables = ProcessInfo.processInfo.environment
                variables["CI"] = "1"
                let result = try await Shell.run("/bin/zsh", arguments: ["-lc", environment.command(command)],
                                                timeout: 300, directory: root, environment: variables, maximumOutputBytes: 131_072)
                try Task.checkCancellation()
                guard result.status == 0 else {
                    let diagnosis = ProjectFailureDiagnosis.classify(logs: [result.stdout, result.stderr], exitCode: result.status)
                    self.recordFailure(for: project, code: result.status, diagnosis: diagnosis)
                    throw ProjectReliabilityError.message("\(diagnosis.title). \(diagnosis.recovery)")
                }
                // Existing lockfiles are frozen; a first install is allowed to create a new one.
                let frozen = command.contains(" ci") || command.contains("--frozen-lockfile") || command.contains("--immutable")
                if frozen, try store.fingerprint(project) != fingerprint {
                    throw ProjectReliabilityError.message("Dependency metadata changed during installation. Review the lockfile before retrying.")
                }
                try store.recordSuccess(project, environment: environment, fingerprint: store.fingerprint(project))
                self.installationStates[project.id] = .succeeded
                await self.checkRequirements(for: project)
            } catch is CancellationError {
                if self.projects.contains(where: { $0.id == project.id }) { self.installationStates[project.id] = .cancelled }
            } catch {
                if self.projects.contains(where: { $0.id == project.id }) {
                    self.installationStates[project.id] = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                }
            }
        }
        installationTasks[project.id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func cancelInstallation(for project: LocalProject) { installationTasks[project.id]?.cancel() }

    func startDependencyChain(for project: LocalProject) async {
        guard dependencyLaunchTasks[project.id] == nil else { return }
        let order: [LocalProject]
        do { order = try ProjectDependencyGraph.order(for: project, projects: projects) }
        catch { setState(for: project.id, status: .crashed, message: error.localizedDescription); return }
        dependencyLaunchMembers[project.id] = Set(order.map(\.id))
        setState(for: project.id, status: .starting, message: "Checking dependent services…")
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.dependencyLaunchTasks.removeValue(forKey: project.id)
                self.dependencyLaunchMembers.removeValue(forKey: project.id)
            }
            do {
                var prepared: [UUID: PreflightResult] = [:]
                for item in order {
                    try Task.checkCancellation()
                    let check = await self.preflightChecker.check(item)
                    try Task.checkCancellation()
                    self.preflightResults[item.id] = check
                    guard check.isClear else { throw ProjectReliabilityError.message("\(item.displayName): \(check.summary)") }
                    prepared[item.id] = check
                }
                for item in order {
                    try Task.checkCancellation()
                    try await ProjectComposeServices().start(for: item)
                    try Task.checkCancellation()
                    if item.id == project.id { self.setState(for: item.id, status: .stopped) }
                    await self.startProject(item, recordsUsage: false, withDependencies: false, prechecked: prepared[item.id])
                    try Task.checkCancellation()
                    if item.id != project.id {
                        try await ProjectDependencyGraph.waitUntilReady {
                            let status = self.runtimeState(for: item).status
                            if [.crashed, .stopped, .portBusy, .portMismatch].contains(status) {
                                throw ProjectReliabilityError.message("\(item.displayName) failed to start. Open its logs before retrying.")
                            }
                            let health = await self.healthChecker.check(item)
                            try Task.checkCancellation()
                            guard ![.crashed, .stopped, .portBusy, .portMismatch].contains(self.runtimeState(for: item).status) else {
                                throw ProjectReliabilityError.message("\(item.displayName) stopped or changed ports while checking readiness.")
                            }
                            if case .healthy = health { return true }
                            return false
                        }
                    }
                }
            } catch is CancellationError {
                if self.projects.contains(where: { $0.id == project.id }), !self.processManager.isRunning(projectId: project.id) {
                    self.setState(for: project.id, status: .stopped)
                }
            } catch {
                self.setState(for: project.id, status: .crashed, message: error.localizedDescription)
                self.appendLog(projectId: project.id, text: error.localizedDescription)
            }
        }
        dependencyLaunchTasks[project.id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func refreshResourceMeasurements() async {
        var roots: [UUID: Set<Int32>] = [:]
        for project in projects {
            let state = runtimeState(for: project)
            if let pid = processManager.rootPID(for: project.id) { roots[project.id, default: []].insert(pid) }
            else if let pid = state.pid { roots[project.id, default: []].insert(pid) }
            for port in discoveredPorts where port.projectId == project.id { roots[project.id, default: []].insert(port.pid) }
        }
        let valid = Set(projects.map(\.id))
        resourceStates = resourceStates.filter { valid.contains($0.key) }
        for id in resourceStates.keys where roots[id] == nil { resourceStates[id]?.warning = nil }
        guard !roots.isEmpty else { return }
        let sampler = ProjectResourceSampler()
        guard let snapshot = try? await sampler.snapshot(), !Task.isCancelled else { return }
        for project in projects {
            guard let pids = roots[project.id] else { continue }
            let sample = sampler.aggregate(roots: pids, entries: snapshot)
            var state = resourceStates[project.id] ?? ProjectResourceState()
            let warning = state.record(sample, settings: project.reliability,
                                       alerts: .load(from: defaults))
            resourceStates[project.id] = state
            if let warning {
                notificationService.notify(title: "\(project.displayName) resource usage", body: warning)
            }
        }
    }

    func loadFailureHistory() {
        for project in projects {
            guard let data = defaults.data(forKey: "projectFailures.\(project.id)"), data.count <= 65_536,
                  let records = try? JSONDecoder().decode([ProjectFailureRecord].self, from: data) else { continue }
            failureHistory[project.id] = Array(records.suffix(20))
        }
    }

    func recordFailure(for project: LocalProject, code: Int32, diagnosis: ProjectFailureDiagnosis) {
        var records = failureHistory[project.id] ?? []
        records.append(ProjectFailureRecord(exitCode: code, diagnosis: diagnosis))
        records = Array(records.suffix(20))
        failureHistory[project.id] = records
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "projectFailures.\(project.id)") }
    }

    func clearFailureHistory(for project: LocalProject) {
        failureHistory.removeValue(forKey: project.id)
        defaults.removeObject(forKey: "projectFailures.\(project.id)")
    }

    func resetAutomaticRestarts(for id: UUID) {
        automaticRestartTasks.removeValue(forKey: id)?.cancel()
        restartBudgets[id] = ProjectRestartBudget()
    }

    func scheduleAutomaticRestart(for project: LocalProject) {
        var budget = restartBudgets[project.id] ?? ProjectRestartBudget()
        guard let delay = budget.nextDelay(maximum: project.reliability.validated.maximumRestarts) else {
            let message = "Automatic restart paused after repeated crashes. Review the diagnosis and press Start to retry."
            setState(for: project.id, status: .crashed, message: message)
            appendLog(projectId: project.id, text: message)
            automaticRestartTasks.removeValue(forKey: project.id)?.cancel()
            return
        }
        restartBudgets[project.id] = budget
        appendLog(projectId: project.id, text: "Automatic restart in \(Int(delay)) seconds (attempt \(budget.failures.count)/\(project.reliability.maximumRestarts)).")
        automaticRestartTasks[project.id]?.cancel()
        automaticRestartTasks[project.id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self, let current = self.projects.first(where: { $0.id == project.id }), current.autoRestart else { return }
                self.automaticRestartTasks.removeValue(forKey: project.id)
                await self.startProject(current, recordsUsage: false)
            } catch { /* User Stop or app shutdown cancels delayed retries. */ }
        }
    }

    func cancelReliabilityOperations(for id: UUID) {
        projectLaunchRequests.removeValue(forKey: id)
        preflightTasks.removeValue(forKey: id)?.cancel()
        stopVerificationTasks.removeValue(forKey: id)?.cancel()
        cancelMaintenance(for: id)
        for root in Array(dependencyLaunchTasks.keys) where root == id || dependencyLaunchMembers[root]?.contains(id) == true {
            dependencyLaunchTasks[root]?.cancel()
        }
        installationTasks[id]?.cancel()
        automaticRestartTasks.removeValue(forKey: id)?.cancel()
    }

    func cancelAllReliabilityOperations() {
        bulkStartGeneration = UUID()
        for id in Array(maintenanceRequests.keys) { cancelMaintenance(for: id) }
        groupStartRequests.removeAll()
        projectLaunchRequests.removeAll()
        for task in preflightTasks.values { task.cancel() }
        preflightTasks.removeAll()
        for task in stopVerificationTasks.values { task.cancel() }
        stopVerificationTasks.removeAll()
        for task in dependencyLaunchTasks.values { task.cancel() }
        for task in installationTasks.values { task.cancel() }
        for task in automaticRestartTasks.values { task.cancel() }
        automaticRestartTasks.removeAll()
    }
}
