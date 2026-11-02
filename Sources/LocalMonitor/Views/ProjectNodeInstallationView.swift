import SwiftUI

struct ProjectNodeInstallationView: View {
    let requirement: ProjectNodeRequirement?
    let state: ProjectNodeInstallationState?
    let disabled: Bool
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if requirement != nil || state != nil {
            VStack(alignment: .leading, spacing: 6) {
                if state?.isRunning == true {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Installing Node.js…").font(.caption)
                        Spacer(minLength: 0)
                        Button("Cancel", action: onCancel).controlSize(.small)
                    }
                } else if let requirement {
                    Text("Node.js \(requirement.selector) is required by \(requirement.source.lastPathComponent).")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onInstall) {
                        Label("Install Node.js \(requirement.selector)", systemImage: "arrow.down.circle")
                    }
                    .controlSize(.small)
                    .disabled(disabled)
                    .help("Downloads a matching Node.js version using fnm or nvm, then checks this project's requirements.")
                }
                if let state, !state.isRunning {
                    Text(state.message)
                        .font(.caption)
                        .foregroundStyle(messageColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var messageColor: Color {
        switch state {
        case .failed: return .red
        case .succeeded: return .green
        default: return .secondary
        }
    }
}
