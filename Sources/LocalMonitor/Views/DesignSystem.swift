import SwiftUI

struct CardBackground: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(cardFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(cardHighlight, lineWidth: 0.5)
                    }
                    .shadow(color: cardShadow, radius: 8, y: 2)
            }
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.50) : Color.black.opacity(0.50)
    }

    private var cardHighlight: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045)
    }

    private var cardShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.065)
    }
}

extension View {
    func localCardBackground(cornerRadius: CGFloat = 10) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

struct IconActionButton: View {
    let systemName: String
    let help: String
    var tint: Color = .secondary
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.45) : tint)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(disabled ? 0.035 : 0.065))
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct StatusBadge: View {
    let status: ProjectRunStatus

    var body: some View {
        Text(status.displayName)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(tint.opacity(0.12))
            }
    }

    private var tint: Color {
        switch status {
        case .stopped:
            return .secondary
        case .starting:
            return .orange
        case .running:
            return .green
        case .portBusy:
            return .orange
        case .portMismatch, .noPort:
            return .orange
        case .crashed:
            return .red
        }
    }
}

struct StatusDot: View {
    let status: ProjectRunStatus

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .stroke(tint.opacity(0.35), lineWidth: 3)
            }
            .frame(width: 24, height: 24)
            .help(status.displayName)
            .accessibilityLabel(status.displayName)
    }

    private var tint: Color {
        switch status {
        case .running:
            return .green
        case .starting, .portBusy, .portMismatch, .noPort:
            return .orange
        case .crashed:
            return .red
        case .stopped:
            return .secondary.opacity(0.75)
        }
    }
}

struct MetadataChip: View {
    let icon: String
    let text: String
    var tint: Color = .secondary
    var help: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(0.10))
        }
        .help(help ?? text)
    }
}

struct SettingsSectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .localCardBackground()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsToggleRowView: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(disabled ? .tertiary : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(disabled ? .tertiary : .primary)

                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .padding(.vertical, 3)
    }
}

struct SettingsMenuBarDisplayRowView: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Display")
                    .font(.system(size: 12, weight: .semibold))

                Text("Choose menu bar layout")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Picker("", selection: $selection) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .frame(width: 136, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

struct EmptyStatusView: View {
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: action) {
                Label(buttonTitle, systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 142)
    }
}
