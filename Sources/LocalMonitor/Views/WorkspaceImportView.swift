import SwiftUI

struct WorkspaceImportView: View {
    let workspace: WorkspaceImport
    let onAdd: ([ProjectLaunchProfile]) -> Void
    let onCancel: () -> Void
    @State private var selectedIDs: Set<String>

    init(workspace: WorkspaceImport, onAdd: @escaping ([ProjectLaunchProfile]) -> Void, onCancel: @escaping () -> Void) {
        self.workspace = workspace
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selectedIDs = State(initialValue: Set(workspace.availableProfiles.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(workspace.rootURL.lastPathComponent)
                .font(.headline)
            Text("Select additional apps to add. Added apps keep their current settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(workspace.profiles) { profile in
                        let saved = workspace.savedProject(for: profile)
                        Toggle(isOn: saved == nil ? selection(for: profile.id) : .constant(true)) {
                            WorkspaceAppLabelView(profile: profile, savedProject: saved)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(saved != nil)
                    }
                }
            }
            if workspace.availableProfiles.isEmpty {
                Text(workspace.profiles.isEmpty ? "No runnable workspace apps found." : "All workspace apps have already been added.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Apps") {
                    onAdd(workspace.availableProfiles.filter { selectedIDs.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 390, height: 340)
    }

    private func selection(for id: String) -> Binding<Bool> {
        Binding(get: { selectedIDs.contains(id) }, set: { selected in
            if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        })
    }
}

private struct WorkspaceAppLabelView: View {
    let profile: ProjectLaunchProfile
    let savedProject: LocalProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(profile.folderURL.lastPathComponent).fontWeight(.semibold)
                if savedProject != nil {
                    Text("Added").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(profile.relativePath).font(.caption).foregroundStyle(.secondary)
            Text("\(profile.detection.kind.displayName) · \(savedProject?.hostname ?? profile.detection.hostname):\(savedProject?.port ?? profile.detection.defaultPort)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
