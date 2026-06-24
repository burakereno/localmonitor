import SwiftUI

struct DashboardWindowView: View {
    @ObservedObject var model: LocalMonitorModel
    @AppStorage(AppPreference.healthChecksKey) private var healthChecks = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Local Monitor", systemImage: "server.rack")
                    .font(.system(size: 16, weight: .bold))

                Spacer()

                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    dashboardSection("Projects") {
                        ForEach(model.projects) { project in
                            let state = model.runtimeState(for: project)
                            HStack(spacing: 10) {
                                Image(systemName: project.kind.symbolName)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.displayName)
                                        .font(.system(size: 13, weight: .bold))

                                    Text("\(project.kind.displayName) · :\(project.port) · \(model.projectIdentities[project.id]?.branch ?? "no branch")")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(projectStatusText(project: project, state: state))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(state.status == .running ? .green : .secondary)
                            }
                            .padding(10)
                            .localCardBackground(cornerRadius: 8)
                        }
                    }

                    dashboardSection("Ports") {
                        ForEach(model.primaryVisiblePorts) { port in
                            HStack(spacing: 10) {
                                Image(systemName: port.isManaged ? "checkmark.circle.fill" : "network")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(port.isManaged ? .green : .orange)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(port.displayOwner)
                                            .font(.system(size: 12, weight: .bold))
                                            .lineLimit(1)

                                        Text("|")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.tertiary)

                                        Text(verbatim: String(port.port))
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    }

                                    Text(port.detailText)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(10)
                            .localCardBackground(cornerRadius: 8)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private func dashboardSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            content()
        }
    }

    private func projectStatusText(project: LocalProject, state: ProjectRuntimeState) -> String {
        guard healthChecks else { return state.status.displayName }
        return model.healthStates[project.id]?.displayName ?? state.status.displayName
    }
}
