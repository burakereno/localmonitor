import Foundation

struct ProjectInspector {
    func inspect(_ project: LocalProject) async -> ProjectIdentity {
        ProjectIdentity(
            branch: await gitBranch(in: project.folderURL),
            packageName: project.name,
            framework: project.kind,
            hasNodeModules: false,
            hasEnvFile: false
        )
    }

    private func gitBranch(in folderURL: URL) async -> String? {
        guard
            let result = try? await Shell.run(
                "/usr/bin/git",
                arguments: ["-C", folderURL.path, "branch", "--show-current"],
                timeout: 2
            ),
            result.status == 0
        else {
            return nil
        }

        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}
