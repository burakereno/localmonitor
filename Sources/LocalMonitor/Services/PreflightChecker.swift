import Foundation

struct PreflightChecker {
    var nodeRuntimeResolver = ProjectNodeRuntimeResolver()
    var packageRuntimeResolver = ProjectPackageRuntimeResolver()
    var dependencyInstallation = ProjectDependencyInstallation()

    func check(_ project: LocalProject) async -> PreflightResult {
        var issues: [PreflightIssue] = []
        var launchEnvironment: ProjectLaunchEnvironment?
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: project.path) {
            issues.append(PreflightIssue(severity: .error, message: "Folder missing"))
        }

        let packageURL = project.folderURL.appendingPathComponent("package.json")
        if !fileManager.fileExists(atPath: packageURL.path), project.kind != .supabase {
            issues.append(PreflightIssue(severity: .warning, message: "package.json missing"))
        }

        if ProjectWorkspace.dependencyDirectory(in: project.folderURL) == nil,
           ![ProjectKind.supabase, .prisma].contains(project.kind) {
            issues.append(PreflightIssue(severity: .warning, message: "node_modules missing"))
        }

        do {
            let environment = try await ProjectLaunchEnvironment.prepare(project, nodeResolver: nodeRuntimeResolver,
                                                                          packageResolver: packageRuntimeResolver)
            launchEnvironment = environment
            if let node = environment.node {
                issues.append(PreflightIssue(severity: .info, message: "Node \(node.version) selected from \(node.requirement.source.lastPathComponent)."))
            }
            if let package = environment.package {
                issues.append(PreflightIssue(severity: .info, message: "\(package.manager.rawValue) \(package.version) selected."))
            }
            if project.kind != .supabase, await !commandExists(project.packageManager.rawValue, environment: environment) {
                issues.append(PreflightIssue(severity: .error, message: "\(project.packageManager.displayName) not found"))
            }
            issues += try dependencyInstallation.issues(for: project, environment: environment)
        } catch {
            issues.append(PreflightIssue(severity: .error, message: error.localizedDescription))
        }

        do {
            let checker = ProjectEnvironmentChecker()
            let presence = try await checker.shellPresence(for: project)
            issues += try checker.issues(for: project, shellPresence: presence)
        } catch {
            issues.append(PreflightIssue(severity: .error, message: "Environment checks could not complete. Review the environment files and try again."))
        }

        if project.commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(PreflightIssue(severity: .error, message: "Command missing"))
        }

        return PreflightResult(issues: issues, launchEnvironment: launchEnvironment)
    }

    private func commandExists(_ command: String, environment: ProjectLaunchEnvironment) async -> Bool {
        let lookup = "command -v \(ProjectNodeRuntime.quote(command)) >/dev/null 2>&1"
        guard
            let result = try? await Shell.run(
                "/bin/zsh",
                arguments: ["-lc", environment.command(lookup)]
            )
        else {
            return false
        }

        return result.status == 0
    }
}
