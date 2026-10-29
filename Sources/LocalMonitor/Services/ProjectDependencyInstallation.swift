import CryptoKit
import Foundation

struct ProjectDependencyInstallation {
    var storageRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Local Monitor/DependencyInstalls", isDirectory: true)

    struct Record: Codable {
        let fingerprint: String
        let nodeMajor: Int?
        let manager: String
        var managerVersion: String? = nil
        let installedAt: Date
    }

    func folder(for project: LocalProject) -> URL {
        let folder = (ProjectWorkspace.root(containing: project.folderURL) ?? project.folderURL)
            .standardizedFileURL.resolvingSymlinksInPath()
        return URL(fileURLWithPath: folder.path, isDirectory: true)
    }

    func fingerprint(_ project: LocalProject) throws -> String {
        let root = folder(for: project)
        let files = [root.appendingPathComponent("package.json"), project.folderURL.appendingPathComponent("package.json")]
            + ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"].map { root.appendingPathComponent($0) }
        var hash = SHA256()
        var seen = Set<String>()
        for file in files where seen.insert(file.path).inserted {
            if let data = try ProjectMetadata.data(at: file, limit: 8_388_608) {
                hash.update(data: Data(file.path.utf8)); hash.update(data: data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func issues(for project: LocalProject, environment: ProjectLaunchEnvironment) throws -> [PreflightIssue] {
        guard ![.supabase, .prisma].contains(project.kind),
              ProjectWorkspace.dependencyDirectory(in: project.folderURL) != nil else { return [] }
        var issues: [PreflightIssue] = []
        let localRecord = try record(at: recordURL(project))
        let sharedRecord = try record(at: workspaceRecordURL(project))
        if localRecord == nil {
            issues.append(PreflightIssue(severity: .info, message: "Dependency installation has not been verified. Install Dependencies records its lockfile and Node version."))
        }
        if let localRecord, localRecord.fingerprint != (try fingerprint(project)) {
            issues.append(PreflightIssue(severity: .warning, message: "Package or lockfile changed since the last successful install. Run Install Dependencies."))
        }
        guard let record = sharedRecord ?? localRecord else { return issues }
        if let major = environment.nodeVersion?.major, let previous = record.nodeMajor, major != previous {
            issues.append(PreflightIssue(severity: .warning, message: "Dependencies were installed with Node \(previous), now Node \(major) is selected. Reinstall to rebuild native packages."))
        }
        if record.manager != project.packageManager.rawValue {
            issues.append(PreflightIssue(severity: .warning, message: "The package manager changed since dependencies were installed. Run Install Dependencies."))
        }
        if let selected = environment.package?.version ?? environment.observedPackageVersion,
           let installed = record.managerVersion, selected != installed {
            issues.append(PreflightIssue(severity: .warning, message: "The package manager version changed since dependencies were installed. Run Install Dependencies."))
        }
        return issues
    }

    func installCommand(for project: LocalProject, environment: ProjectLaunchEnvironment) -> String {
        let root = folder(for: project)
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
        switch project.packageManager {
        case .npm: return exists("package-lock.json") || exists("npm-shrinkwrap.json") ? "npm ci" : "npm install"
        case .pnpm: return "pnpm install" + (exists("pnpm-lock.yaml") ? " --frozen-lockfile" : "")
        case .bun: return "bun install" + (exists("bun.lock") || exists("bun.lockb") ? " --frozen-lockfile" : "")
        case .yarn:
            guard exists("yarn.lock") else { return "yarn install" }
            let major = (environment.package?.version ?? environment.observedPackageVersion)?.split(separator: ".").first.flatMap { Int($0) } ?? 1
            return "yarn install \(major >= 2 ? "--immutable" : "--frozen-lockfile")"
        }
    }

    func recordSuccess(_ project: LocalProject, environment: ProjectLaunchEnvironment, fingerprint: String) throws {
        // Do not certify an install if metadata changed while the package manager was running.
        guard try self.fingerprint(project) == fingerprint else {
            throw ProjectReliabilityError.message("Dependency files changed during installation. Run Install Dependencies again.")
        }
        let record = Record(fingerprint: fingerprint, nodeMajor: environment.nodeVersion?.major,
                            manager: project.packageManager.rawValue,
                            managerVersion: environment.package?.version ?? environment.observedPackageVersion, installedAt: Date())
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: recordURL(project), options: .atomic)
        try data.write(to: workspaceRecordURL(project), options: .atomic)
    }

    private func record(at url: URL) throws -> Record? {
        guard let data = try ProjectMetadata.data(at: url, limit: 16_384) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func workspaceRecordURL(_ project: LocalProject) -> URL {
        let key = SHA256.hash(data: Data(folder(for: project).path.utf8)).map { String(format: "%02x", $0) }.joined()
        return storageRoot.appendingPathComponent("workspace-" + key + ".json")
    }

    private func recordURL(_ project: LocalProject) -> URL {
        let key = SHA256.hash(data: Data(project.folderURL.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return storageRoot.appendingPathComponent(key + ".json")
    }
}
