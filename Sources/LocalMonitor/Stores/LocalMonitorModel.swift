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

@MainActor
final class LocalMonitorModel: ObservableObject {
    @Published private(set) var projects: [LocalProject]
    @Published private(set) var groups: [WorkspaceGroup]
    @Published private(set) var runtimeStates: [UUID: ProjectRuntimeState] = [:]
    @Published private(set) var projectIdentities: [UUID: ProjectIdentity] = [:]
    @Published private(set) var healthStates: [UUID: HealthState] = [:]
    @Published private(set) var preflightResults: [UUID: PreflightResult] = [:]
    @Published private(set) var discoveredPorts: [DiscoveredPort] = []
    @Published private(set) var pinnedPortNames: [Int: String] = [:]
    @Published private(set) var ignoredPorts: Set<Int> = []
    @Published private(set) var pendingKillPortID: String?
    @Published private(set) var cleanRestartStates: [UUID: CleanRestartState] = [:]
    @Published private(set) var cacheStates: [UUID: ProjectCacheState] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var menuBarTitle = MenuBarTitle(
        runningCount: 0,
        totalCount: 0,
        externalCount: 0,
        displayMode: .count
    )
    @Published var selectedLogProjectID: UUID?

    private let store: ProjectStore
    private let portScanner: PortScanner
    private let portKiller: PortKiller
    private let projectInspector: ProjectInspector
    private let preflightChecker: PreflightChecker
    private let healthChecker: HealthChecker
    private let notificationService: NotificationService
    private let processManager: ProjectProcessManager
    private var refreshTask: Task<Void, Never>?
    private var cacheSizeTask: Task<Void, Never>?
    private var projectPanel: NSOpenPanel?
    private var lastHealthStates: [UUID: HealthState] = [:]
    private var lastReadinessCheckDates: [UUID: Date] = [:]
    private var lastProjectIdentityRefresh: Date?
    private let cacheSizeRefreshInterval: TimeInterval = 600
    private let readinessCheckRefreshInterval: TimeInterval = 12
    private let projectIdentityRefreshInterval: TimeInterval = 60

    init(
        store: ProjectStore = ProjectStore(),
        portScanner: PortScanner = PortScanner(),
        portKiller: PortKiller = PortKiller(),
        projectInspector: ProjectInspector = ProjectInspector(),
        preflightChecker: PreflightChecker = PreflightChecker(),
        healthChecker: HealthChecker = HealthChecker(),
        notificationService: NotificationService? = nil,
        processManager: ProjectProcessManager? = nil
    ) {
        self.store = store
        self.portScanner = portScanner
        self.portKiller = portKiller
        self.projectInspector = projectInspector
        self.preflightChecker = preflightChecker
        self.healthChecker = healthChecker
        self.notificationService = notificationService ?? .shared
        self.processManager = processManager ?? ProjectProcessManager()
        let loadedLibrary = store.load()
        let library = Self.migrateLegacyCommandTemplates(in: loadedLibrary)
        self.projects = library.projects
        self.groups = library.groups
        self.pinnedPortNames = Self.loadPinnedPorts()
        self.ignoredPorts = Self.loadIgnoredPorts()

        if library != loadedLibrary {
            store.save(library)
        }

        for project in projects {
            runtimeStates[project.id] = .stopped
            healthStates[project.id] = .unknown
        }

        self.processManager.onEvent = { [weak self] event in
            self?.handle(processEvent: event)
        }

        updateMenuBarTitle()
    }

    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()

            while !Task.isCancelled {
                let interval = UInt64(AppPreference.refreshInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
                await self.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func shutdown() {
        if AppPreference.stopProjectsOnQuit {
            stopAllProjects()
        }
        stop()
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let scanned = AppPreference.scanExternalPorts ? try await portScanner.scan() : []
            discoveredPorts = applyPortPreferences(to: annotate(scanned))
            reconcileRunningStates()
            await refreshProjectIdentities()
            await refreshReadinessStates(updateHealthState: AppPreference.healthChecks)
            if !AppPreference.healthChecks {
                resetHealthStates()
            }
            scheduleCacheStateRefresh()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        lastUpdated = Date()
        updateMenuBarTitle()
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
                await self.addProject(folderURL: selectedURL)
            }
        }
    }

    func addProject(folderURL: URL) async {
        let detection = ProjectDetector.detect(folderURL: folderURL, preferredPort: AppPreference.defaultPort)
        let port = nextAvailablePort(startingAt: detection.defaultPort)
        let project = LocalProject(
            name: detection.name,
            profileName: primaryProfileName(for: detection.kind),
            path: folderURL.path,
            kind: detection.kind,
            packageManager: detection.packageManager,
            port: port,
            commandTemplate: detection.commandTemplate,
            healthPath: detection.suggestedPresets.first?.healthPath ?? "/",
            openAfterStart: AppPreference.openBrowserAfterStart
        )

        projects.append(project)
        runtimeStates[project.id] = .stopped
        healthStates[project.id] = .unknown
        persist()
        updateMenuBarTitle()
        await refresh()
    }

    func removeProject(_ project: LocalProject) {
        stopProject(project)
        projects.removeAll { $0.id == project.id }
        for index in groups.indices {
            groups[index].projectIDs.removeAll { $0 == project.id }
        }
        runtimeStates.removeValue(forKey: project.id)
        projectIdentities.removeValue(forKey: project.id)
        healthStates.removeValue(forKey: project.id)
        lastHealthStates.removeValue(forKey: project.id)
        lastReadinessCheckDates.removeValue(forKey: project.id)
        preflightResults.removeValue(forKey: project.id)
        cleanRestartStates.removeValue(forKey: project.id)
        cacheStates.removeValue(forKey: project.id)
        if selectedLogProjectID == project.id {
            selectedLogProjectID = nil
        }
        persist()
        updateMenuBarTitle()
    }

    func startProject(_ project: LocalProject) async {
        let state = runtimeState(for: project)
        if state.status == .running || state.status == .starting || state.status == .portMismatch || state.status == .noPort || state.status == .noResponse {
            return
        }

        if let owner = matchingProjectPortOwner(for: project) {
            markRunning(project, owner: owner)
            await checkReadiness(for: project, updateHealthState: AppPreference.healthChecks, force: true)
            if runtimeState(for: project).status == .running, project.openAfterStart {
                openInBrowser(project)
            }
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

        let preflight = await preflightChecker.check(project)
        preflightResults[project.id] = preflight
        if !preflight.isClear {
            setState(for: project.id, status: .crashed, message: preflight.summary)
            notificationService.notify(title: "\(project.displayName) blocked", body: preflight.summary)
            return
        }

        setState(for: project.id, status: .starting, message: project.resolvedCommand)

        do {
            try processManager.start(project: project)
        } catch {
            setState(for: project.id, status: .crashed, message: error.localizedDescription)
            return
        }

        try? await Task.sleep(nanoseconds: 900_000_000)
        await refresh()
        let refreshedState = runtimeState(for: project)

        if refreshedState.status == .running, project.openAfterStart {
            openInBrowser(project)
        }
    }

    func stopProject(_ project: LocalProject) {
        if processManager.isRunning(projectId: project.id) {
            processManager.stop(projectId: project.id)
        } else if let owner = matchingProjectProcessOwner(for: project) {
            ProcessTree.terminate(pid: owner.pid)
        }

        runtimeStates[project.id] = .stopped
        healthStates[project.id] = .unknown
        lastReadinessCheckDates.removeValue(forKey: project.id)
        updateMenuBarTitle()
        Task { await verifyStopped(project) }
    }

    private func verifyStopped(_ project: LocalProject) async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await refresh()

        guard let owner = matchingProjectProcessOwner(for: project) else {
            runtimeStates[project.id] = .stopped
            healthStates[project.id] = .unknown
            lastReadinessCheckDates.removeValue(forKey: project.id)
            updateMenuBarTitle()
            return
        }

        ProcessTree.terminate(pid: owner.pid)
        try? await Task.sleep(nanoseconds: 700_000_000)
        await refresh()

        if let remainingOwner = matchingProjectProcessOwner(for: project) {
            markPortMismatch(project, owner: remainingOwner)
            appendLog(projectId: project.id, text: "Stop requested, but process is still running on \(remainingOwner.port).")
        } else {
            runtimeStates[project.id] = .stopped
            healthStates[project.id] = .unknown
            lastReadinessCheckDates.removeValue(forKey: project.id)
        }

        updateMenuBarTitle()
    }

    func restartProject(_ project: LocalProject) async {
        guard cleanRestartStates[project.id]?.isActive != true else { return }

        let keepOnlineGroup = isProjectOnlineForGrouping(project)
        setCleanRestartState(
            for: project,
            phase: .stopping,
            message: "Restarting project",
            progress: 0.16,
            keepsOnlineGroup: keepOnlineGroup,
            operation: .restart
        )
        stopProject(project)
        try? await Task.sleep(nanoseconds: 450_000_000)
        setCleanRestartState(
            for: project,
            phase: .starting,
            message: "Starting project",
            progress: 0.68,
            keepsOnlineGroup: keepOnlineGroup,
            operation: .restart
        )
        await startProject(project)

        let state = runtimeState(for: project)
        guard state.status == .running || state.status == .portMismatch || state.status == .noPort else {
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

    func cleanRestartProject(_ project: LocalProject) async {
        guard project.kind.supportsCleanRestart else { return }
        guard cleanRestartStates[project.id]?.isActive != true else { return }

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
            stopProject(project)
            try? await Task.sleep(nanoseconds: 850_000_000)
            await refresh()
        }

        setCleanRestartState(
            for: project,
            phase: .cleaning,
            message: "Cleaning \(project.kind.displayName) cache",
            progress: shouldRestartAfterClean ? 0.42 : 0.68,
            keepsOnlineGroup: keepOnlineGroup
        )

        do {
            let removedPaths = try await removeCleanCaches(for: project)
            if removedPaths.isEmpty {
                appendLog(projectId: project.id, text: "Cache clean: no cache folders found.")
            } else {
                appendLog(projectId: project.id, text: "Cache clean: removed \(removedPaths.joined(separator: ", ")).")
            }
            await refreshCacheState(for: project, force: true)
        } catch {
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
        await startProject(project)

        if AppPreference.healthChecks {
            setCleanRestartState(
                for: project,
                phase: .checking,
                message: "Waiting for response",
                progress: 0.9,
                keepsOnlineGroup: keepOnlineGroup
            )
            await checkReadiness(for: project, updateHealthState: true, force: true)
        }

        let state = runtimeState(for: project)
        guard state.status == .running || state.status == .portMismatch || state.status == .noPort else {
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
        for project in projects {
            await startProject(project)
        }
    }

    func startAutoStartProjects() async {
        for project in projects where project.autoStart {
            await startProject(project)
        }
    }

    func startAutoStartGroups() async {
        for group in groups where group.autoStart {
            await startGroup(group)
        }
    }

    func stopAllProjects() {
        processManager.stopAll()
        stopObservedProjectProcesses()
        for project in projects {
            runtimeStates[project.id] = .stopped
            lastReadinessCheckDates.removeValue(forKey: project.id)
        }
        updateMenuBarTitle()
    }

    func requestKillPort(_ port: DiscoveredPort) async {
        if AppPreference.safeKill, port.safety != .normal, pendingKillPortID != port.id {
            pendingKillPortID = port.id
            return
        }

        await killPort(port)
    }

    func killPort(_ port: DiscoveredPort) async {
        pendingKillPortID = nil

        if let projectId = port.projectId, let project = projects.first(where: { $0.id == projectId }) {
            stopProject(project)
            return
        }

        do {
            try await portKiller.stop(pid: port.pid)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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

    func openInBrowser(_ project: LocalProject) {
        guard let url = project.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openPortInBrowser(_ port: DiscoveredPort) {
        guard let url = URL(string: "http://localhost:\(port.port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openLoopback(_ project: LocalProject) {
        guard let url = URL(string: "http://127.0.0.1:\(project.port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openObservedPort(_ project: LocalProject) {
        guard
            let observedPort = runtimeState(for: project).observedPort,
            let url = URL(string: "http://localhost:\(observedPort)")
        else {
            openInBrowser(project)
            return
        }

        NSWorkspace.shared.open(url)
    }

    func copyURL(_ project: LocalProject, network: Bool = false) {
        let host = network ? localNetworkAddress() : "localhost"
        copyToPasteboard("http://\(host):\(project.port)")
    }

    func copyObservedURL(_ project: LocalProject) {
        let port = runtimeState(for: project).observedPort ?? project.port
        copyToPasteboard("http://localhost:\(port)")
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
        let port = nextAvailablePort(startingAt: project.port + 1, excluding: project.id)
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
        updateProject(project) { mutable in
            mutable.openAfterStart = enabled
        }
    }

    func updatePackageManager(for project: LocalProject, packageManager: PackageManager) {
        updateProject(project) { mutable in
            mutable.packageManager = packageManager
        }
    }

    func updateHealthPath(for project: LocalProject, healthPath: String) {
        updateProject(project) { mutable in
            mutable.healthPath = healthPath.isEmpty ? "/" : healthPath
        }
    }

    func updateAutoRestart(for project: LocalProject, enabled: Bool) {
        updateProject(project) { mutable in
            mutable.autoRestart = enabled
        }
    }

    func updateHealthChecks(enabled: Bool) async {
        if enabled {
            await refreshReadinessStates(updateHealthState: true, force: true)
        } else {
            resetHealthStates()
        }
    }

    func applyPreset(_ preset: CommandPreset, to project: LocalProject) {
        updateProject(project) { mutable in
            mutable.kind = preset.kind
            mutable.commandTemplate = preset.commandTemplate
            mutable.healthPath = preset.healthPath
            if let port = preset.port {
                mutable.port = nextAvailablePort(startingAt: port, excluding: project.id)
            }
            mutable.profileName = preset.title
        }
    }

    func duplicateProfile(from project: LocalProject, preset: CommandPreset? = nil) {
        let presetPort = preset?.port ?? project.port + 1
        let nextPort = nextAvailablePort(startingAt: presetPort)
        var clone = project
        clone.id = UUID()
        clone.profileName = preset?.title ?? nextProfileName(for: project)
        clone.kind = preset?.kind ?? project.kind
        clone.port = nextPort
        clone.commandTemplate = preset?.commandTemplate ?? project.commandTemplate
        clone.healthPath = preset?.healthPath ?? project.healthPath
        clone.autoStart = false
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
        for project in projects where group.projectIDs.contains(project.id) {
            await startProject(project)
        }
    }

    func stopGroup(_ group: WorkspaceGroup) {
        for project in projects where group.projectIDs.contains(project.id) {
            stopProject(project)
        }
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
        var state = runtimeStates[project.id] ?? .stopped
        state.logs.removeAll()
        runtimeStates[project.id] = state
    }

    func copyLogs(for project: LocalProject) {
        copyToPasteboard(logs(for: project).joined(separator: "\n"))
    }

    func updateMenuBarTitle() {
        let displayModeRaw = UserDefaults.standard.string(forKey: MenuBarDisplayMode.storageKey)
        let displayMode = displayModeRaw.flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .count
        let running = projects.filter { runtimeState(for: $0).status == .running }.count
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
            port.port == project.port && port.projectId != project.id && !sameProjectPortOwner(port, for: project)
        }
    }

    private func matchingProjectPortOwner(for project: LocalProject) -> DiscoveredPort? {
        discoveredPorts.first { port in
            sameProjectPortOwner(port, for: project)
        }
    }

    private func sameProjectPortOwner(_ port: DiscoveredPort, for project: LocalProject) -> Bool {
        port.port == project.port && sameProjectProcessOwner(port, for: project)
    }

    private func matchingProjectProcessOwner(for project: LocalProject) -> DiscoveredPort? {
        discoveredPorts
            .filter { sameProjectProcessOwner($0, for: project) }
            .sorted { lhs, rhs in
                if lhs.port == project.port { return true }
                if rhs.port == project.port { return false }
                return lhs.port < rhs.port
            }
            .first
    }

    private func projectIsRunningOrStarting(_ project: LocalProject) -> Bool {
        let state = runtimeState(for: project)
        switch state.status {
        case .running, .starting, .portMismatch, .noPort, .noResponse:
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
        case .running, .portMismatch:
            return true
        case .starting, .noPort, .noResponse, .stopped, .portBusy, .crashed:
            return false
        }
    }

    private func sameProjectProcessOwner(_ port: DiscoveredPort, for project: LocalProject) -> Bool {
        if port.projectId == project.id {
            return true
        }

        guard let workingDirectory = port.workingDirectory else {
            return false
        }

        let projectPath = URL(fileURLWithPath: project.path, isDirectory: true)
            .standardizedFileURL
            .path
        let processPath = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .standardizedFileURL
            .path

        return processPath == projectPath || processPath.hasPrefix("\(projectPath)/")
    }

    private func stopObservedProjectProcesses() {
        var stoppedPIDs = Set<Int32>()

        for project in projects {
            guard let owner = matchingProjectProcessOwner(for: project) else { continue }
            guard stoppedPIDs.insert(owner.pid).inserted else { continue }
            ProcessTree.terminate(pid: owner.pid)
        }
    }

    private func updateProject(_ project: LocalProject, mutate: (inout LocalProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        mutate(&projects[index])
        projects[index].updatedAt = Date()
        persist()
        updateMenuBarTitle()
        Task { await refresh() }
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
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            _ = await MainActor.run {
                self?.cleanRestartStates.removeValue(forKey: projectId)
            }
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
                    Self.isSafeCachePath(cacheURL.path, rootPath: rootPath),
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
        let rootPath = URL(fileURLWithPath: project.path, isDirectory: true)
            .standardizedFileURL
            .path
        let relativePaths = project.kind.cleanCacheRelativePaths

        return try await Task.detached(priority: .utility) {
            var removedPaths: [String] = []
            let fileManager = FileManager.default

            for relativePath in relativePaths {
                let cacheURL = URL(fileURLWithPath: rootPath, isDirectory: true)
                    .appendingPathComponent(relativePath)
                    .standardizedFileURL

                guard Self.isSafeCachePath(cacheURL.path, rootPath: rootPath) else {
                    throw CleanRestartError.unsafePath(relativePath)
                }

                guard fileManager.fileExists(atPath: cacheURL.path) else {
                    continue
                }

                do {
                    try fileManager.removeItem(at: cacheURL)
                    removedPaths.append(relativePath)
                } catch {
                    throw CleanRestartError.removeFailed(relativePath, error.localizedDescription)
                }
            }

            return removedPaths
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

    nonisolated private static func isSafeCachePath(_ path: String, rootPath: String) -> Bool {
        path != rootPath && path.hasPrefix("\(rootPath)/")
    }

    private func persist() {
        store.save(ProjectLibrary(projects: projects, groups: groups))
    }

    private static func migrateLegacyCommandTemplates(in library: ProjectLibrary) -> ProjectLibrary {
        var migrated = library

        for index in migrated.projects.indices {
            let project = migrated.projects[index]
            let commandTemplate = ProjectDetector.normalizeCommandTemplate(
                project.commandTemplate,
                packageManager: project.packageManager
            )

            guard commandTemplate != project.commandTemplate else { continue }
            migrated.projects[index].commandTemplate = commandTemplate
            migrated.projects[index].updatedAt = Date()
        }

        return migrated
    }

    private func nextAvailablePort(startingAt preferredPort: Int) -> Int {
        nextAvailablePort(startingAt: preferredPort, excluding: nil)
    }

    private func nextAvailablePort(startingAt preferredPort: Int, excluding projectId: UUID?) -> Int {
        let projectPorts = projects
            .filter { $0.id != projectId }
            .map(\.port)
        let usedPorts = Set(discoveredPorts.map(\.port)).union(projectPorts)
        var candidate = min(65_535, max(1_024, preferredPort))
        while usedPorts.contains(candidate), candidate < 65_535 {
            candidate += 1
        }
        return candidate
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

    private func annotate(_ ports: [DiscoveredPort]) -> [DiscoveredPort] {
        let managedProjectIDsByPID = processManager.managedProjectIDsByPID()

        return ports.map { port in
            var copy = port
            if
                let projectId = managedProjectIDsByPID[port.pid],
                let project = projects.first(where: { $0.id == projectId })
            {
                copy.isManaged = true
                copy.projectId = project.id
                copy.projectName = project.name
            } else if let project = projects.first(where: { sameProjectProcessOwner(port, for: $0) }) {
                copy.isManaged = true
                copy.projectId = project.id
                copy.projectName = project.name
            }
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

    private func reconcileRunningStates() {
        for project in projects {
            guard var state = runtimeStates[project.id] else {
                runtimeStates[project.id] = .stopped
                continue
            }

            if state.status == .stopped || state.status == .starting || state.status == .running || state.status == .portMismatch || state.status == .noPort || state.status == .noResponse {
                if let owner = matchingProjectPortOwner(for: project) {
                    markRunning(project, owner: owner)
                } else if let observed = matchingProjectProcessOwner(for: project) {
                    markPortMismatch(project, owner: observed)
                } else if processManager.isRunning(projectId: project.id) {
                    let elapsed = state.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if elapsed > 10 {
                        state.status = .noPort
                        state.observedPort = nil
                        state.lastMessage = "Process is alive, but no listening port opened for \(project.port)."
                    } else {
                        state.status = .starting
                    }
                    runtimeStates[project.id] = state
                } else if state.status != .stopped {
                    state.status = .stopped
                    state.pid = nil
                    state.observedPort = nil
                    state.startedAt = nil
                    state.lastMessage = "Stopped."
                    runtimeStates[project.id] = state
                    healthStates[project.id] = .unknown
                }
            }
        }
    }

    private func markRunning(_ project: LocalProject, owner: DiscoveredPort) {
        var state = runtimeStates[project.id] ?? .stopped
        let previousStatus = state.status
        syncStartedAt(&state, owner: owner)
        state.status = previousStatus == .noResponse ? .noResponse : .running
        state.pid = owner.pid
        state.observedPort = owner.port
        if previousStatus != .noResponse {
            state.lastMessage = "Listening on localhost:\(project.port)"
        }
        runtimeStates[project.id] = state
        updateMenuBarTitle()
    }

    private func markPortMismatch(_ project: LocalProject, owner: DiscoveredPort) {
        var state = runtimeStates[project.id] ?? .stopped
        syncStartedAt(&state, owner: owner)
        state.status = .portMismatch
        state.pid = owner.pid
        state.observedPort = owner.port
        state.lastMessage = "Expected \(project.port), running on \(owner.port)."
        runtimeStates[project.id] = state
        updateMenuBarTitle()
    }

    private func syncStartedAt(_ state: inout ProjectRuntimeState, owner: DiscoveredPort) {
        if let ownerStartedAt = owner.startedAt {
            if state.pid != owner.pid
                || state.startedAt == nil
                || abs(ownerStartedAt.timeIntervalSince(state.startedAt ?? ownerStartedAt)) > 5
            {
                state.startedAt = ownerStartedAt
            }
            return
        }

        if state.pid != owner.pid || state.startedAt == nil {
            state.startedAt = Date()
        }
    }

    private func setState(
        for projectId: UUID,
        status: ProjectRunStatus,
        pid: Int32? = nil,
        startedAt: Date? = nil,
        message: String? = nil
    ) {
        var state = runtimeStates[projectId] ?? .stopped
        state.status = status
        if let pid {
            state.pid = pid
        }
        if let startedAt {
            state.startedAt = startedAt
        }
        if status == .stopped || status == .starting || status == .portBusy || status == .crashed {
            state.observedPort = nil
        }
        if status == .stopped || status == .portBusy || status == .crashed {
            state.startedAt = nil
        }
        state.lastMessage = message
        runtimeStates[projectId] = state
        updateMenuBarTitle()
    }

    private func handle(processEvent event: ProjectProcessEvent) {
        switch event {
        case .started(let projectId, let pid):
            setState(
                for: projectId,
                status: .starting,
                pid: pid,
                startedAt: Date(),
                message: "Process started as PID \(pid)."
            )
        case .output(let projectId, let text):
            appendLog(projectId: projectId, text: text)
        case .exited(let projectId, let code):
            var state = runtimeStates[projectId] ?? .stopped
            state.status = code == 0 ? .stopped : .crashed
            state.pid = nil
            state.observedPort = nil
            state.startedAt = nil
            state.lastMessage = code == 0 ? "Stopped." : "Exited with code \(code)."
            runtimeStates[projectId] = state
            healthStates[projectId] = .unknown
            updateMenuBarTitle()

            guard code != 0, let project = projects.first(where: { $0.id == projectId }) else { return }
            notificationService.notify(title: "\(project.displayName) crashed", body: "Exited with code \(code).")

            if project.autoRestart {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await self?.startProject(project)
                }
            }
        }
    }

    private func appendLog(projectId: UUID, text: String) {
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
            projectIdentities[project.id] = await projectInspector.inspect(project)
        }

        lastProjectIdentityRefresh = now
    }

    private func refreshReadinessStates(updateHealthState: Bool, force: Bool = false) async {
        for project in projects where shouldCheckReadiness(for: project) {
            await checkReadiness(for: project, updateHealthState: updateHealthState, force: force)
        }
    }

    private func shouldCheckReadiness(for project: LocalProject) -> Bool {
        switch runtimeState(for: project).status {
        case .running, .noResponse:
            return true
        case .stopped, .starting, .portBusy, .portMismatch, .noPort, .crashed:
            return false
        }
    }

    private func resetHealthStates() {
        for project in projects {
            healthStates[project.id] = .unknown
        }
        lastHealthStates.removeAll()
    }

    private func checkReadiness(
        for project: LocalProject,
        updateHealthState: Bool,
        force: Bool = false
    ) async {
        if
            !force,
            let lastCheck = lastReadinessCheckDates[project.id],
            Date().timeIntervalSince(lastCheck) < readinessCheckRefreshInterval
        {
            return
        }

        lastReadinessCheckDates[project.id] = Date()
        if updateHealthState {
            healthStates[project.id] = .checking
        }
        let next = await healthChecker.check(project)
        applyReadinessState(next, for: project)

        guard updateHealthState else { return }

        let previous = lastHealthStates[project.id]
        healthStates[project.id] = next
        lastHealthStates[project.id] = next
        notifyHealthChange(project: project, previous: previous, next: next)
    }

    private func applyReadinessState(_ health: HealthState, for project: LocalProject) {
        var state = runtimeStates[project.id] ?? .stopped
        guard state.status == .running || state.status == .noResponse else { return }

        switch health {
        case .healthy, .warning:
            state.status = .running
            state.lastMessage = "Listening on localhost:\(state.observedPort ?? project.port)"
        case .unreachable(let message):
            state.status = .noResponse
            state.lastMessage = message
        case .unknown, .checking:
            return
        }

        runtimeStates[project.id] = state
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
                notificationService.notify(title: "\(project.displayName) is ready", body: "Listening on localhost:\(project.port)")
            }
        case .warning(let code, _):
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
        UserDefaults.standard.set(pins, forKey: Self.pinnedPortsKey)
        UserDefaults.standard.set(Array(ignoredPorts).sorted(), forKey: Self.ignoredPortsKey)
    }

    private static func loadPinnedPorts() -> [Int: String] {
        guard let raw = UserDefaults.standard.dictionary(forKey: pinnedPortsKey) as? [String: String] else {
            return [:]
        }

        return raw.reduce(into: [Int: String]()) { result, item in
            if let port = Int(item.key) {
                result[port] = item.value
            }
        }
    }

    private static func loadIgnoredPorts() -> Set<Int> {
        let raw = UserDefaults.standard.array(forKey: ignoredPortsKey) as? [Int] ?? []
        return Set(raw)
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
