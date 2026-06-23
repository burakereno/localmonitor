import AppKit
import SwiftUI

private enum PanelMode: Hashable {
    case dashboard
    case projects
    case settings
}

struct StatusPanelView: View {
    @ObservedObject var model: LocalMonitorModel
    let onAddProject: () -> Void
    @ObservedObject private var launchAtLogin = LaunchAtLoginPreference.shared
    @ObservedObject private var updater = UpdateChecker.shared

    @AppStorage(MenuBarDisplayMode.storageKey) private var menuBarDisplayModeRaw = MenuBarDisplayMode.count.rawValue
    @AppStorage(AppPreference.stopProjectsOnQuitKey) private var stopProjectsOnQuit = false
    @AppStorage(AppPreference.openBrowserAfterStartKey) private var openBrowserAfterStart = true
    @AppStorage(AppPreference.scanExternalPortsKey) private var scanExternalPorts = true
    @AppStorage(AppPreference.showExternalInMenuBarKey) private var showExternalInMenuBar = true
    @AppStorage(AppPreference.defaultPortKey) private var defaultPort = 3000
    @AppStorage(AppPreference.refreshIntervalKey) private var refreshInterval = 15.0
    @AppStorage(AppPreference.showDockIconKey) private var showDockIcon = false
    @AppStorage(AppPreference.showDockValuesKey) private var showDockValues = false
    @AppStorage(AppPreference.safeKillKey) private var safeKill = true
    @AppStorage(AppPreference.notificationsKey) private var notifications = true
    @AppStorage(AppPreference.healthChecksKey) private var healthChecks = false

    @State private var activePanel = PanelMode.dashboard
    @State private var expandedPortGroupIDs: Set<String> = []
    @State private var showSystemPorts = false
    @State private var showFooterUpToDate = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            ZStack {
                switch activePanel {
                case .dashboard:
                    ScrollView {
                        content
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 12)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                case .projects:
                    ScrollView {
                        projectsContent
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 12)
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                case .settings:
                    ScrollView {
                        settingsContent
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 12)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.snappy(duration: 0.24), value: activePanel)

            Divider().opacity(0.5)

            footer
        }
        .frame(width: 420, height: 620)
        .preferredColorScheme(.dark)
        .onAppear {
            launchAtLogin.refresh()
        }
        .onChange(of: menuBarDisplayModeRaw) { _, _ in
            model.updateMenuBarTitle()
        }
        .onChange(of: showExternalInMenuBar) { _, _ in
            model.updateMenuBarTitle()
        }
        .onChange(of: scanExternalPorts) { _, _ in
            Task { await model.refresh() }
        }
        .onChange(of: notifications) { _, enabled in
            if enabled {
                NotificationService.shared.prepare()
            }
        }
        .onChange(of: healthChecks) { _, enabled in
            Task { await model.updateHealthChecks(enabled: enabled) }
        }
        .onChange(of: showDockIcon) { _, _ in
            notifyDockSettingsChanged()
        }
        .onChange(of: showDockValues) { _, _ in
            notifyDockSettingsChanged()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            SummaryCardView(
                projects: sortedProjects,
                onlineProjectIDs: Set(onlineProjectIDs),
                error: model.lastError
            )

            if model.projects.isEmpty {
                EmptyStatusView(
                    title: "No Projects Yet",
                    message: "Add a local project folder and Local Monitor will detect Next.js, Hono, package manager, command, and port.",
                    buttonTitle: "Add Project"
                ) {
                    onAddProject()
                }
            } else {
                projectList
            }

            if !model.groups.isEmpty {
                groupsSection
            }

            if let selected = selectedLogProject {
                LogPreviewCardView(
                    project: selected,
                    logs: model.logs(for: selected)
                ) {
                    model.selectedLogProjectID = nil
                } onClear: {
                    model.clearLogs(for: selected)
                } onCopy: {
                    model.copyLogs(for: selected)
                }
            }

            if scanExternalPorts {
                externalPortsSection
                systemPortsSection
            }
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "PROJECTS", trailing: "\(model.projects.count)")

            if !onlineProjects.isEmpty {
                projectGroupHeader(title: "ONLINE", count: onlineProjects.count, tint: .green)
                projectCards(for: onlineProjects)
            }

            if !offlineProjects.isEmpty {
                projectGroupHeader(title: "OFFLINE", count: offlineProjects.count, tint: .secondary)
                    .padding(.top, onlineProjects.isEmpty ? 0 : 4)
                projectCards(for: offlineProjects)
            }
        }
        .animation(.snappy(duration: 0.24), value: onlineProjectIDs)
        .animation(.snappy(duration: 0.24), value: offlineProjectIDs)
    }

    @ViewBuilder
    private func projectCards(for projects: [LocalProject]) -> some View {
        ForEach(projects) { project in
            ProjectCardView(
                project: project,
                state: model.runtimeState(for: project),
                identity: model.projectIdentities[project.id],
                preflight: model.preflightResults[project.id],
                conflict: model.conflictOwner(for: project),
                cleanRestartState: model.cleanRestartStates[project.id],
                cacheState: model.cacheStates[project.id]
            ) {
                Task { await model.startProject(project) }
            } onStop: {
                model.stopProject(project)
            } onRestart: {
                Task { await model.restartProject(project) }
            } onCleanRestart: {
                Task { await model.cleanRestartProject(project) }
            } onOpen: {
                model.openObservedPort(project)
            } onCopyURL: {
                model.copyObservedURL(project)
            } onLogs: {
                model.selectedLogProjectID = project.id
            }
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "WORKSPACES", trailing: "\(model.groups.count)")

            ForEach(model.groups) { group in
                WorkspaceGroupCardView(
                    group: group,
                    projects: model.projects.filter { group.projectIDs.contains($0.id) }
                ) {
                    Task { await model.startGroup(group) }
                } onStop: {
                    model.stopGroup(group)
                }
            }
        }
    }

    private var externalPortsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: "DISCOVERED PORTS",
                trailing: model.visiblePortGroups.count == model.primaryVisiblePorts.count
                    ? "\(model.primaryVisiblePorts.count)"
                    : "\(model.visiblePortGroups.count)/\(model.primaryVisiblePorts.count)"
            )

            if model.visiblePortGroups.isEmpty {
                Text("No listening local ports found.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .localCardBackground()
            } else {
                VStack(spacing: 0) {
                    ForEach(model.visiblePortGroups) { group in
                        ExternalPortGroupView(
                            group: group,
                            isExpanded: expandedPortGroupIDs.contains(group.id),
                            pendingKillPortID: model.pendingKillPortID
                        ) {
                            togglePortGroup(group.id)
                        } onOpen: { port in
                            model.openPortInBrowser(port)
                        } onCopy: { port in
                            model.copyURL(port)
                        } onPin: { port in
                            if port.pinnedName == nil {
                                model.pinPort(port)
                            } else {
                                model.unpinPort(port)
                            }
                        } onIgnore: { port in
                            model.ignorePort(port)
                        } onKill: { port in
                            Task { await model.requestKillPort(port) }
                        }

                        if group.id != model.visiblePortGroups.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .localCardBackground()
            }
        }
    }

    @ViewBuilder
    private var systemPortsSection: some View {
        if !model.systemPortGroups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        showSystemPorts.toggle()
                    }
                } label: {
                    HStack {
                        Text("SYSTEM / EMULATOR PORTS")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .tracking(0.4)

                        Spacer()

                        Text("\(model.systemPortGroups.count)/\(model.systemVisiblePorts.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        Image(systemName: showSystemPorts ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showSystemPorts {
                    VStack(spacing: 0) {
                        ForEach(model.systemPortGroups) { group in
                            ExternalPortGroupView(
                                group: group,
                                isExpanded: expandedPortGroupIDs.contains(group.id),
                                pendingKillPortID: model.pendingKillPortID
                            ) {
                                togglePortGroup(group.id)
                            } onOpen: { port in
                                model.openPortInBrowser(port)
                            } onCopy: { port in
                                model.copyURL(port)
                            } onPin: { port in
                                if port.pinnedName == nil {
                                    model.pinPort(port)
                                } else {
                                    model.unpinPort(port)
                                }
                            } onIgnore: { port in
                                model.ignorePort(port)
                            } onKill: { port in
                                Task { await model.requestKillPort(port) }
                            }

                            if group.id != model.systemPortGroups.last?.id {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .localCardBackground()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text("Hidden from main ports: emulator, simulator, system sharing, and protected helper processes.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .localCardBackground()
                }
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionView(title: "STARTUP") {
                SettingsToggleRowView(
                    icon: "power",
                    title: "Open at Login",
                    subtitle: "Open Local Monitor when you log in",
                    isOn: $launchAtLogin.isEnabled
                )

                Divider().opacity(0.35).padding(.vertical, 5)

                SettingsToggleRowView(
                    icon: "stop.circle",
                    title: "Stop on Quit",
                    subtitle: "Stop app-started project processes when quitting",
                    isOn: $stopProjectsOnQuit
                )

                Divider().opacity(0.35).padding(.vertical, 5)

                SettingsToggleRowView(
                    icon: "bell",
                    title: "Notifications",
                    subtitle: "Show ready, crash, and health alerts",
                    isOn: $notifications
                )
            }

            SettingsSectionView(title: "DISCOVERY") {
                SettingsToggleRowView(
                    icon: "network",
                    title: "External Ports",
                    subtitle: "List ports opened by other programs",
                    isOn: $scanExternalPorts
                )

                Divider().opacity(0.35).padding(.vertical, 5)

                SettingsToggleRowView(
                    icon: "menubar.arrow.up.rectangle",
                    title: "Menu Count",
                    subtitle: "Include external port count in tooltip",
                    isOn: $showExternalInMenuBar,
                    disabled: !scanExternalPorts
                )

                Divider().opacity(0.35).padding(.vertical, 5)

                Stepper(value: $refreshInterval, in: 10...60, step: 5) {
                    settingsValueRow(
                        icon: "arrow.clockwise",
                        title: "Refresh",
                        subtitle: "Port scan interval",
                        value: "\(Int(refreshInterval))s"
                    )
                }
                .controlSize(.small)

                if !model.ignoredPorts.isEmpty {
                    Divider().opacity(0.35).padding(.vertical, 5)

                    ForEach(Array(model.ignoredPorts).sorted(), id: \.self) { port in
                        HStack {
                            Label(String(port), systemImage: "eye.slash")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Show") {
                                model.showIgnoredPort(port)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            SettingsSectionView(title: "DEFAULTS") {
                Stepper(value: $defaultPort, in: 1_024...65_535, step: 1) {
                    settingsValueRow(
                        icon: "number",
                        title: "Default Port",
                        subtitle: "First choice for new projects",
                        value: "\(defaultPort)"
                    )
                }
                .controlSize(.small)

                Divider().opacity(0.35).padding(.vertical, 5)

                SettingsToggleRowView(
                    icon: "safari",
                    title: "Open Browser",
                    subtitle: "Open localhost after a project starts",
                    isOn: $openBrowserAfterStart
                )

                Divider().opacity(0.35).padding(.vertical, 5)

                SettingsToggleRowView(
                    icon: "heart.text.square",
                    title: "Health Checks",
                    subtitle: "Occasionally check HTTP readiness",
                    isOn: $healthChecks
                )

                Divider().opacity(0.35).padding(.vertical, 5)

                SettingsToggleRowView(
                    icon: "shield",
                    title: "Safe Kill",
                    subtitle: "Confirm protected or system-like processes",
                    isOn: $safeKill
                )
            }

            SettingsSectionView(title: "MENU BAR") {
                SettingsMenuBarDisplayRowView(selection: $menuBarDisplayModeRaw)
            }

            SettingsSectionView(title: "DOCK") {
                SettingsToggleRowView(
                    icon: "dock.rectangle",
                    title: "Dock Icon",
                    subtitle: "Show Local Monitor in the Dock",
                    isOn: $showDockIcon
                )

                Divider().opacity(0.35).padding(.vertical, 5)

                SettingsToggleRowView(
                    icon: "number.square",
                    title: "Values",
                    subtitle: "Show running count on the Dock icon",
                    isOn: $showDockValues,
                    disabled: !showDockIcon
                )
            }

            AboutCardView()
        }
    }

    private var projectsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title: "PROJECTS", trailing: "\(model.projects.count)")

                Button {
                    onAddProject()
                } label: {
                    Label("Add Project Folder", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.07))
                        }
                }
                .buttonStyle(.plain)

                if model.projects.isEmpty {
                    Text("No saved projects yet.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .localCardBackground()
                } else {
                    ForEach(sortedProjects) { project in
                        ProjectSettingsEditorView(
                            project: project,
                            port: binding(
                                get: { project.port },
                                set: { model.updatePort(for: project, port: $0) }
                            ),
                            autoRestart: binding(
                                get: { project.autoRestart },
                                set: { model.updateAutoRestart(for: project, enabled: $0) }
                            ),
                            openAfterStart: binding(
                                get: { project.openAfterStart },
                                set: { model.updateOpenAfterStart(for: project, enabled: $0) }
                            )
                        ) {
                            model.revealProject(project)
                        } onRemove: {
                            model.removeProject(project)
                        }
                        .padding(12)
                        .localCardBackground()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title: "WORKSPACES", trailing: "\(model.groups.count)")

                Button {
                    model.addWorkspaceGroup()
                } label: {
                    Label("Add Workspace Group", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.07))
                        }
                }
                .buttonStyle(.plain)

                if model.groups.isEmpty {
                    Text("No workspace groups yet.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .localCardBackground()
                } else {
                    ForEach(model.groups) { group in
                        WorkspaceGroupSettingsView(
                            group: group,
                            projects: model.projects,
                            name: binding(
                                get: { group.name },
                                set: { model.updateWorkspaceGroupName(group, name: $0) }
                            ),
                            membership: { project in
                                binding(
                                    get: { group.projectIDs.contains(project.id) },
                                    set: { model.toggleProject(project, in: group, enabled: $0) }
                                )
                            }
                        ) {
                            model.removeWorkspaceGroup(group)
                        }
                        .padding(12)
                        .localCardBackground()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)

                Text("Local Monitor")
                    .font(.system(size: 14, weight: .bold))
            }

            Spacer()

            headerModeButton(
                mode: .projects,
                systemName: activePanel == .projects ? "folder.fill" : "folder",
                help: "Projects"
            )

            headerModeButton(
                mode: .settings,
                systemName: activePanel == .settings ? "gearshape.fill" : "gearshape",
                help: "Settings"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func headerModeButton(mode: PanelMode, systemName: String, help: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.24)) {
                activePanel = activePanel == mode ? .dashboard : mode
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundStyle(activePanel == mode ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(activePanel == mode ? Color.primary.opacity(0.08) : Color.clear)
                }
        }
        .buttonStyle(.plain)
        .help(activePanel == mode ? "Close \(help)" : help)
        .accessibilityLabel(activePanel == mode ? "Close \(help)" : help)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.refresh() }
            } label: {
                HStack(spacing: 6) {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    }

                    Text(model.isRefreshing ? "Refreshing" : "Refresh")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
            .help(model.isRefreshing ? "Refreshing" : "Refresh")

            Spacer()

            footerTrailingActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footerTrailingActions: some View {
        HStack(spacing: 8) {
            Button {
                DashboardWindowController.shared.show(model: model)
            } label: {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Dashboard")

            if updater.updateAvailable, let latestVersion = updater.latestVersion {
                UpdateButton(version: latestVersion)
            } else {
                footerVersionStatus
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.06))
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private var footerVersionStatus: some View {
        HStack(spacing: 6) {
            Button {
                Task { await updater.checkForUpdates(force: true) }
            } label: {
                Image(systemName: updater.isChecking ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(updater.isChecking ? .tertiary : .secondary)
                    .frame(width: 14, height: 14)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(updater.isChecking)
            .help(updater.isChecking ? "Checking for Updates" : "Check for Updates")
            .onHover { hovering in
                if hovering && !updater.isChecking { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }

            Text(footerUpdateText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(footerUpdateColor)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeInOut(duration: 0.18), value: updater.isChecking)
        .animation(.easeInOut(duration: 0.18), value: updater.lastCheckCompletedAt)
        .onChange(of: updater.lastCheckCompletedAt) { _, _ in
            guard updater.isUpToDate else { return }
            Task {
                showFooterUpToDate = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                showFooterUpToDate = false
            }
        }
    }

    private var footerUpdateText: String {
        if updater.isChecking { return "Checking" }
        if updater.lastError != nil { return "Check failed" }
        if showFooterUpToDate { return "Up to date" }
        return "v\(appVersion)"
    }

    private var footerUpdateColor: Color {
        if updater.lastError != nil { return .red }
        if showFooterUpToDate { return .green }
        return .secondary
    }

    private var selectedLogProject: LocalProject? {
        guard let id = model.selectedLogProjectID else { return nil }
        return model.projects.first { $0.id == id }
    }

    private var lastUpdatedText: String {
        guard let date = model.lastUpdated else { return "Waiting" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var sortedProjects: [LocalProject] {
        model.projects
            .enumerated()
            .sorted { lhs, rhs in
                let lhsRank = projectSortRank(lhs.element)
                let rhsRank = projectSortRank(rhs.element)

                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private var onlineProjects: [LocalProject] {
        sortedProjects.filter(isProjectOnline)
    }

    private var offlineProjects: [LocalProject] {
        sortedProjects.filter { !isProjectOnline($0) }
    }

    private func isProjectOnline(_ project: LocalProject) -> Bool {
        model.isProjectOnlineForGrouping(project)
    }

    private var onlineProjectIDs: [UUID] {
        onlineProjects.map(\.id)
    }

    private var offlineProjectIDs: [UUID] {
        offlineProjects.map(\.id)
    }

    private func projectSortRank(_ project: LocalProject) -> Int {
        isProjectOnline(project) ? 0 : 1
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private func sectionHeader(title: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            Spacer()

            Text(trailing)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func projectGroupHeader(title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.45)

            Spacer()

            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)
    }

    private func settingsValueRow(icon: String, title: String, subtitle: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func binding<Value>(
        get: @escaping () -> Value,
        set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: set)
    }

    private func notifyDockSettingsChanged() {
        NotificationCenter.default.post(name: .localMonitorDockSettingsChanged, object: nil)
    }

    private func togglePortGroup(_ id: String) {
        if expandedPortGroupIDs.contains(id) {
            expandedPortGroupIDs.remove(id)
        } else {
            expandedPortGroupIDs.insert(id)
        }
    }
}

private struct SummaryCardView: View {
    let projects: [LocalProject]
    let onlineProjectIDs: Set<UUID>
    let error: String?

    private let visibleProjectLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.green)

                    Text("Running Projects")
                        .font(.system(size: 12, weight: .bold))
                }

                Spacer()

                Text(error == nil ? statusText : "Needs Attention")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(error == nil ? .green : .orange)
            }

            projectIconStrip

            if let error {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .localCardBackground()
    }

    private var projectIconStrip: some View {
        HStack(spacing: 8) {
            if projects.isEmpty {
                Text("No projects yet")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(projects.prefix(visibleProjectLimit))) { project in
                    ProjectAvatarView(project: project, tint: avatarTint(for: project))
                        .opacity(isOnline(project) ? 1 : 0.28)
                        .help(project.displayName)
                        .accessibilityLabel(project.displayName)
                }

                if hiddenProjectCount > 0 {
                    Text("+\(hiddenProjectCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background {
                            Circle()
                                .fill(Color.primary.opacity(0.08))
                        }
                        .help("\(hiddenProjectCount) more projects")
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hiddenProjectCount: Int {
        max(projects.count - visibleProjectLimit, 0)
    }

    private var runningCount: Int {
        onlineProjectIDs.count
    }

    private var statusText: String {
        "\(runningCount) Running"
    }

    private func isOnline(_ project: LocalProject) -> Bool {
        onlineProjectIDs.contains(project.id)
    }

    private func avatarTint(for project: LocalProject) -> Color {
        switch project.kind {
        case .nextjs:
            return .primary
        case .hono:
            return .orange
        case .vite, .supabase:
            return .green
        case .astro, .storybook:
            return .purple
        case .remix, .sveltekit, .nuxt:
            return .blue
        case .expo:
            return .cyan
        case .prisma:
            return .indigo
        case .unknown:
            return .blue
        }
    }
}

private struct AboutCardView: View {
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("ABOUT")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)

                Spacer()

                updateCheckButton
            }

            HStack(spacing: 9) {
                Image(systemName: "terminal")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Monitor")
                        .font(.system(size: 13, weight: .bold))

                    Text("Version \(updater.currentVersion)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text("Menu bar control for local web projects and ports")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if updater.updateAvailable, let latestVersion = updater.latestVersion {
                    UpdateButton(version: latestVersion)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            updateStatusText
        }
        .padding(12)
        .localCardBackground()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updateCheckButton: some View {
        Button {
            Task { await updater.checkForUpdates(force: true) }
        } label: {
            HStack(spacing: 4) {
                if updater.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                }

                Text(updateCheckButtonTitle)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(updateCheckButtonForeground)
            .frame(width: 86, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(updater.isChecking ? 0.035 : 0.06))
            }
        }
        .buttonStyle(.plain)
        .disabled(updater.isChecking)
        .help(updater.isChecking ? "Checking for Updates" : "Check for Updates")
        .animation(.easeInOut(duration: 0.18), value: updater.isChecking)
        .animation(.easeInOut(duration: 0.18), value: updater.lastCheckCompletedAt)
    }

    private var updateCheckButtonTitle: String {
        if updater.isChecking { return "Checking" }
        if updater.lastError != nil { return "Failed" }
        if updater.isUpToDate && updater.lastCheckCompletedAt != nil { return "Up to date" }
        return "Check"
    }

    private var updateCheckButtonForeground: Color {
        if updater.isChecking { return Color(nsColor: .tertiaryLabelColor) }
        if updater.lastError != nil { return .red }
        if updater.isUpToDate && updater.lastCheckCompletedAt != nil { return .green }
        return .secondary
    }

    @ViewBuilder
    private var updateStatusText: some View {
        if updater.isChecking {
            Text("Checking for updates...")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else if updater.updateAvailable, let latestVersion = updater.latestVersion {
            Text("Version \(latestVersion) available")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else if updater.lastError != nil {
            Text("Update check failed")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        } else if updater.isUpToDate && updater.lastCheckCompletedAt != nil {
            Text("Up to date")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        }
    }
}
