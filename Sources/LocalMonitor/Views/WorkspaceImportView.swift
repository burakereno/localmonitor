import SwiftUI

struct WorkspaceImportView: View {
    let workspace: WorkspaceImport
    let onAdd: ([ProjectLaunchProfile]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String>

    init(workspace: WorkspaceImport, onAdd: @escaping ([ProjectLaunchProfile]) -> Void) {
        self.workspace = workspace
        self.onAdd = onAdd
        _selectedIDs = State(initialValue: Set(workspace.profiles.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Workspace Apps")
                .font(.headline)
            Text("Choose the apps to add. Each app gets its own Start, Stop, port, and browser address.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(workspace.profiles) { profile in
                        Toggle(isOn: selection(for: profile.id)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.folderURL.lastPathComponent).fontWeight(.semibold)
                                Text("\(profile.detection.kind.displayName) · \(profile.detection.hostname):\(profile.detection.defaultPort)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Apps") {
                    onAdd(workspace.profiles.filter { selectedIDs.contains($0.id) })
                    dismiss()
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
