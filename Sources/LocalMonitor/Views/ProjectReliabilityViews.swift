import Charts
import SwiftUI

struct ProjectReliabilitySettingsView: View {
    let project: LocalProject
    let projects: [LocalProject]
    let onSave: (ProjectReliabilitySettings) -> Void
    let onPackageManager: (PackageManager) -> Void
    @State private var settings: ProjectReliabilitySettings
    @State private var environmentKeys: String
    @State private var composeServices: String

    init(project: LocalProject, projects: [LocalProject], onSave: @escaping (ProjectReliabilitySettings) -> Void,
         onPackageManager: @escaping (PackageManager) -> Void) {
        self.project = project; self.projects = projects; self.onSave = onSave; self.onPackageManager = onPackageManager
        _settings = State(initialValue: project.reliability)
        _environmentKeys = State(initialValue: project.reliability.requiredEnvironmentKeys.joined(separator: ", "))
        _composeServices = State(initialValue: project.reliability.composeServices.joined(separator: ", "))
    }

    var body: some View {
        DisclosureGroup("Requirements & Services") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Package manager", selection: Binding(get: { project.packageManager }, set: onPackageManager)) {
                    ForEach(PackageManager.allCases) { manager in Text(manager.displayName).tag(manager) }
                }
                Text("The package.json version pin is checked on Start. Standard dev/start commands follow this selection; edit custom commands in Launch Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Required environment keys (DATABASE_URL, API_URL)", text: $environmentKeys)
                    .accessibilityLabel("Required environment keys")
                TextField("Environment mode (auto, development, staging)", text: $settings.environmentMode)
                    .accessibilityLabel("Environment mode")
                if let validationMessage { Text(validationMessage).font(.caption).foregroundStyle(.orange) }
                Text("Auto follows the launch command; choose a mode for custom scripts. Required keys block Start when missing. Template keys are suggestions; values are never displayed.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Start and wait for these projects first").font(.caption.weight(.semibold))
                ForEach(projects.filter { $0.id != project.id }) { dependency in
                    Toggle(dependency.displayName, isOn: Binding(
                        get: { settings.dependencyProjectIDs.contains(dependency.id) },
                        set: { enabled in
                            settings.dependencyProjectIDs.removeAll { $0 == dependency.id }
                            if enabled { settings.dependencyProjectIDs.append(dependency.id) }
                        }
                    )).toggleStyle(.checkbox)
                }
                if settings.dependencyProjectIDs.contains(where: { id in !projects.contains(where: { $0.id == id }) }) {
                    Button("Remove unavailable dependencies") {
                        settings.dependencyProjectIDs.removeAll { id in !projects.contains(where: { $0.id == id }) }
                    }
                }
                TextField("Compose services (db, redis)", text: $composeServices)
                    .accessibilityLabel("Compose services to start")
                Text("Selected Compose services must define healthchecks. Shared dependencies keep running when this project stops.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Stepper("Memory warning: \(settings.memoryWarningMB) MB", value: $settings.memoryWarningMB, in: 128...65_536, step: 128)
                Stepper("CPU warning: \(settings.cpuWarningPercent)%", value: $settings.cpuWarningPercent, in: 50...3_200, step: 50)
                Stepper("Maximum automatic retries: \(settings.maximumRestarts)", value: $settings.maximumRestarts, in: 0...10)
                Text("Warnings require sustained usage. Retries use increasing delays and a five-minute limit window.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save Requirements & Services") {
                    settings.requiredEnvironmentKeys = split(environmentKeys)
                    settings.composeServices = split(composeServices)
                    onSave(settings.validated)
                }.disabled(validationMessage != nil)
            }
            .textFieldStyle(.roundedBorder).controlSize(.small).padding(.top, 8)
        }
        .font(.system(size: 11))
        .onChange(of: project.reliability) { _, value in
            settings = value
            environmentKeys = value.requiredEnvironmentKeys.joined(separator: ", ")
            composeServices = value.composeServices.joined(separator: ", ")
        }
    }

    private func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    private var validationMessage: String? {
        if split(environmentKeys).contains(where: { !ProjectReliabilitySettings.validEnvironmentKey($0) }) {
            return "Use environment key names only, without values or punctuation."
        }
        if settings.environmentMode.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) == nil {
            return "Choose a valid environment mode, such as development or staging."
        }
        if split(composeServices).contains(where: { $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) == nil }) {
            return "Use existing Compose service names, separated by commas."
        }
        return nil
    }
}

struct ProjectReliabilityDetailView: View {
    @ObservedObject var model: LocalMonitorModel
    let project: LocalProject

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Requirements & Diagnostics").font(.system(size: 12, weight: .bold))
            HStack {
                Button("Check Requirements") { Task { await model.checkRequirements(for: project) } }
                    .disabled(model.checkingProjects.contains(project.id) || model.installationTasks[project.id] != nil)
                if project.kind != .supabase {
                    if model.installationTasks[project.id] != nil {
                        ProgressView().controlSize(.small)
                        Button("Cancel Install") { model.cancelInstallation(for: project) }
                    } else {
                        Button("Install Dependencies") { Task { await model.installDependencies(for: project) } }
                            .disabled(![.stopped, .crashed, .portBusy].contains(model.runtimeState(for: project).status))
                            .help("Installs with the project's package manager. A matching manager version may be downloaded through Corepack.")
                    }
                }
            }.controlSize(.small)
            if let installation = model.installationStates[project.id] {
                Text(installation.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if model.checkingProjects.contains(project.id) { ProgressView("Checking…").controlSize(.small) }
            if let result = model.preflightResults[project.id] {
                if result.issues.isEmpty { Label("Requirements clear", systemImage: "checkmark.circle").foregroundStyle(.green) }
                ForEach(result.issues) { issue in
                    Label(issue.message, systemImage: symbol(issue.severity))
                        .foregroundStyle(color(issue.severity)).font(.caption).textSelection(.enabled)
                }
            }
            if let resources = model.resourceStates[project.id], let latest = resources.samples.last {
                Divider()
                Text(latest.summary).font(.caption.monospacedDigit())
                if let warning = resources.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("Resource history") {
                    VStack(alignment: .leading) {
                        Text("Memory (MB)").font(.caption)
                        Chart(resources.samples, id: \.date) { sample in
                            LineMark(x: .value("Time", sample.date), y: .value("MB", Double(sample.memoryBytes) / 1_048_576))
                        }.frame(height: 70).accessibilityLabel("Project and child process memory history")
                        Text("CPU (%)").font(.caption)
                        Chart(resources.samples, id: \.date) { sample in
                            LineMark(x: .value("Time", sample.date), y: .value("CPU", sample.cpuPercent))
                        }.frame(height: 70).accessibilityLabel("Project and child process CPU history")
                    }
                }.font(.caption)
            }
            let history = model.failureHistory[project.id] ?? []
            if !history.isEmpty {
                Divider()
                DisclosureGroup("Failure history (\(history.count))") {
                    ForEach(history.reversed()) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                            Text(record.diagnosis.title).font(.caption.weight(.semibold))
                            Text(record.diagnosis.recovery).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                    Button("Clear Failure History") { model.clearFailureHistory(for: project) }.controlSize(.small)
                }.font(.caption)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).localCardBackground()
    }

    private func symbol(_ severity: PreflightIssue.Severity) -> String {
        switch severity { case .info: return "info.circle"; case .warning: return "exclamationmark.triangle"; case .error: return "xmark.circle" }
    }
    private func color(_ severity: PreflightIssue.Severity) -> Color {
        switch severity { case .info: return .secondary; case .warning: return .orange; case .error: return .red }
    }
}
