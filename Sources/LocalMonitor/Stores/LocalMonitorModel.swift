import AppKit
import Combine
import Foundation

enum CleanRestartError: LocalizedError {
    case unsafePath(String)
    case removeFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path):
            return "Unsafe cache path skipped: \(path)"
        case .removeFailed(let path, let message):
            return "Could not remove \(path): \(message)"
        }
    }
}

private struct RuntimeSessionSnapshot: Codable {
    let startedAt: Date
    let processStartedAt: Date?
    let lastSeenRunningAt: Date?
    let pid: Int32?
    let observedPort: Int?
}

@MainActor
final class LocalMonitorModel: ObservableObject {
    @Published private(set) var projects: [LocalProject]
    @Published private(set) var groups: [WorkspaceGroup]
    @Published private(set) var runtimeStates: [UUID: ProjectRuntimeState] = [:]
    @Published private(set) var projectIdentities: [UUID: ProjectIdentity] = [:]
    @Published private(set) var projectBrowserHostnames: [UUID: [String]] = [:]
    @Published private(set) var healthStates: [UUID: HealthState] = [:]
    @Published var preflightResults: [UUID: PreflightResult] = [:]
    @Published var resourceStates: [UUID: ProjectResourceState] = [:]
    @Published var failureHistory: [UUID: [ProjectFailureRecord]] = [:]
    @Published var installationStates: [UUID: ProjectInstallationState] = [:]
    @Published var nodeInstallationStates: [UUID: ProjectNodeInstallationState] = [:]
    @Published var checkingProjects: Set<UUID> = []
    var dependencyLaunchTasks: [UUID: Task<Void, Never>] = [:]
    var dependencyLaunchMembers: [UUID: Set<UUID>] = [:]
    var projectLaunchRequests: [UUID: UUID] = [:]
    var preflightTasks: [UUID: Task<PreflightResult, Never>] = [:]
    var stopVerificationTasks: [UUID: Task<Void, Never>] = [:]
    var maintenanceRequests: [UUID: UUID] = [:]
    var bulkStartGeneration = UUID()
    var groupStartRequests: [UUID: UUID] = [:]
    var installationTasks: [UUID: Task<Void, Never>] = [:]
    var nodeInstallationTasks: [UUID: Task<Void, Never>] = [:]
    var nodeInstaller = ProjectNodeInstaller()
    var automaticRestartTasks: [UUID: Task<Void, Never>] = [:]
    var restartBudgets: [UUID: ProjectRestartBudget] = [:]
    var dependencyInstallation = ProjectDependencyInstallation()
    @Published private(set) var discoveredPorts: [DiscoveredPort] = []
    @Published private(set) var pinnedPortNames: [Int: String] = [:]
    @Published private(set) var ignoredPorts: Set<Int> = []
    @Published private var pendingKillPort: DiscoveredPort?
    var pendingKillPortID: String? { pendingKillPort?.id }
    @Published private(set) var cleanRestartStates: [UUID: CleanRestartState] = [:]
    @Published private(set) var cacheStates: [UUID: ProjectCacheState] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private var operationError: String?
    @Published private var scanError: String?
    var lastError: String? { operationError ?? scanError ?? store.saveIssue ?? store.loadIssue }
    @Published private(set) var menuBarTitle = MenuBarTitle(
        runningCount: 0,
        totalCount: 0,
        externalCount: 0,
        displayMode: .count
    )
    @Published var selectedLogProjectID: UUID? {
        didSet {
            if selectedLogProjectID != oldValue { Task { await refreshSelectedLog() } }
        }
    }
    private let logReader = ProjectLogReader()
    private var logRevision = 0

    let iconCache: ProjectIconCache
    private let store: ProjectStore
    private let portScanner: any PortScanning
    private let portKiller: PortKiller
    private let projectInspector: ProjectInspector
    let preflightChecker: PreflightChecker
    let healthChecker: any HealthChecking
    let notificationService: NotificationService
    let processManager: ProjectProcessManager
    let defaults: UserDefaults
    private var refreshCycle: Task<Void, Never>?
    private struct RefreshRequest {
        let includesExternalPorts: Bool
        let completion: CheckedContinuation<[DiscoveredPort]?, Never>
    }
    private var refreshRequests: [RefreshRequest] = []
    private var cleaningFolders: Set<String> = []
    private var healthRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var cacheSizeTask: Task<Void, Never>?
    private var projectPanel: NSOpenPanel?
    private var workspaceImportController: WorkspaceImportWindowController?
    private var pendingBrowserOpens = Set<UUID>()
    private var lastHealthStates: [UUID: HealthState] = [:]
    private var lastReadinessCheckDates: [UUID: Date] = [:]
    private var readinessCheckIDs: [UUID: UUID] = [:]
    private var healthChecksEnabled: Bool
    private var lastProjectIdentityRefresh: Date?
    private let cacheSizeRefreshInterval: TimeInterval = 600
    private let readinessCheckRefreshInterval: TimeInterval = 12
    private let projectIdentityRefreshInterval: TimeInterval = 60
    private let sessionContinuityGraceInterval: TimeInterval = 120
    private let initialPortWaitInterval: TimeInterval = 90

    init(
        store: ProjectStore = ProjectStore(),
        portScanner: any PortScanning = PortScanner(),
        portKiller: PortKiller = PortKiller(),
        projectInspector: ProjectInspector = ProjectInspector(),
        preflightChecker: PreflightChecker = PreflightChecker(),
        healthChecker: any HealthChecking = HealthChecker(),
        healthChecksEnabled: Bool? = nil,
        notificationService: NotificationService? = nil,
        processManager: ProjectProcessManager? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.iconCache = store.storageDirectoryURL.map {
            ProjectIconCache(storageDirectoryURL: $0.appendingPathComponent("Favicons", isDirectory: true))
        } ?? .shared
        self.portScanner = portScanner
        self.portKiller = portKiller
        self.projectInspector = projectInspector
        self.preflightChecker = preflightChecker
        self.healthChecker = healthChecker
        self.healthChecksEnabled = healthChecksEnabled ?? AppPreference.healthChecks
        self.notificationService = notificationService ?? .shared
        self.processManager = processManager ?? ProjectProcessManager(
            userDefaults: userDefaults, storageDirectoryURL: store.storageDirectoryURL?.appendingPathComponent("Managed Processes")
        )
        self.defaults = userDefaults
        let loadedLibrary = store.load()
        let library = Self.migrateLegacyCommandTemplates(in: loadedLibrary)
        let savedRuntimeSessions = Self.loadRuntimeSessions(from: userDefaults)
        self.projects = library.projects
        self.groups = library.groups
        self.pinnedPortNames = Self.loadPinnedPorts(from: userDefaults)
        self.ignoredPorts = Self.loadIgnoredPorts(from: userDefaults)

        if library != loadedLibrary {
            store.save(library)
        }

        for project in projects {
            if let snapshot = savedRuntimeSessions[project.id] {
                runtimeStates[project.id] = Self.runtimeState(from: snapshot)
            } else {
                runtimeStates[project.id] = .stopped
            }
            healthStates[project.id] = .unknown
        }

        self.processManager.reconcile(projects: projects, pruneMissing: store.loadIssue == nil)
        self.processManager.onEvent = { [weak self] event in
            self?.handle(processEvent: event)
        }

        updateMenuBarTitle()
        refreshBrowserHostnames()
        loadFailureHistory()
    }

    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()

            while !Task.isCancelled {
                let interval = UInt64(AppPreference.refreshInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await self.refresh()
            }
        }
    }

    func stop() {
        pendingBrowserOpens.removeAll()
        cancelAllReliabilityOperations()
        refreshTask?.cancel()
        refreshTask = nil
        refreshCycle?.cancel()
        refreshCycle = nil
        for request in refreshRequests { request.completion.resume(returning: nil) }
        refreshRequests.removeAll()
        isRefreshing = false
        healthRefreshTask?.cancel()
        healthRefreshTask = nil
        readinessCheckIDs.removeAll()
    }

    func shutdown() {
        if AppPreference.stopProjectsOnQuit {
            stopAllProjects()
        }
        stop()
    }

    func refresh() async {
        _ = await requestRefresh()
    }

    private func requestRefresh(includingExternalPorts: Bool = false) async -> [DiscoveredPort]? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { completion in
            refreshRequests.append(RefreshRequest(includesExternalPorts: includingExternalPorts, completion: completion))
            guard refreshCycle == nil else { return }
            isRefreshing = true
            refreshCycle = Task {
                guard !Task.isCancelled else { return }
                while !refreshRequests.isEmpty {
                    let batch = refreshRequests
                    refreshRequests.removeAll()
                    let ports = await refreshOnce(includingExternalPorts: batch.contains(where: \.includesExternalPorts))
                    for request in batch { request.completion.resume(returning: ports) }
                    if Task.isCancelled { return }
                }
                refreshCycle = nil
                isRefreshing = false
            }
        }
    }

    private func refreshOnce(includingExternalPorts: Bool) async -> [DiscoveredPort]? {
        guard !Task.isCancelled else { return nil }
        var snapshot: [DiscoveredPort]?
        refreshProjectNames()
        refreshBrowserHostnames()
        let completeLibrary = store.loadIssue == nil
        iconCache.refreshFavicons(for: projects, pruneMissing: completeLibrary)
        processManager.reconcile(projects: projects, pruneMissing: completeLibrary)

        do {
            let includeExternal = defaults.object(forKey: AppPreference.scanExternalPortsKey) as? Bool ?? true
            let pids = includeExternal || includingExternalPorts ? nil : Set(processManager.managedProjectIDsByPID().keys)
            let scanned = try await portScanner.scan(pids: pids, requireComplete: includingExternalPorts)
            guard !Task.isCancelled else { return nil }
            let annotated = annotate(scanned, managedProjectIDsByPID: processManager.managedProjectIDsByPID())
            snapshot = annotated
            let showExternal = defaults.object(forKey: AppPreference.scanExternalPortsKey) as? Bool ?? true
            discoveredPorts = applyPortPreferences(to: annotated.filter { port in
                (showExternal || port.isManaged) && !(port.projectId.map(processManager.isTerminating) ?? false)
            })
            if let pendingKillPort, !discoveredPorts.contains(where: {
                $0.id == pendingKillPort.id && $0.startedAt == pendingKillPort.startedAt && $0.projectId == pendingKillPort.projectId
            }) { self.pendingKillPort = nil }
            reconcileRunningStates()
            let faviconProjects = projects.filter { isProjectOnlineForGrouping($0) }.map { project in
                var destination = project
                destination.port = runtimeState(for: project).observedPort ?? project.port
                return destination
            }
            iconCache.refreshSiteFavicons(for: faviconProjects)
            if healthChecksEnabled, healthRefreshTask == nil, !Task.isCancelled {
                healthRefreshTask = Task {
                    await refreshReadinessStates()
                    if !Task.isCancelled { healthRefreshTask = nil }
                }
            }
            if !healthChecksEnabled {
                resetHealthStates()
            }
            scheduleCacheStateRefresh()
            await refreshProjectIdentities()
            guard !Task.isCancelled else { return nil }
            await logReader.rotateLargeLogs(at: projects.map { processManager.logURL(for: $0.id) })
            await refreshSelectedLog()
            guard !Task.isCancelled else { return nil }
            scanError = nil
        } catch {
            guard !Task.isCancelled else { return nil }
            scanError = error.localizedDescription
        }

        await refreshResourceMeasurements()
        guard !Task.isCancelled else { return nil }
        persistRuntimeSessions()
        lastUpdated = Date()
        updateMenuBarTitle()
        return snapshot
    }

    func chooseAndAddProject() {
        if let projectPanel {
            NSApp.activate(ignoringOtherApps: true)
            projectPanel.makeKeyAndOrderFront(nil)
            return
        }

        let shouldRestoreAccessory = !DockIconPreference.showDockIcon
        if shouldRestoreAccessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Add Project"
        panel.prompt = "Add"
        panel.message = "Choose the project folder that contains package.json."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = defaultProjectDirectoryURL()
        panel.level = .modalPanel
        projectPanel = panel

        panel.begin { [weak self] response in
            let selectedURL = panel.url

            Task { @MainActor in
                guard let self else {
                    if shouldRestoreAccessory {
                        NSApp.setActivationPolicy(.accessory)
                    }
                    return
                }

                self.projectPanel = nil

                if shouldRestoreAccessory {
                    NSApp.setActivationPolicy(.accessory)
                }

                guard response == .OK, let selectedURL else { return }
                let profiles = ProjectDetector.launchProfiles(in: selectedURL)
                if profiles.count > 1 {
                    self.presentWorkspaceApps(rootURL: selectedURL, profiles: profiles)
                } else {
                    await self.addProject(folderURL: selectedURL)
                }
            }
        }
    }

    func showWorkspaceApps(for project: LocalProject) {
        guard let rootPath = project.workspaceRootPath else { return }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        presentWorkspaceApps(rootURL: rootURL, profiles: ProjectDetector.launchProfiles(in: rootURL))
    }

    private func presentWorkspaceApps(rootURL: URL, profiles: [ProjectLaunchProfile]) {
        workspaceImportController = WorkspaceImportWindowController(
            workspace: WorkspaceImport(rootURL: rootURL, profiles: profiles, savedProjects: projects)
        ) { [weak self] selected in
            Task { await self?.addWorkspaceProfiles(selected, rootURL: rootURL) }
        }
        workspaceImportController?.present()
    }

    func addProject(folderURL: URL) async {
        let profiles = ProjectDetector.launchProfiles(in: folderURL)
        if !profiles.isEmpty {
            await addWorkspaceProfiles(profiles, rootURL: folderURL)
            return
        }
        let detection = ProjectDetector.detect(folderURL: folderURL, preferredPort: AppPreference.defaultPort)
        let listeners = (try? await portScanner.scan()) ?? discoveredPorts
        let folder = folderURL.resolvingSymlinksInPath().standardizedFileURL
        guard !projects.contains(where: { $0.folderURL.resolvingSymlinksInPath().standardizedFileURL.path == folder.path }),
              let port = importPort(for: folder, preferredPort: detection.defaultPort, listeners: listeners) else { return }
        let project = LocalProject(
            name: detection.name,
            profileName: primaryProfileName(for: detection.kind),
            path: folderURL.path,
            kind: detection.kind,
            packageManager: detection.packageManager,
            port: port,
            commandTemplate: detection.commandTemplate,
            healthPath: detection.suggestedPresets.first?.healthPath ?? "/",
            hostname: detection.hostname,
            openAfterStart: AppPreference.openBrowserAfterStart
        )

        projects.append(project)
        runtimeStates[project.id] = .stopped
        healthStates[project.id] = .unknown
        persist()
        updateMenuBarTitle()
        await refresh()
    }

    func addWorkspaceProfiles(_ profiles: [ProjectLaunchProfile], rootURL: URL) async {
        // Import can happen before the next periodic refresh. Read listeners now
        // so an already running app retains its port without restarting it.
        let listeners = (try? await portScanner.scan()) ?? discoveredPorts
        let name = ProjectDetector.packageName(in: rootURL) ?? rootURL.lastPathComponent
        let preferred = ProjectWorkspace.preferredProfile(in: rootURL, profiles: profiles)
        let ordered = profiles.sorted {
            if $0.id == preferred?.id, $1.id != preferred?.id { return true }
            if $1.id == preferred?.id { return false }
            return $0.relativePath < $1.relativePath
        }
        var portsExhausted = false
        for profile in ordered where !projects.contains(where: {
            $0.folderURL.resolvingSymlinksInPath().standardizedFileURL.path
                == profile.folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        }) {
            let detection = profile.detection
            guard let port = importPort(for: profile.folderURL, preferredPort: detection.defaultPort, listeners: listeners) else {
                portsExhausted = true
                break
            }
            let project = LocalProject(
                name: name,
                profileName: profile.relativePath == "." ? primaryProfileName(for: detection.kind) : profile.folderURL.lastPathComponent,
                path: profile.folderURL.path,
                kind: detection.kind,
                packageManager: detection.packageManager,
                port: port,
                commandTemplate: detection.commandTemplate,
                hostname: detection.hostname,
                workspaceRootPath: rootURL.path,
                openAfterStart: AppPreference.openBrowserAfterStart
            )
            projects.append(project)
            runtimeStates[project.id] = .stopped
            healthStates[project.id] = .unknown
        }
        persist()
        updateMenuBarTitle()
        await refresh()
        if portsExhausted { operationError = "All project ports are in use." }
    }

    func removeProject(_ project: LocalProject) {
        stopProject(project)
        processManager.removeLog(for: project.id)
        projects.removeAll { $0.id == project.id }
        discoveredPorts = annotate(discoveredPorts, managedProjectIDsByPID: processManager.managedProjectIDsByPID())
        for index in groups.indices {
            groups[index].projectIDs.removeAll { $0 == project.id }
        }
        runtimeStates.removeValue(forKey: project.id)
        projectIdentities.removeValue(forKey: project.id)
        projectBrowserHostnames.removeValue(forKey: project.id)
        healthStates.removeValue(forKey: project.id)
        lastHealthStates.removeValue(forKey: project.id)
        invalidateReadinessCheck(for: project.id)
        preflightResults.removeValue(forKey: project.id)
        cleanRestartStates.removeValue(forKey: project.id)
        cacheStates.removeValue(forKey: project.id)
        resourceStates.removeValue(forKey: project.id)
        installationStates.removeValue(forKey: project.id)
        nodeInstallationStates.removeValue(forKey: project.id)
        clearFailureHistory(for: project)
        restartBudgets.removeValue(forKey: project.id)
        if selectedLogProjectID == project.id {
            selectedLogProjectID = nil
        }
        persist()
        updateMenuBarTitle()
    }

    func startProject(_ project: LocalProject, recordsUsage: Bool = true,
                      withDependencies: Bool = true, prechecked: PreflightResult? = nil) async {
        guard projects.contains(where: { $0.id == project.id }), !Task.isCancelled else { return }
        stopVerificationTasks.removeValue(forKey: project.id)?.cancel()
        if recordsUsage {
            resetAutomaticRestarts(for: project.id)
            recordProjectUse(project)
        }

        if isInstallingDependencies(for: project) || isInstallingNode(for: project)
            || cleaningFolders.contains(project.folderURL.resolvingSymlinksInPath().standardizedFileURL.path) { return }

        let state = runtimeState(for: project)
        if state.status == .running || state.status == .warmingUp || state.status == .responseDelayed || state.status == .starting || state.status == .portMismatch || state.status == .noPort || state.status == .noResponse {
            return
        }

        if withDependencies, !project.reliability.dependencyProjectIDs.isEmpty || !project.reliability.composeServices.isEmpty {
            await startDependencyChain(for: project)
            return
        }

        guard projectLaunchRequests[project.id] == nil else { return }
        let request = UUID()
        projectLaunchRequests[project.id] = request
        defer {
            if projectLaunchRequests[project.id] == request {
                projectLaunchRequests.removeValue(forKey: project.id)
                preflightTasks.removeValue(forKey: project.id)
                if Task.isCancelled { pendingBrowserOpens.remove(project.id) }
                if Task.isCancelled, runtimeStates[project.id]?.status == .starting,
                   !processManager.isRunning(projectId: project.id) {
                    setState(for: project.id, status: .stopped)
                }
            }
        }

        if processManager.isTerminating(project.id) {
            let stopped = await processManager.waitForTermination(of: project.id)
            guard !Task.isCancelled, projectLaunchRequests[project.id] == request else { return }
            guard stopped else {
                operationError = "The previous process is still running."
                return
            }
            guard let snapshot = await requestRefresh(includingExternalPorts: true),
                  !Task.isCancelled, projectLaunchRequests[project.id] == request else { return }
            if let conflict = snapshot.first(where: { $0.port == project.port && $0.projectId != project.id }) {
                setState(for: project.id, status: .portBusy, message: "\(conflict.displayOwner) owns port \(project.port).")
                return
            }
            if let owner = snapshot.first(where: { $0.projectId == project.id && !$0.isManaged }),
               !discoveredPorts.contains(where: { $0.id == owner.id }) {
                operationError = "A process is still running for this project."
                return
            }
        }
        if let owner = matchingProjectPortOwner(for: project) {
            if project.openAfterStart { pendingBrowserOpens.insert(project.id) }
            markRunning(project, owner: owner)
            await checkReadiness(for: project, force: true)
            return
        }

        if let owner = matchingProjectProcessOwner(for: project) {
            markPortMismatch(project, owner: owner)
            return
        }

        guard conflictOwner(for: project) == nil else {
            setState(
                for: project.id,
                status: .portBusy,
                message: "Port \(project.port) is already in use."
            )
            return
        }

        let preflight: PreflightResult
        setState(for: project.id, status: .starting, message: "Checking launch requirements…")
        if let prechecked { preflight = prechecked } else {
            let checker = preflightChecker
            let task = Task { await checker.check(project) }
            preflightTasks[project.id] = task
            preflight = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        guard !Task.isCancelled, projectLaunchRequests[project.id] == request,
              projects.contains(where: { $0.id == project.id }) else { return }
        preflightResults[project.id] = preflight
        if !preflight.isClear {
            setState(for: project.id, status: .crashed, message: preflight.summary)
            notificationService.notify(title: "\(project.displayName) blocked", body: preflight.summary)
            return
        }

        setState(
            for: project.id,
            status: .starting,
            ownership: .managed,
            message: project.resolvedCommand
        )

        if project.openAfterStart { pendingBrowserOpens.insert(project.id) }
        do {
            try await processManager.start(project: project, launchEnvironment: preflight.launchEnvironment)
        } catch is CancellationError {
            if projectLaunchRequests[project.id] == request { pendingBrowserOpens.remove(project.id) }
            return
        } catch {
            guard projectLaunchRequests[project.id] == request else { return }
            pendingBrowserOpens.remove(project.id)
            setState(for: project.id, status: .crashed, message: error.localizedDescription)
            return
        }

        try? await Task.sleep(nanoseconds: 900_000_000)
        guard !Task.isCancelled, projectLaunchRequests[project.id] == request else { return }
        await refresh()
    }

    private func openBrowserIfReady(for project: LocalProject) {
        guard runtimeStates[project.id]?.status == .running,
              pendingBrowserOpens.remove(project.id) != nil, project.openAfterStart else { return }
        openInBrowser(project, recordsUsage: false)
    }

    func stopProject(_ project: LocalProject) {
        stopProject(project, schedulesVerification: true)
    }

    func cancelMaintenance(for id: UUID) {
        if maintenanceRequests.removeValue(forKey: id) != nil { cleanRestartStates.removeValue(forKey: id) }
    }

    private func stopProject(_ project: LocalProject, schedulesVerification: Bool) {
        pendingBrowserOpens.remove(project.id)
        cancelReliabilityOperations(for: project.id)
        if processManager.isRunning(projectId: project.id) || processManager.isStarting(projectId: project.id) {
            processManager.stop(projectId: project.id)
        } else if let owner = Self.externalProcessToStop(for: project, in: discoveredPorts),
                  processManager.projectId(containing: owner.pid) == nil,
                  Self.externalOwner(of: discoveredPorts.filter { $0.pid == owner.pid }, byFolder: projectsByFolder)?.id == project.id,
                  let startedAt = owner.startedAt, ProcessTree.startDate(of: owner.pid) == startedAt {
            processManager.beginTermination(pid: owner.pid, startedAt: startedAt, for: project.id)
        } else if discoveredPorts.contains(where: { $0.projectId == project.id }) {
            operationError = "Could not identify a single process to stop. Check the project's ports."
            if schedulesVerification { Task { await refresh() } }
            return
        }

        operationError = nil
        discoveredPorts.removeAll { $0.projectId == project.id }
        runtimeStates[project.id] = .stopped
        healthStates[project.id] = .unknown
        invalidateReadinessCheck(for: project.id)
        persistRuntimeSessions()
        updateMenuBarTitle()
        if schedulesVerification {
            stopVerificationTasks[project.id] = Task { [weak self] in
                guard let self else { return }
                defer { if !Task.isCancelled { self.stopVerificationTasks.removeValue(forKey: project.id) } }
                await self.verifyStopped(project)
            }
        }
    }

    private func verifyStopped(_ project: LocalProject) async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled, projects.contains(where: { $0.id == project.id }) else { return }
        guard let ports = await requestRefresh(includingExternalPorts: true), !Task.isCancelled,
              projects.contains(where: { $0.id == project.id }), !processManager.isRunning(projectId: project.id) else { return }

        let owners = ports.filter { $0.projectId == project.id }
        guard let owner = owners.first(where: { $0.port == project.port }) ?? owners.first else {
            runtimeStates[project.id] = .stopped
            healthStates[project.id] = .unknown
            invalidateReadinessCheck(for: project.id)
            persistRuntimeSessions()
            updateMenuBarTitle()
            return
        }

        // A newly discovered listener may belong to a later launch. Only report its state.
        if owner.port == project.port { markRunning(project, owner: owner) }
        else { markPortMismatch(project, owner: owner) }
        appendLog(projectId: project.id, text: "A process is listening on \(owner.port) after Stop.")

        persistRuntimeSessions()
        updateMenuBarTitle()
    }

    func restartProject(_ project: LocalProject) async {
        guard !isInstallingDependencies(for: project), !isInstallingNode(for: project),
              projects.contains(where: { $0.id == project.id }) else { return }
        resetAutomaticRestarts(for: project.id)
        guard cleanRestartStates[project.id]?.isActive != true else { return }
        recordProjectUse(project)

        let keepOnlineGroup = isProjectOnlineForGrouping(project)
        setCleanRestartState(
            for: project,
            phase: .stopping,
            message: "Restarting project",
            progress: 0.16,
            keepsOnlineGroup: keepOnlineGroup,
            operation: .restart
        )
        stopProject(project, schedulesVerification: false)
        let request = UUID()
        maintenanceRequests[project.id] = request
        defer { if maintenanceRequests[project.id] == request { maintenanceRequests.removeValue(forKey: project.id) } }
        guard await canContinueMaintenance(for: project, request: request, operation: .restart) else { return }
        setCleanRestartState(
            for: project,
            phase: .starting,
            message: "Starting project",
            progress: 0.68,
            keepsOnlineGroup: keepOnlineGroup,
            operation: .restart
        )
        await startProject(project, recordsUsage: false)
        guard maintenanceRequests[project.id] == request, !Task.isCancelled else { return }

        let state = runtimeState(for: project)
        guard state.status == .starting || state.status == .running || state.status == .warmingUp || state.status == .responseDelayed || state.status == .portMismatch || state.status == .noPort else {
            let message = state.lastMessage ?? "Project did not start."
            setCleanRestartState(
                for: project,
                phase: .failed,
                message: message,
                progress: 1,
                keepsOnlineGroup: false,
                operation: .restart
            )
            clearCleanRestartStateLater(for: project.id)
            return
        }

        setCleanRestartState(
            for: project,
            phase: .done,
            message: "Restarted",
            progress: 1,
            keepsOnlineGroup: keepOnlineGroup,
            operation: .restart
        )
        clearCleanRestartStateLater(for: project.id)
    }

    private func canContinueMaintenance(for project: LocalProject, request: UUID, operation: ProjectOperationKind) async -> Bool {
        let stopped = await processManager.waitForTermination(of: project.id)
        guard maintenanceRequests[project.id] == request, !Task.isCancelled else { return false }
        let snapshot = await requestRefresh(includingExternalPorts: true)
        guard maintenanceRequests[project.id] == request, !Task.isCancelled else { return false }
        let folder = project.folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        let profiles = operation == .cacheClean
            ? projects.filter { $0.folderURL.resolvingSymlinksInPath().standardizedFileURL.path == folder }
            : [project]
        let ids = Set(profiles.map(\.id))
        let message: String
        if !stopped {
            message = "The previous process is still running."
        } else if let snapshot {
            let hasListener = snapshot.contains { port in
                if operation == .restart && port.port == project.port { return true }
                if let id = port.projectId { return ids.contains(id) }
                guard operation == .cacheClean, let cwd = port.workingDirectory else { return false }
                let path = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
                return path == folder || path.hasPrefix(folder + "/")
            }
            let busy = profiles.contains { profile in
                processManager.isRunning(projectId: profile.id) || processManager.isStarting(projectId: profile.id)
                    || projectLaunchRequests[profile.id] != nil || processManager.isTerminating(profile.id)
                    || (profile.id != project.id && maintenanceRequests[profile.id] != nil)
            }
            guard hasListener || busy || cleaningFolders.contains(folder) else { return true }
            message = operation == .cacheClean
                ? "A process or profile is still using this folder. Stop it before cleaning the cache."
                : "The project is still running or its port is in use."
        } else {
            message = scanError ?? "Could not verify that the project stopped."
        }
        setCleanRestartState(for: project, phase: .failed, message: message, progress: 1, operation: operation)
        appendLog(projectId: project.id, text: message)
        clearCleanRestartStateLater(for: project.id)
        return false
    }

    func cleanRestartProject(_ project: LocalProject) async {
        guard project.kind.supportsCleanRestart, !isInstallingDependencies(for: project), !isInstallingNode(for: project),
              projects.contains(where: { $0.id == project.id }) else { return }
        guard cleanRestartStates[project.id]?.isActive != true else { return }
        recordProjectUse(project)

        let shouldRestartAfterClean = projectIsRunningOrStarting(project)
        let keepOnlineGroup = isProjectOnlineForGrouping(project)
        if shouldRestartAfterClean {
            setCleanRestartState(
                for: project,
                phase: .stopping,
                message: "Stopping project",
                progress: 0.12,
                keepsOnlineGroup: keepOnlineGroup
            )
            appendLog(projectId: project.id, text: "Cache clean: stopping project.")
            stopProject(project, schedulesVerification: false)
        }
        let request = UUID()
        maintenanceRequests[project.id] = request
        defer { if maintenanceRequests[project.id] == request { maintenanceRequests.removeValue(forKey: project.id) } }
        guard await canContinueMaintenance(for: project, request: request, operation: .cacheClean) else { return }

        setCleanRestartState(
            for: project,
            phase: .cleaning,
            message: "Cleaning \(project.kind.displayName) cache",
            progress: shouldRestartAfterClean ? 0.42 : 0.68,
            keepsOnlineGroup: keepOnlineGroup
        )

        do {
            let removedPaths = try await removeCleanCaches(for: project)
            guard maintenanceRequests[project.id] == request, !Task.isCancelled else { return }
            if removedPaths.isEmpty {
                appendLog(projectId: project.id, text: "Cache clean: no cache folders found.")
            } else {
                appendLog(projectId: project.id, text: "Cache clean: removed \(removedPaths.joined(separator: ", ")).")
            }
            await refreshCacheState(for: project, force: true)
        } catch {
            guard maintenanceRequests[project.id] == request, !Task.isCancelled else { return }
            setCleanRestartState(
                for: project,
                phase: .failed,
                message: error.localizedDescription,
                progress: 1,
                keepsOnlineGroup: false
            )
            if shouldRestartAfterClean {
                setState(for: project.id, status: .crashed, message: error.localizedDescription)
            }
            appendLog(projectId: project.id, text: "Cache clean failed: \(error.localizedDescription)")
            clearCleanRestartStateLater(for: project.id)
            return
        }
        guard maintenanceRequests[project.id] == request, !Task.isCancelled else { return }

        guard shouldRestartAfterClean else {
            setCleanRestartState(
                for: project,
                phase: .done,
                message: "Cache cleaned",
                progress: 1,
                keepsOnlineGroup: keepOnlineGroup
            )
            appendLog(projectId: project.id, text: "Cache clean complete.")
            clearCleanRestartStateLater(for: project.id)
            return
        }

        setCleanRestartState(
            for: project,
            phase: .starting,
            message: "Starting project",
            progress: 0.72,
            keepsOnlineGroup: keepOnlineGroup
        )
        await startProject(project, recordsUsage: false)
        guard maintenanceRequests[project.id] == request, !Task.isCancelled else { return }

        if healthChecksEnabled {
            setCleanRestartState(
                for: project,
                phase: .checking,
                message: "Waiting for response",
                progress: 0.9,
                keepsOnlineGroup: keepOnlineGroup
            )
            await checkReadiness(for: project, force: true)
            guard maintenanceRequests[project.id] == request, !Task.isCancelled else { return }
        }

        let state = runtimeState(for: project)
        guard state.status == .starting || state.status == .running || state.status == .warmingUp || state.status == .responseDelayed || state.status == .portMismatch || state.status == .noPort else {
            let message = state.lastMessage ?? "Project did not start."
            setCleanRestartState(
                for: project,
                phase: .failed,
                message: message,
                progress: 1,
                keepsOnlineGroup: false
            )
            appendLog(projectId: project.id, text: "Cache clean restart failed: \(message)")
            clearCleanRestartStateLater(for: project.id)
            return
        }

        setCleanRestartState(
            for: project,
            phase: .done,
            message: "Cache cleaned",
            progress: 1,
            keepsOnlineGroup: keepOnlineGroup
        )
        appendLog(projectId: project.id, text: "Cache clean complete.")
        clearCleanRestartStateLater(for: project.id)
    }

    func startAllProjects() async {
        let generation = bulkStartGeneration
        for project in projects {
            guard generation == bulkStartGeneration, !Task.isCancelled else { return }
            await startProject(project, recordsUsage: false)
        }
    }

    func startAutoStartProjects() async {
        let generation = bulkStartGeneration
        for project in projects where project.autoStart {
            guard generation == bulkStartGeneration, !Task.isCancelled else { return }
            await startProject(project, recordsUsage: false)
        }
    }

    func startAutoStartGroups() async {
        let generation = bulkStartGeneration
        for group in groups where group.autoStart {
            guard generation == bulkStartGeneration, !Task.isCancelled else { return }
            await startGroup(group)
        }
    }

    func stopAllProjects() {
        pendingBrowserOpens.removeAll()
        let pending = Set(dependencyLaunchTasks.keys).union(projectLaunchRequests.keys).union(maintenanceRequests.keys)
        cancelAllReliabilityOperations()
        let stoppedProjectIDs = processManager.stopAll().union(pending)
        discoveredPorts.removeAll { $0.projectId.map(stoppedProjectIDs.contains) == true }
        for project in projects where stoppedProjectIDs.contains(project.id) {
            runtimeStates[project.id] = .stopped
            invalidateReadinessCheck(for: project.id)
        }
        persistRuntimeSessions()
        updateMenuBarTitle()
    }

    func requestKillPort(_ port: DiscoveredPort) async {
        if AppPreference.safeKill, port.safety != .normal,
           (pendingKillPort?.id != port.id || pendingKillPort?.startedAt != port.startedAt
            || pendingKillPort?.projectId != port.projectId) {
            pendingKillPort = port
            return
        }

        await killPort(port)
    }

    func killPort(_ port: DiscoveredPort) async {
        pendingKillPort = nil

        guard let startedAt = port.startedAt else {
            operationError = "Could not verify the identity of the process on port \(port.port)."
            return
        }
        guard ProcessTree.startDate(of: port.pid) == startedAt,
              discoveredPorts.contains(where: {
                  $0.pid == port.pid && $0.port == port.port && $0.projectId == port.projectId && $0.startedAt == startedAt
              }) else {
            await refresh()
            return
        }
        let managedID = processManager.projectId(containing: port.pid)
        if port.isManaged || managedID != nil {
            guard let id = managedID, port.projectId == id, port.isManaged,
                  let project = projects.first(where: { $0.id == id }) else {
                await refresh()
                return
            }
            stopProject(project)
            return
        }

        do {
            try await portKiller.stop(pid: port.pid, startedAt: startedAt)
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }

        await refresh()
    }

    func pinPort(_ port: DiscoveredPort) {
        pinnedPortNames[port.port] = port.displayOwner
        ignoredPorts.remove(port.port)
        persistPortPreferences()
        Task { await refresh() }
    }

    func unpinPort(_ port: DiscoveredPort) {
        pinnedPortNames.removeValue(forKey: port.port)
        persistPortPreferences()
        Task { await refresh() }
    }

    func ignorePort(_ port: DiscoveredPort) {
        ignoredPorts.insert(port.port)
        pinnedPortNames.removeValue(forKey: port.port)
        persistPortPreferences()
        Task { await refresh() }
    }

    func showIgnoredPort(_ port: Int) {
        ignoredPorts.remove(port)
        persistPortPreferences()
        Task { await refresh() }
    }

    func openInBrowser(_ project: LocalProject, recordsUsage: Bool = true) {
        if recordsUsage {
            recordProjectUse(project)
        }
        guard let url = project.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    func browserHostnames(for project: LocalProject) -> [String] {
        let defaultHost = LocalHostname.normalize(project.hostname) ?? "localhost"
        return [defaultHost] + (projectBrowserHostnames[project.id] ?? []).filter { $0 != defaultHost }
    }

    func browserURL(for project: LocalProject, hostname: String) -> URL? {
        guard let host = LocalHostname.normalize(hostname), browserHostnames(for: project).contains(host) else { return nil }
        var destination = project
        destination.hostname = host
        return destination.localURL(port: runtimeState(for: project).observedPort ?? project.port)
    }

    func openBrowserHostname(_ project: LocalProject, hostname: String) {
        guard let url = browserURL(for: project, hostname: hostname) else { return }
        recordProjectUse(project)
        NSWorkspace.shared.open(url)
    }

    func openPortInBrowser(_ port: DiscoveredPort) {
        guard let url = URL(string: "http://localhost:\(port.port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openLoopback(_ project: LocalProject) {
        recordProjectUse(project)
        guard let url = URL(string: "http://127.0.0.1:\(project.port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openObservedPort(_ project: LocalProject) {
        recordProjectUse(project)
        guard
            let observedPort = runtimeState(for: project).observedPort,
            let url = project.localURL(port: observedPort)
        else {
            openInBrowser(project, recordsUsage: false)
            return
        }

        NSWorkspace.shared.open(url)
    }

    func copyURL(_ project: LocalProject, network: Bool = false) {
        if network { copyToPasteboard("http://\(localNetworkAddress()):\(project.port)") }
        else { copyToPasteboard(project.localURL?.absoluteString ?? "") }
    }

    func copyObservedURL(_ project: LocalProject) {
        let port = runtimeState(for: project).observedPort ?? project.port
        copyToPasteboard(project.localURL(port: port)?.absoluteString ?? "")
    }

    func copyURL(_ port: DiscoveredPort, network: Bool = false) {
        let host = network ? localNetworkAddress() : "localhost"
        copyToPasteboard("http://\(host):\(port.port)")
    }

    func revealProject(_ project: LocalProject) {
        NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
    }

    func updatePort(for project: LocalProject, port: Int) {
        updateProject(project) { mutable in
            mutable.port = min(65_535, max(1_024, port))
        }
    }

    func useNextAvailablePort(for project: LocalProject) {
        guard let port = nextAvailablePort(startingAt: project.port + 1, excluding: project.id) else { return }
        updatePort(for: project, port: port)
    }

    func useObservedPort(for project: LocalProject) {
        guard let observedPort = runtimeState(for: project).observedPort else { return }
        updatePort(for: project, port: observedPort)
    }

    func updateCommandTemplate(for project: LocalProject, command: String) {
        updateProject(project) { mutable in
            mutable.commandTemplate = command
        }
    }

    func updateAutoStart(for project: LocalProject, enabled: Bool) {
        updateProject(project) { mutable in
            mutable.autoStart = enabled
        }
    }

    func updateOpenAfterStart(for project: LocalProject, enabled: Bool) {
        if !enabled { pendingBrowserOpens.remove(project.id) }
        updateProject(project) { mutable in
            mutable.openAfterStart = enabled
        }
    }

    func updatePackageManager(for project: LocalProject, packageManager: PackageManager) {
        updateProject(project) { mutable in
            mutable.commandTemplate = ProjectDetector.switchPackageManager(
                in: mutable.commandTemplate, from: mutable.packageManager, to: packageManager
            )
            mutable.packageManager = packageManager
        }
    }

    func updateReliability(for project: LocalProject, settings: ProjectReliabilitySettings) {
        updateProject(project) { $0.reliability = settings.validated }
        resetAutomaticRestarts(for: project.id)
    }

    func updateHealthPath(for project: LocalProject, healthPath: String) {
        updateProject(project) { mutable in
            mutable.healthPath = healthPath.isEmpty ? "/" : healthPath
        }
    }

    func updateHostname(for project: LocalProject, hostname: String) {
        guard let hostname = LocalHostname.normalize(hostname) else { return }
        updateProject(project) { $0.hostname = hostname }
    }

    func updateAutoRestart(for project: LocalProject, enabled: Bool) {
        if !enabled { resetAutomaticRestarts(for: project.id) }
        updateProject(project) { mutable in
            mutable.autoRestart = enabled
        }
    }

    func updateHealthChecks(enabled: Bool) async {
        healthChecksEnabled = enabled
        if enabled {
            await refreshReadinessStates(force: true)
        } else {
            resetHealthStates()
        }
    }

    func applyPreset(_ preset: CommandPreset, to project: LocalProject) {
        let nextPort = preset.port.flatMap { nextAvailablePort(startingAt: $0, excluding: project.id) }
        guard preset.port == nil || nextPort != nil else { return }
        updateProject(project) { mutable in
            mutable.kind = preset.kind
            mutable.commandTemplate = preset.commandTemplate
            mutable.healthPath = preset.healthPath
            if let nextPort { mutable.port = nextPort }
            mutable.profileName = preset.title
        }
    }

    func duplicateProfile(from project: LocalProject, preset: CommandPreset? = nil) {
        let presetPort = preset?.port ?? project.port + 1
        guard let nextPort = nextAvailablePort(startingAt: presetPort, excluding: nil) else { return }
        var clone = project
        clone.id = UUID()
        clone.profileName = preset?.title ?? nextProfileName(for: project)
        clone.kind = preset?.kind ?? project.kind
        clone.port = nextPort
        clone.commandTemplate = preset?.commandTemplate ?? project.commandTemplate
        clone.healthPath = preset?.healthPath ?? project.healthPath
        clone.autoStart = false
        clone.isQuickLaunchPinned = false
        clone.quickLaunchOrder = nil
        clone.lastUsedAt = nil
        clone.createdAt = Date()
        clone.updatedAt = Date()

        projects.append(clone)
        runtimeStates[clone.id] = .stopped
        healthStates[clone.id] = .unknown
        persist()
        Task { await refresh() }
    }

    func addWorkspaceGroup() {
        let base = "Workspace"
        let index = groups.count + 1
        groups.append(WorkspaceGroup(name: "\(base) \(index)", projectIDs: projects.map(\.id)))
        persist()
    }

    func removeWorkspaceGroup(_ group: WorkspaceGroup) {
        groups.removeAll { $0.id == group.id }
        persist()
    }

    func updateWorkspaceGroupName(_ group: WorkspaceGroup, name: String) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = name.isEmpty ? "Workspace" : name
        persist()
    }

    func updateWorkspaceGroupAutoStart(_ group: WorkspaceGroup, enabled: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].autoStart = enabled
        persist()
    }

    func toggleProject(_ project: LocalProject, in group: WorkspaceGroup, enabled: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        if enabled {
            if !groups[index].projectIDs.contains(project.id) {
                groups[index].projectIDs.append(project.id)
            }
        } else {
            groups[index].projectIDs.removeAll { $0 == project.id }
        }
        persist()
    }

    func startGroup(_ group: WorkspaceGroup) async {
        let request = UUID(), generation = bulkStartGeneration
        groupStartRequests[group.id] = request
        defer { if groupStartRequests[group.id] == request { groupStartRequests.removeValue(forKey: group.id) } }
        for project in projects where group.projectIDs.contains(project.id) {
            guard groupStartRequests[group.id] == request, generation == bulkStartGeneration, !Task.isCancelled else { return }
            await startProject(project, recordsUsage: false)
        }
    }

    func stopGroup(_ group: WorkspaceGroup) {
        groupStartRequests.removeValue(forKey: group.id)
        for project in projects where group.projectIDs.contains(project.id) {
            stopProject(project)
        }
    }

    var quickLaunchProjects: [LocalProject] {
        projects
            .enumerated()
            .sorted { lhs, rhs in
                let lhsProject = lhs.element
                let rhsProject = rhs.element

                if lhsProject.isQuickLaunchPinned != rhsProject.isQuickLaunchPinned {
                    return lhsProject.isQuickLaunchPinned
                }

                if lhsProject.isQuickLaunchPinned {
                    let lhsOrder = lhsProject.quickLaunchOrder ?? .max
                    let rhsOrder = rhsProject.quickLaunchOrder ?? .max
                    if lhsOrder != rhsOrder {
                        return lhsOrder < rhsOrder
                    }
                } else if lhsProject.lastUsedAt != rhsProject.lastUsedAt {
                    switch (lhsProject.lastUsedAt, rhsProject.lastUsedAt) {
                    case let (lhsDate?, rhsDate?):
                        return lhsDate > rhsDate
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        break
                    }
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func setQuickLaunchPinned(_ project: LocalProject, pinned: Bool) {
        guard projects.contains(where: { $0.id == project.id }) else { return }

        var pinnedIDs = orderedPinnedProjectIDs
        pinnedIDs.removeAll { $0 == project.id }
        if pinned {
            pinnedIDs.append(project.id)
        }

        applyQuickLaunchPinOrder(pinnedIDs)
        persist()
    }

    @discardableResult
    func moveQuickLaunchProject(_ sourceProjectID: UUID, before targetProjectID: UUID) -> Bool {
        guard sourceProjectID != targetProjectID else { return false }
        guard projects.contains(where: { $0.id == sourceProjectID }) else { return false }
        guard projects.contains(where: { $0.id == targetProjectID }) else { return false }

        var pinnedIDs = orderedPinnedProjectIDs
        pinnedIDs.removeAll { $0 == sourceProjectID }

        if let targetIndex = pinnedIDs.firstIndex(of: targetProjectID) {
            pinnedIDs.insert(sourceProjectID, at: targetIndex)
        } else {
            pinnedIDs.append(sourceProjectID)
        }

        applyQuickLaunchPinOrder(pinnedIDs)
        persist()
        return true
    }

    func recordProjectUse(_ project: LocalProject, at date: Date = Date()) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].lastUsedAt = date
        persist()
    }

    func runtimeState(for project: LocalProject) -> ProjectRuntimeState {
        var state = runtimeStates[project.id] ?? .stopped

        if
            state.status != .running,
            state.status != .starting,
            state.status != .portMismatch,
            state.status != .noPort,
            state.status != .noResponse,
            let owner = conflictOwner(for: project)
        {
            state.status = .portBusy
            state.pid = owner.pid
            state.lastMessage = "\(owner.displayOwner) owns port \(project.port)"
        }

        return state
    }

    func logs(for project: LocalProject) -> [String] {
        runtimeStates[project.id]?.logs ?? []
    }

    func clearLogs(for project: LocalProject) {
        logRevision &+= 1
        processManager.clearLog(for: project.id)
        var state = runtimeStates[project.id] ?? .stopped
        state.logs.removeAll()
        runtimeStates[project.id] = state
    }

    func copyLogs(for project: LocalProject) {
        Task {
            let url = processManager.logLocation(for: project.id)
            let lines = await logReader.lines(at: url) ?? logs(for: project)
            copyToPasteboard(lines.joined(separator: "\n"))
        }
    }

    func updateMenuBarTitle() {
        let displayModeRaw = defaults.string(forKey: MenuBarDisplayMode.storageKey)
        let displayMode = displayModeRaw.flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .count
        let running = projects.filter {
            let status = runtimeState(for: $0).status
            return status == .running || status == .warmingUp || status == .responseDelayed
        }.count
        let externalCount = AppPreference.showExternalInMenuBar ? externalPorts.count : 0

        menuBarTitle = MenuBarTitle(
            runningCount: running,
            totalCount: projects.count,
            externalCount: externalCount,
            displayMode: displayMode
        )
    }

    var externalPorts: [DiscoveredPort] {
        primaryVisiblePorts.filter { !$0.isManaged }
    }

    var visiblePorts: [DiscoveredPort] {
        discoveredPorts.filter { !$0.isIgnored }
    }

    var primaryVisiblePorts: [DiscoveredPort] {
        visiblePorts.filter { port in
            !port.isManaged && (port.pinnedName != nil || !port.isSystemOrEmulatorPort)
        }
    }

    var systemVisiblePorts: [DiscoveredPort] {
        visiblePorts.filter { port in
            !port.isManaged && port.pinnedName == nil && port.isSystemOrEmulatorPort
        }
    }

    var visiblePortGroups: [DiscoveredPortGroup] {
        Self.groupPorts(primaryVisiblePorts)
    }

    var systemPortGroups: [DiscoveredPortGroup] {
        Self.groupPorts(systemVisiblePorts)
    }

    var pinnedPorts: [DiscoveredPort] {
        visiblePorts.filter { $0.pinnedName != nil }
    }

    static func groupPorts(_ ports: [DiscoveredPort]) -> [DiscoveredPortGroup] {
        let grouped = Dictionary(grouping: ports, by: groupKey(for:))

        return grouped.compactMap { key, groupedPorts in
            guard let primary = primaryPort(in: groupedPorts) else { return nil }
            let sortedPorts = groupedPorts.sorted { lhs, rhs in
                if lhs.port == rhs.port { return lhs.pid < rhs.pid }
                return lhs.port < rhs.port
            }

            return DiscoveredPortGroup(
                key: key,
                title: primary.displayOwner,
                primaryPort: primary,
                ports: sortedPorts
            )
        }
        .sorted { lhs, rhs in
            if lhs.primaryPort.port == rhs.primaryPort.port {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.primaryPort.port < rhs.primaryPort.port
        }
    }

    func conflictOwner(for project: LocalProject) -> DiscoveredPort? {
        discoveredPorts.first { port in
            port.port == project.port && port.projectId != project.id
        }
    }

    private func matchingProjectPortOwner(for project: LocalProject) -> DiscoveredPort? {
        discoveredPorts.first { port in
            port.port == project.port && port.projectId == project.id
        }
    }

    private func matchingProjectProcessOwner(for project: LocalProject) -> DiscoveredPort? {
        matchingProjectPortOwner(for: project) ?? discoveredPorts.first { $0.projectId == project.id }
    }

    static func externalProcessToStop(for project: LocalProject, in ports: [DiscoveredPort]) -> DiscoveredPort? {
        let listeners = ports.filter { $0.projectId == project.id && !$0.isManaged }
        let expected = listeners.filter { $0.port == project.port }
        let candidates = expected.isEmpty ? listeners : expected
        guard Set(candidates.map(\.pid)).count == 1 else { return nil }
        return candidates.first
    }

    private func projectIsRunningOrStarting(_ project: LocalProject) -> Bool {
        let state = runtimeState(for: project)
        switch state.status {
        case .running, .warmingUp, .responseDelayed, .starting, .portMismatch, .noPort, .noResponse:
            return true
        case .stopped, .portBusy, .crashed:
            break
        }

        return processManager.isRunning(projectId: project.id)
            || matchingProjectPortOwner(for: project) != nil
            || matchingProjectProcessOwner(for: project) != nil
    }

    func isProjectOnlineForGrouping(_ project: LocalProject) -> Bool {
        if cleanRestartStates[project.id]?.keepsOnlineGroup == true {
            return true
        }

        switch runtimeState(for: project).status {
        case .running, .warmingUp, .responseDelayed, .portMismatch:
            return true
        case .starting, .noPort, .noResponse, .stopped, .portBusy, .crashed:
            return false
        }
    }

    private var projectsByFolder: [String: [LocalProject]] {
        Dictionary(grouping: projects) { $0.folderURL.resolvingSymlinksInPath().standardizedFileURL.path }
    }

    static func externalOwner(of listeners: [DiscoveredPort], byFolder: [String: [LocalProject]]) -> LocalProject? {
        guard let directory = listeners.first?.workingDirectory else { return nil }
        var folder = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
        while true {
            if let profiles = byFolder[folder.path] {
                if profiles.count == 1 { return profiles[0] }
                let ports = Set(listeners.map(\.port))
                let matching = profiles.filter { ports.contains($0.port) }
                return matching.count == 1 ? matching[0] : nil
            }
            if folder.path == "/" { return nil }
            let parent = folder.deletingLastPathComponent()
            guard !parent.path.isEmpty, parent.path != folder.path else { return nil }
            folder = parent
        }
    }

    private func updateProject(_ project: LocalProject, mutate: (inout LocalProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let previous = projects[index]
        mutate(&projects[index])
        if previous.path != projects[index].path || previous.port != projects[index].port || previous.commandTemplate != projects[index].commandTemplate
            || previous.packageManager != projects[index].packageManager || previous.reliability != projects[index].reliability {
            pendingBrowserOpens.remove(project.id)
            cancelReliabilityOperations(for: project.id)
            processManager.cancelPendingStart(for: project.id)
            if runtimeStates[project.id]?.status == .starting, !processManager.isRunning(projectId: project.id) {
                runtimeStates[project.id] = .stopped
            }
        }
        if previous.healthURL != projects[index].healthURL || previous.path != projects[index].path {
            invalidateReadinessCheck(for: project.id)
            runtimeStates[project.id]?.readiness = ProjectReadinessState()
            healthStates[project.id] = .unknown
        }
        projects[index].updatedAt = Date()
        persist()
        updateMenuBarTitle()
        Task { await refresh() }
    }

    private func refreshProjectNames() {
        var didChange = false

        for index in projects.indices {
            let nameFolder = projects[index].workspaceRootPath.map { URL(fileURLWithPath: $0) } ?? projects[index].folderURL
            guard let detectedName = ProjectDetector.packageName(in: nameFolder) else {
                continue
            }
            guard projects[index].name != detectedName else { continue }

            projects[index].name = detectedName
            projects[index].updatedAt = Date()
            didChange = true
        }

        if didChange {
            persist()
        }
    }

    private func refreshBrowserHostnames() {
        let hosts = Dictionary(uniqueKeysWithValues: projects.map {
            ($0.id, LocalHostname.detectedHosts(in: $0.folderURL))
        })
        if hosts != projectBrowserHostnames { projectBrowserHostnames = hosts }
    }

    private func setCleanRestartState(
        for project: LocalProject,
        phase: CleanRestartPhase,
        message: String,
        progress: Double,
        keepsOnlineGroup: Bool = false,
        operation: ProjectOperationKind = .cacheClean
    ) {
        cleanRestartStates[project.id] = CleanRestartState(
            operation: operation,
            phase: phase,
            message: message,
            progress: min(max(progress, 0), 1),
            keepsOnlineGroup: keepsOnlineGroup
        )
    }

    private func clearCleanRestartStateLater(for projectId: UUID) {
        let completed = cleanRestartStates[projectId]
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, self.cleanRestartStates[projectId] == completed else { return }
            self.cleanRestartStates.removeValue(forKey: projectId)
        }
    }

    private func scheduleCacheStateRefresh(force: Bool = false) {
        let cacheProjects = projects.filter { $0.kind.supportsCleanRestart }
        guard !cacheProjects.isEmpty else {
            cacheStates.removeAll()
            return
        }

        if !force, cacheSizeTask != nil {
            return
        }

        if force {
            cacheSizeTask?.cancel()
        }

        cacheSizeTask = Task { [weak self, cacheProjects] in
            await self?.refreshCacheStates(for: cacheProjects, force: force)
        }
    }

    private func refreshCacheStates(for cacheProjects: [LocalProject], force: Bool) async {
        defer { cacheSizeTask = nil }

        let validIDs = Set(projects.map(\.id))
        cacheStates = cacheStates.filter { validIDs.contains($0.key) }

        for project in cacheProjects {
            if Task.isCancelled { return }
            await refreshCacheState(for: project, force: force)
        }
    }

    private func refreshCacheState(for project: LocalProject, force: Bool) async {
        guard project.kind.supportsCleanRestart else { return }
        guard projects.contains(where: { $0.id == project.id }) else { return }

        if
            !force,
            let cacheState = cacheStates[project.id],
            Date().timeIntervalSince(cacheState.updatedAt) < cacheSizeRefreshInterval
        {
            return
        }

        let bytes = await cacheSize(for: project)
        guard projects.contains(where: { $0.id == project.id }) else { return }

        cacheStates[project.id] = ProjectCacheState(
            bytes: bytes,
            limitBytes: project.kind.cacheSizeLimitBytes,
            updatedAt: Date()
        )
    }

    private func cacheSize(for project: LocalProject) async -> Int64 {
        let rootPath = URL(fileURLWithPath: project.path, isDirectory: true)
            .standardizedFileURL
            .path
        let relativePaths = project.kind.cleanCacheRelativePaths

        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var total: Int64 = 0

            for relativePath in relativePaths {
                let cacheURL = URL(fileURLWithPath: rootPath, isDirectory: true)
                    .appendingPathComponent(relativePath)
                    .standardizedFileURL

                guard
                    ProjectCacheCleaner.contains(cacheURL, in: project.folderURL),
                    fileManager.fileExists(atPath: cacheURL.path)
                else {
                    continue
                }

                total += Self.itemSize(at: cacheURL, fileManager: fileManager)
            }

            return total
        }.value
    }

    private func removeCleanCaches(for project: LocalProject) async throws -> [String] {
        let folder = project.folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        cleaningFolders.insert(folder)
        defer { cleaningFolders.remove(folder) }
        return try await Task.detached(priority: .utility) {
            try ProjectCacheCleaner.remove(relativePaths: project.kind.cleanCacheRelativePaths, in: project.folderURL)
        }.value
    }

    nonisolated private static func itemSize(at url: URL, fileManager: FileManager) -> Int64 {
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]
        var total = fileSize(at: url)

        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [],
                errorHandler: { _, _ in true }
            )
        else {
            return total
        }

        for case let itemURL as URL in enumerator {
            total += fileSize(at: itemURL)
        }

        return total
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]

        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
            return 0
        }

        return Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.totalFileSize
                ?? values.fileSize
                ?? 0
        )
    }

    private func persist() {
        store.save(ProjectLibrary(projects: projects, groups: groups))
    }

    private func persistRuntimeSessions() {
        guard !projects.isEmpty || store.loadIssue == nil else { return }
        var snapshots = runtimeStates.reduce(into: [String: RuntimeSessionSnapshot]()) { result, item in
            guard let startedAt = item.value.startedAt else { return }
            result[item.key.uuidString] = RuntimeSessionSnapshot(
                startedAt: startedAt,
                processStartedAt: item.value.processStartedAt,
                lastSeenRunningAt: item.value.lastSeenRunningAt,
                pid: item.value.pid,
                observedPort: item.value.observedPort
            )
        }

        if store.loadIssue != nil {
            let knownIDs = Set(projects.map(\.id))
            for (id, snapshot) in Self.loadRuntimeSessions(from: defaults) where !knownIDs.contains(id) {
                snapshots[id.uuidString] = snapshot
            }
        }
        guard !snapshots.isEmpty else {
            defaults.removeObject(forKey: Self.runtimeSessionsKey)
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(snapshots) else { return }
        defaults.set(data, forKey: Self.runtimeSessionsKey)
    }

    private static func loadRuntimeSessions(from defaults: UserDefaults) -> [UUID: RuntimeSessionSnapshot] {
        guard let data = defaults.data(forKey: runtimeSessionsKey) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let snapshots = try? decoder.decode([String: RuntimeSessionSnapshot].self, from: data) else {
            return [:]
        }

        return snapshots.reduce(into: [UUID: RuntimeSessionSnapshot]()) { result, item in
            guard let id = UUID(uuidString: item.key) else { return }
            result[id] = item.value
        }
    }

    private static func runtimeState(from snapshot: RuntimeSessionSnapshot) -> ProjectRuntimeState {
        var state = ProjectRuntimeState.stopped
        state.pid = snapshot.pid
        state.startedAt = snapshot.startedAt
        state.processStartedAt = snapshot.processStartedAt
        state.lastSeenRunningAt = snapshot.lastSeenRunningAt
        state.observedPort = snapshot.observedPort
        return state
    }

    private static func migrateLegacyCommandTemplates(in library: ProjectLibrary) -> ProjectLibrary {
        var migrated = library

        for index in migrated.projects.indices {
            let project = migrated.projects[index]
            let commandTemplate = ProjectDetector.normalizeCommandTemplate(
                project.commandTemplate,
                packageManager: project.packageManager
            )

            var normalized = project
            if commandTemplate != project.commandTemplate {
                normalized.commandTemplate = commandTemplate
                normalized.updatedAt = Date()
            }
            migrated.projects[index] = ProjectLaunchMigration.migrate(ProjectDetector.repairDetectedDefaults(in: normalized))
        }

        return migrated
    }

    private func importPort(for folder: URL, preferredPort: Int, listeners: [DiscoveredPort]) -> Int? {
        let hasSavedOwner = projects.contains { $0.port == preferredPort }
        let expectedPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let atPreferredPort = listeners.filter { $0.port == preferredPort }
        let sameProject = !atPreferredPort.isEmpty && atPreferredPort.allSatisfy { owner in
            guard let path = owner.workingDirectory else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == expectedPath
        }
        return !hasSavedOwner && sameProject ? preferredPort : nextAvailablePort(
            startingAt: preferredPort, excluding: nil, occupiedPorts: Set(listeners.map(\.port))
        )
    }

    private func nextAvailablePort(startingAt preferredPort: Int, excluding projectId: UUID?, occupiedPorts: Set<Int>? = nil) -> Int? {
        let projectPorts = projects
            .filter { $0.id != projectId }
            .map(\.port)
        let usedPorts = (occupiedPorts ?? Set(discoveredPorts.map(\.port))).union(projectPorts)
        operationError = nil
        guard let port = Self.availablePort(startingAt: preferredPort, excluding: usedPorts) else {
            operationError = "All project ports are in use."
            return nil
        }
        return port
    }

    static func availablePort(startingAt preferredPort: Int, excluding usedPorts: Set<Int>) -> Int? {
        let first = (1_024...65_535).contains(preferredPort) ? preferredPort : 1_024
        return (first...65_535).first(where: { !usedPorts.contains($0) })
            ?? (1_024..<first).first(where: { !usedPorts.contains($0) })
    }

    private func defaultProjectDirectoryURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Documents/Projects", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home
        ]

        return candidates.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        } ?? home
    }

    private func annotate(_ ports: [DiscoveredPort], managedProjectIDsByPID: [Int32: UUID]) -> [DiscoveredPort] {
        let folders = projectsByFolder
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let unmanaged = ports.filter { managedProjectIDsByPID[$0.pid] == nil }
        let managedIDs = Set(managedProjectIDsByPID.values)
        let externalOwners = Dictionary(grouping: unmanaged, by: \.pid).compactMapValues {
            listeners -> LocalProject? in
            guard let owner = Self.externalOwner(of: listeners, byFolder: folders),
                  !managedIDs.contains(owner.id) else { return nil }
            return owner
        }
        return ports.map { port in
            let managedID = managedProjectIDsByPID[port.pid]
            let project = managedID.flatMap { projectsByID[$0] } ?? externalOwners[port.pid]
            var copy = port
            copy.isManaged = managedID != nil
            copy.projectId = project?.id
            copy.projectName = project?.name
            return copy
        }
    }

    private func applyPortPreferences(to ports: [DiscoveredPort]) -> [DiscoveredPort] {
        ports.map { port in
            var copy = port
            copy.pinnedName = pinnedPortNames[port.port]
            copy.isIgnored = ignoredPorts.contains(port.port) && copy.pinnedName == nil
            return copy
        }
    }

    func reconcileRunningStates(now: Date = Date()) {
        for project in projects {
            guard !processManager.isTerminating(project.id) else { continue }
            guard var state = runtimeStates[project.id] else {
                runtimeStates[project.id] = .stopped
                continue
            }

            if state.status != .crashed {
                if let owner = matchingProjectPortOwner(for: project) {
                    markRunning(project, owner: owner, persist: false)
                } else if let observed = matchingProjectProcessOwner(for: project) {
                    markPortMismatch(project, owner: observed, persist: false)
                } else if let pid = processManager.rootPID(for: project.id) {
                    state.ownership = .managed
                    let startedAt = state.startedAt ?? ProcessTree.startDate(of: pid) ?? now
                    state.startedAt = startedAt
                    state.observedPort = nil
                    // A launch command can run preparatory scripts before starting its server.
                    let waitInterval = state.lastSeenRunningAt == nil ? initialPortWaitInterval : 10
                    if now.timeIntervalSince(startedAt) >= waitInterval {
                        state.status = .noPort
                        state.lastMessage = "Process is alive, but no listening port opened for \(project.port)."
                    } else {
                        state.status = .starting
                        state.lastMessage = "Waiting for \(project.localAuthority) to open."
                    }
                    runtimeStates[project.id] = state
                } else if projectLaunchRequests[project.id] != nil || dependencyLaunchTasks[project.id] != nil {
                    state.status = .starting
                    runtimeStates[project.id] = state
                } else if state.isWithinSessionContinuityGrace(
                    now: now,
                    continuityGrace: sessionContinuityGraceInterval
                ) {
                    state.status = .noPort
                    state.pid = nil
                    state.observedPort = nil
                    state.lastMessage = "Waiting for \(project.localAuthority) to reopen."
                    runtimeStates[project.id] = state
                } else if state.status != .stopped || state.startedAt != nil || state.lastSeenRunningAt != nil {
                    state.status = .stopped
                    state.ownership = .none
                    state.pid = nil
                    state.observedPort = nil
                    state.clearSessionTiming()
                    state.lastMessage = "Stopped."
                    runtimeStates[project.id] = state
                    healthStates[project.id] = .unknown
                }
            }
        }
    }

    func markRunning(_ project: LocalProject, owner: DiscoveredPort, persist: Bool = true) {
        var state = runtimeStates[project.id] ?? .stopped
        let previousStatus = state.status
        let listenerChanged = state.pid != owner.pid || state.observedPort != owner.port
            || (state.processStartedAt != nil && owner.startedAt != nil && state.processStartedAt != owner.startedAt)
        if listenerChanged {
            invalidateReadinessCheck(for: project.id)
            state.readiness = ProjectReadinessState()
            healthStates[project.id] = .unknown
        }
        let beginsChecking = state.readiness.startedAt == nil
        syncStartedAt(&state, owner: owner)
        if healthChecksEnabled {
            state.readiness.begin(at: Date())
            if listenerChanged || beginsChecking {
                state.status = .warmingUp
                state.lastMessage = "Waiting for the first HTTP response."
            } else if previousStatus == .warmingUp || previousStatus == .responseDelayed || previousStatus == .noResponse {
                state.status = previousStatus
            } else {
                state.status = .running
            }
        } else {
            state.status = .running
        }
        state.ownership = owner.isManaged ? .managed : .external
        state.pid = owner.pid
        state.observedPort = owner.port
        if state.status == .running {
            state.lastMessage = "Listening on \(project.localAuthority)"
        }
        runtimeStates[project.id] = state
        openBrowserIfReady(for: project)
        if persist {
            persistRuntimeSessions()
            updateMenuBarTitle()
        }
    }

    private func markPortMismatch(_ project: LocalProject, owner: DiscoveredPort, persist: Bool = true) {
        var state = runtimeStates[project.id] ?? .stopped
        invalidateReadinessCheck(for: project.id)
        state.readiness = ProjectReadinessState()
        syncStartedAt(&state, owner: owner)
        state.status = .portMismatch
        state.ownership = owner.isManaged ? .managed : .external
        state.pid = owner.pid
        state.observedPort = owner.port
        state.lastMessage = "Expected \(project.port), running on \(owner.port)."
        runtimeStates[project.id] = state
        if persist {
            persistRuntimeSessions()
            updateMenuBarTitle()
        }
    }

    private func syncStartedAt(_ state: inout ProjectRuntimeState, owner: DiscoveredPort) {
        state.syncSession(
            with: owner,
            continuityGrace: sessionContinuityGraceInterval
        )
    }

    func setState(
        for projectId: UUID,
        status: ProjectRunStatus,
        ownership: ProjectProcessOwnership? = nil,
        pid: Int32? = nil,
        startedAt: Date? = nil,
        message: String? = nil
    ) {
        var state = runtimeStates[projectId] ?? .stopped
        state.status = status
        if status == .starting || status == .stopped || status == .crashed || status == .portBusy {
            invalidateReadinessCheck(for: projectId)
            state.readiness = ProjectReadinessState()
            healthStates[projectId] = .unknown
        }
        if let ownership {
            state.ownership = ownership
        }
        if let pid {
            state.pid = pid
        }
        if let startedAt {
            state.clearSessionTiming()
            state.startedAt = startedAt
        }
        if status == .stopped || status == .starting || status == .portBusy || status == .crashed {
            state.observedPort = nil
        }
        if status == .stopped || status == .portBusy || status == .crashed {
            state.ownership = .none
            state.clearSessionTiming()
        }
        state.lastMessage = message
        runtimeStates[projectId] = state
        persistRuntimeSessions()
        updateMenuBarTitle()
    }

    private func handle(processEvent event: ProjectProcessEvent) {
        switch event {
        case .started(let projectId, let pid):
            setState(
                for: projectId,
                status: .starting,
                ownership: .managed,
                pid: pid,
                startedAt: Date(),
                message: "Process started as PID \(pid)."
            )
        case .exited(let projectId, let code):
            pendingBrowserOpens.remove(projectId)
            invalidateReadinessCheck(for: projectId)
            var state = runtimeStates[projectId] ?? .stopped
            state.readiness = ProjectReadinessState()
            state.status = code == 0 ? .stopped : .crashed
            state.ownership = .none
            state.pid = nil
            state.observedPort = nil
            state.clearSessionTiming()
            let diagnosis = ProjectFailureDiagnosis.classify(logs: processManager.logLines(for: projectId), exitCode: code)
            state.lastMessage = code == 0 ? "Stopped." : "\(diagnosis.title). \(diagnosis.recovery)"
            runtimeStates[projectId] = state
            healthStates[projectId] = .unknown
            persistRuntimeSessions()
            updateMenuBarTitle()

            guard code != 0, let project = projects.first(where: { $0.id == projectId }) else { return }
            recordFailure(for: project, code: code, diagnosis: diagnosis)
            notificationService.notify(title: "\(project.displayName) crashed", body: diagnosis.title)

            if project.autoRestart {
                scheduleAutomaticRestart(for: project)
            }
        }
    }

    func appendLog(projectId: UUID, text: String) {
        if selectedLogProjectID == projectId { logRevision &+= 1 }
        processManager.appendLog(projectId: projectId, text: text)
        var state = runtimeStates[projectId] ?? .stopped
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        state.logs.append(contentsOf: lines)
        if state.logs.count > 200 {
            state.logs = Array(state.logs.suffix(200))
        }
        state.lastMessage = lines.last ?? state.lastMessage
        runtimeStates[projectId] = state
    }

    private func refreshSelectedLog() async {
        guard let id = selectedLogProjectID else { return }
        let revision = logRevision
        let url = processManager.logLocation(for: id)
        guard let lines = await logReader.lines(at: url), !Task.isCancelled, revision == logRevision,
              selectedLogProjectID == id, runtimeStates[id]?.logs != lines else { return }
        runtimeStates[id]?.logs = lines
    }

    private func refreshProjectIdentities(force: Bool = false) async {
        let now = Date()
        let hasMissingIdentity = projects.contains { projectIdentities[$0.id] == nil }

        if
            !force,
            !hasMissingIdentity,
            let lastProjectIdentityRefresh,
            now.timeIntervalSince(lastProjectIdentityRefresh) < projectIdentityRefreshInterval
        {
            return
        }

        for project in projects {
            let identity = await projectInspector.inspect(project)
            guard !Task.isCancelled else { return }
            if projects.contains(where: { $0.id == project.id && $0.path == project.path && $0.kind == project.kind }) {
                projectIdentities[project.id] = identity
            }
        }

        lastProjectIdentityRefresh = now
    }

    private func refreshReadinessStates(force: Bool = false) async {
        guard healthChecksEnabled else { return }
        let candidates = projects.filter { shouldCheckReadiness(for: $0) }
        await withTaskGroup(of: Void.self) { group in
            for (index, project) in candidates.enumerated() {
                if index >= 6 { await group.next() }
                guard !Task.isCancelled else { break }
                group.addTask { await self.checkReadiness(for: project, force: force) }
            }
        }
    }

    private func shouldCheckReadiness(for project: LocalProject) -> Bool {
        switch runtimeState(for: project).status {
        case .running, .warmingUp, .responseDelayed, .noResponse:
            return true
        case .stopped, .starting, .portBusy, .portMismatch, .noPort, .crashed:
            return false
        }
    }

    private func invalidateReadinessCheck(for projectID: UUID) {
        readinessCheckIDs.removeValue(forKey: projectID)
        lastReadinessCheckDates.removeValue(forKey: projectID)
        lastHealthStates.removeValue(forKey: projectID)
    }

    private func resetHealthStates() {
        readinessCheckIDs.removeAll()
        lastReadinessCheckDates.removeAll()
        lastHealthStates.removeAll()
        for project in projects {
            healthStates[project.id] = .unknown
            guard var state = runtimeStates[project.id] else { continue }
            state.readiness = ProjectReadinessState()
            if state.status == .warmingUp || state.status == .responseDelayed || state.status == .noResponse {
                state.status = .running
                state.lastMessage = "Listening on \(project.hostname):\(state.observedPort ?? project.port)"
            }
            runtimeStates[project.id] = state
            openBrowserIfReady(for: project)
        }
        updateMenuBarTitle()
    }

    func checkReadiness(for project: LocalProject, force: Bool = false) async {
        guard !Task.isCancelled, healthChecksEnabled,
              projects.contains(where: { $0.id == project.id && $0.healthURL == project.healthURL }),
              shouldCheckReadiness(for: project),
              readinessCheckIDs[project.id] == nil else { return }
        if !force, let lastCheck = lastReadinessCheckDates[project.id],
           Date().timeIntervalSince(lastCheck) < readinessCheckRefreshInterval {
            return
        }

        let checkID = UUID()
        readinessCheckIDs[project.id] = checkID
        lastReadinessCheckDates[project.id] = Date()
        runtimeStates[project.id]?.readiness.begin(at: Date())
        healthStates[project.id] = .checking
        defer {
            if readinessCheckIDs[project.id] == checkID {
                readinessCheckIDs.removeValue(forKey: project.id)
            }
        }
        let next = await healthChecker.check(project)
        // Settings, a restart, or an endpoint edit can invalidate an in-flight result.
        guard !Task.isCancelled, healthChecksEnabled,
              readinessCheckIDs[project.id] == checkID,
              shouldCheckReadiness(for: project) else { return }
        applyReadinessState(next, for: project)

        let status = runtimeState(for: project).status
        if status == .warmingUp || status == .responseDelayed {
            healthStates[project.id] = .checking
            return
        }
        let previous = lastHealthStates[project.id]
        healthStates[project.id] = next
        lastHealthStates[project.id] = next
        notifyHealthChange(project: project, previous: previous, next: next)
    }

    private func applyReadinessState(_ health: HealthState, for project: LocalProject) {
        var state = runtimeStates[project.id] ?? .stopped
        guard let status = state.readiness.record(health, at: Date()) else { return }
        state.status = status
        switch status {
        case .running:
            state.lastMessage = "Listening on \(project.hostname):\(state.observedPort ?? project.port)"
        case .warmingUp:
            state.lastMessage = "Waiting for the first HTTP response."
        case .responseDelayed:
            state.lastMessage = "Response delayed. Checking again."
        case .noResponse:
            if case .unreachable(let message) = health {
                state.lastMessage = message
            }
        default:
            break
        }
        runtimeStates[project.id] = state
        openBrowserIfReady(for: project)
        updateMenuBarTitle()
    }

    private func notifyHealthChange(
        project: LocalProject,
        previous: HealthState?,
        next: HealthState
    ) {
        switch next {
        case .healthy:
            if previous == nil || previous == .checking || previous == .unknown {
                notificationService.notify(title: "\(project.displayName) is ready", body: "Listening on \(project.localAuthority)")
            }
        case .warning(let code, _):
            if case .warning(let oldCode, _) = previous, oldCode == code { return }
            notificationService.notify(title: "\(project.displayName) health warning", body: "Health check returned \(code).")
        case .unreachable(let message):
            if case .healthy = previous {
                notificationService.notify(title: "\(project.displayName) stopped responding", body: message)
            }
        case .unknown, .checking:
            break
        }
    }

    private func primaryProfileName(for kind: ProjectKind) -> String {
        switch kind {
        case .storybook:
            return "storybook"
        case .prisma:
            return "studio"
        case .supabase:
            return "supabase"
        default:
            return "dev"
        }
    }

    private func nextProfileName(for project: LocalProject) -> String {
        let siblings = projects.filter { $0.path == project.path && $0.name == project.name }
        return "profile \(siblings.count + 1)"
    }

    private func persistPortPreferences() {
        let pins = pinnedPortNames.reduce(into: [String: String]()) { result, item in
            result[String(item.key)] = item.value
        }
        defaults.set(pins, forKey: Self.pinnedPortsKey)
        defaults.set(Array(ignoredPorts).sorted(), forKey: Self.ignoredPortsKey)
    }

    private static func loadPinnedPorts(from defaults: UserDefaults) -> [Int: String] {
        guard let raw = defaults.dictionary(forKey: pinnedPortsKey) as? [String: String] else {
            return [:]
        }

        return raw.reduce(into: [Int: String]()) { result, item in
            if let port = Int(item.key) {
                result[port] = item.value
            }
        }
    }

    private static func loadIgnoredPorts(from defaults: UserDefaults) -> Set<Int> {
        let raw = defaults.array(forKey: ignoredPortsKey) as? [Int] ?? []
        return Set(raw)
    }

    private var orderedPinnedProjectIDs: [UUID] {
        projects
            .enumerated()
            .filter { $0.element.isQuickLaunchPinned }
            .sorted { lhs, rhs in
                let lhsOrder = lhs.element.quickLaunchOrder ?? .max
                let rhsOrder = rhs.element.quickLaunchOrder ?? .max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element.id)
    }

    private func applyQuickLaunchPinOrder(_ pinnedIDs: [UUID]) {
        let orderByID = Dictionary(uniqueKeysWithValues: pinnedIDs.enumerated().map { ($0.element, $0.offset) })

        for index in projects.indices {
            if let order = orderByID[projects[index].id] {
                projects[index].isQuickLaunchPinned = true
                projects[index].quickLaunchOrder = order
            } else {
                projects[index].isQuickLaunchPinned = false
                projects[index].quickLaunchOrder = nil
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func localNetworkAddress() -> String {
        let addresses = Host.current().addresses
        return addresses.first { address in
            address.contains(".") && !address.hasPrefix("127.") && address != "0.0.0.0"
        } ?? "localhost"
    }

    private static let pinnedPortsKey = "pinnedPortNames"
    private static let ignoredPortsKey = "ignoredPorts"
    private static let runtimeSessionsKey = "runtimeSessionsV1"
}

private extension LocalMonitorModel {
    static func groupKey(for port: DiscoveredPort) -> String {
        if let projectId = port.projectId {
            return "project-\(projectId.uuidString)"
        }

        if let pinnedName = port.pinnedName?.normalizedPortGroupToken {
            return "pin-\(pinnedName)"
        }

        if let inferredProjectName = port.inferredProjectName?.normalizedPortGroupToken {
            return "name-\(inferredProjectName)"
        }

        if let workingDirectory = port.workingDirectory?.normalizedPortGroupToken {
            return "cwd-\(workingDirectory)"
        }

        return "pid-\(port.pid)-\(port.command.normalizedPortGroupToken ?? port.command)"
    }

    static func primaryPort(in ports: [DiscoveredPort]) -> DiscoveredPort? {
        ports.min { lhs, rhs in
            let lhsScore = primaryScore(for: lhs)
            let rhsScore = primaryScore(for: rhs)

            if lhsScore == rhsScore {
                if lhs.port == rhs.port {
                    return lhs.pid < rhs.pid
                }
                return lhs.port < rhs.port
            }

            return lhsScore < rhsScore
        }
    }

    static func primaryScore(for port: DiscoveredPort) -> Int {
        var score = port.port

        if port.pinnedName != nil { score -= 10_000 }
        if port.isManaged { score -= 8_000 }
        if port.port == 3000 { score -= 5_000 }
        if (3000...3999).contains(port.port) { score -= 3_000 }
        if (5000...5999).contains(port.port) { score -= 2_000 }
        if port.safety == .normal { score -= 500 }
        if port.command.localizedCaseInsensitiveContains("node") { score -= 200 }
        if (port.commandLine ?? "").localizedCaseInsensitiveContains("next") { score -= 200 }

        return score
    }
}

private extension String {
    var normalizedPortGroupToken: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .replacingOccurrences(of: #"[^a-z0-9/_-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
