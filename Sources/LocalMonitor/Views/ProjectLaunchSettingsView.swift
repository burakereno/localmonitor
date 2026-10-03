import SwiftUI

struct ProjectLaunchSettingsView: View {
    let project: LocalProject
    let onCommand: (String) -> Void
    let onHostname: (String) -> Void
    let onHealthPath: (String) -> Void
    @State private var command: String
    @State private var hostname: String
    @State private var healthPath: String

    init(project: LocalProject, onCommand: @escaping (String) -> Void,
         onHostname: @escaping (String) -> Void, onHealthPath: @escaping (String) -> Void) {
        self.project = project
        self.onCommand = onCommand
        self.onHostname = onHostname
        self.onHealthPath = onHealthPath
        _command = State(initialValue: project.commandTemplate)
        _hostname = State(initialValue: project.hostname)
        _healthPath = State(initialValue: project.healthPath)
    }

    var body: some View {
        DisclosureGroup("Launch Settings") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Working folder: \(project.compactPath)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                TextField("Command ({port} follows the saved port)", text: $command)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { save() }
                TextField("Hostname", text: $hostname).onSubmit { save() }
                if LocalHostname.normalize(hostname) == nil {
                    Text("Use localhost, a *.localhost name, or a loopback IP.")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("Health check path", text: $healthPath).onSubmit { save() }
                Button("Save Launch Settings", action: save)
                    .disabled(LocalHostname.normalize(hostname) == nil || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 6)
        }
        .font(.system(size: 11))
        .onChange(of: project.commandTemplate) { _, value in command = value }
        .onChange(of: project.hostname) { _, value in hostname = value }
        .onChange(of: project.healthPath) { _, value in healthPath = value }
    }

    private func save() {
        guard LocalHostname.normalize(hostname) != nil,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onCommand(command)
        onHostname(hostname)
        onHealthPath(healthPath)
    }
}
