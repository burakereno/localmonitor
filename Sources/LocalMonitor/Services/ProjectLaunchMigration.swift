import Foundation

enum ProjectLaunchMigration {
    /// Only migrate a default command. User-authored commands and saved ports stay intact.
    static func migrate(_ project: LocalProject) -> LocalProject {
        guard project.workspaceRootPath == nil else { return project }
        let profiles = ProjectDetector.launchProfiles(in: project.folderURL, preferredPort: project.port)
        let manager = project.packageManager
        let defaults: Set<String> = [
            "\(manager.devCommand)\(manager.scriptArguments("-p {port}"))",
            "\(manager.startCommand)\(manager.scriptArguments("-p {port}"))",
            "PORT={port} \(manager.devCommand)",
            "PORT={port} \(manager.startCommand)"
        ]
        guard defaults.contains(project.commandTemplate),
              let profile = ProjectWorkspace.preferredProfile(in: project.folderURL, profiles: profiles) else { return project }
        var migrated = project
        migrated.workspaceRootPath = project.path
        migrated.path = profile.folderURL.path
        migrated.profileName = profile.folderURL.lastPathComponent
        migrated.kind = profile.detection.kind
        migrated.packageManager = profile.detection.packageManager
        migrated.commandTemplate = profile.detection.commandTemplate
        if project.hostname == "localhost" { migrated.hostname = profile.detection.hostname }
        migrated.updatedAt = Date()
        return migrated
    }
}
