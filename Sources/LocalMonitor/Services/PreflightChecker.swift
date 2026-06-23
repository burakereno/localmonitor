import Foundation

struct PreflightChecker {
    func check(_ project: LocalProject) async -> PreflightResult {
        var issues: [PreflightIssue] = []
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: project.path) {
            issues.append(PreflightIssue(severity: .error, message: "Folder missing"))
        }

        let packageURL = project.folderURL.appendingPathComponent("package.json")
        if !fileManager.fileExists(atPath: packageURL.path), project.kind != .supabase {
            issues.append(PreflightIssue(severity: .warning, message: "package.json missing"))
        }

        if !fileManager.fileExists(atPath: project.folderURL.appendingPathComponent("node_modules").path),
           ![ProjectKind.supabase, .prisma].contains(project.kind) {
            issues.append(PreflightIssue(severity: .warning, message: "node_modules missing"))
        }

        if !hasEnvFile(in: project.folderURL) {
            issues.append(PreflightIssue(severity: .info, message: ".env not found"))
        }

        if await !commandExists(project.packageManager.rawValue), project.kind != .supabase {
            issues.append(PreflightIssue(severity: .error, message: "\(project.packageManager.displayName) not found"))
        }

        if project.commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(PreflightIssue(severity: .error, message: "Command missing"))
        }

        return PreflightResult(issues: issues)
    }

    private func hasEnvFile(in folderURL: URL) -> Bool {
        [".env.local", ".env", ".env.development", ".dev.vars"].contains { name in
            FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(name).path)
        }
    }

    private func commandExists(_ command: String) async -> Bool {
        guard
            let result = try? await Shell.run(
                "/bin/zsh",
                arguments: ["-lc", "command -v \(command) >/dev/null 2>&1"]
            )
        else {
            return false
        }

        return result.status == 0
    }
}
