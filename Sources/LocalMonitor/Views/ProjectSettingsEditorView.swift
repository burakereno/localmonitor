import SwiftUI

struct ProjectSettingsEditorView: View {
    let project: LocalProject
    let port: Binding<Int>
    let autoRestart: Binding<Bool>
    let openAfterStart: Binding<Bool>
    let launchSettings: ProjectLaunchSettingsView
    let onReveal: () -> Void
    let onRemove: () -> Void
    let onWorkspaceApps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: project.kind.symbolName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)

                    Text(project.kind.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if project.workspaceRootPath != nil {
                    IconActionButton(systemName: "square.grid.2x2", help: "Workspace Apps", action: onWorkspaceApps)
                }
                IconActionButton(systemName: "folder", help: "Reveal Folder", action: onReveal)
                IconActionButton(systemName: "trash", help: "Remove Project", tint: .red, action: onRemove)
            }

            Stepper(value: port, in: 1_024...65_535, step: 1) {
                HStack {
                    Label("Port", systemImage: "number")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(port.wrappedValue)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
            }
            .controlSize(.small)

            Toggle("Auto-restart after crash", isOn: autoRestart)
                .font(.system(size: 11, weight: .medium))
                .toggleStyle(.checkbox)

            Toggle("Open browser after start", isOn: openAfterStart)
                .font(.system(size: 11, weight: .medium))
                .toggleStyle(.checkbox)

            launchSettings
        }
        .padding(.vertical, 5)
    }
}
