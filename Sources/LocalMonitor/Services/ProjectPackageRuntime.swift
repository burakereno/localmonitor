import CryptoKit
import Foundation

struct ProjectPackageRequirement: Equatable {
    let manager: PackageManager
    let version: String
    let source: URL

    static func read(in folder: URL) throws -> Self? {
        for directory in ProjectMetadata.ancestors(of: folder) {
            guard let package = try ProjectMetadata.package(at: directory) else { continue }
            let source = directory.appendingPathComponent("package.json")
            if let declaration = package["packageManager"] as? String {
                let parts = declaration.split(separator: "@", maxSplits: 1).map(String.init)
                guard parts.count == 2, let manager = PackageManager(rawValue: parts[0]),
                      !parts[1].isEmpty else {
                    throw ProjectReliabilityError.message("Invalid packageManager in \(source.path). Use a manager and version, such as pnpm@9.15.0.")
                }
                return Self(manager: manager, version: parts[1], source: source)
            }
            if let engines = package["devEngines"] as? [String: Any],
               let manager = engines["packageManager"] as? [String: Any],
               let name = manager["name"] as? String, let version = manager["version"] as? String,
               let type = PackageManager(rawValue: name) {
                return Self(manager: type, version: version, source: source)
            }
        }
        return nil
    }

    var range: NodeVersionRange {
        get throws {
            guard let number = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first, !number.isEmpty else {
                throw ProjectReliabilityError.message("A valid package manager version is required in package.json.")
            }
            return try NodeVersionRange(String(number))
        }
    }
}

struct ProjectPackageRuntime: Equatable {
    let manager: PackageManager
    let version: String
    let shimDirectory: URL

    func command(_ command: String) -> String {
        "export PATH=\(ProjectNodeRuntime.quote(shimDirectory.path)):\"$PATH\"\nrehash\n\(command)"
    }
}

struct ProjectLaunchEnvironment: Equatable {
    var node: ProjectNodeRuntime?
    var package: ProjectPackageRuntime?
    var observedNode: NodeVersion? = nil
    var observedPackageVersion: String? = nil
    var allowsPackageDownload = false

    var nodeVersion: NodeVersion? { node?.version ?? observedNode }

    func command(_ command: String) -> String {
        let prepared = package?.command(command) ?? command
        let command = node?.command(prepared) ?? prepared
        return "export COREPACK_ENABLE_NETWORK=\(allowsPackageDownload ? 1 : 0) COREPACK_ENABLE_AUTO_PIN=0 COREPACK_DEFAULT_TO_LATEST=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0\n" + command
    }

    static func prepare(_ project: LocalProject, nodeResolver: ProjectNodeRuntimeResolver = .init(),
                        packageResolver: ProjectPackageRuntimeResolver = .init(), allowDownload: Bool = false) async throws -> Self {
        let node = try await nodeResolver.resolve(in: project.folderURL)
        let package = project.kind == .supabase ? nil : try await packageResolver.resolve(project, node: node, allowDownload: allowDownload)
        var observed: NodeVersion?
        if node == nil, project.kind != .supabase {
            let probe = try await Shell.run("/bin/zsh", arguments: ["-lc", "node --version"], timeout: 3,
                                            directory: project.folderURL, maximumOutputBytes: 8_192)
            if probe.status == 0, let text = probe.stdout.split(whereSeparator: \.isNewline).last { observed = try? NodeVersion(String(text)) }
        }
        var prepared = Self(node: node, package: package, observedNode: observed, allowsPackageDownload: allowDownload)
        if package == nil, project.packageManager == .yarn, project.kind != .supabase {
            let probe = try await Shell.run("/bin/zsh", arguments: ["-lc", prepared.command("yarn --version")],
                                            timeout: allowDownload ? 90 : 5, directory: project.folderURL, maximumOutputBytes: 8_192)
            if probe.status == 0, let text = probe.stdout.split(whereSeparator: \.isNewline).last,
               let version = try? NodeVersion(String(text)) { prepared.observedPackageVersion = version.description }
        }
        return prepared
    }
}

struct ProjectPackageRuntimeResolver {
    var shimRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Local Monitor/PackageManagers", isDirectory: true)
    var candidateDirectories: [URL]? = nil
    var allowCorepack = true

    func resolve(_ project: LocalProject, node: ProjectNodeRuntime?, allowDownload: Bool = false) async throws -> ProjectPackageRuntime? {
        guard let requirement = try ProjectPackageRequirement.read(in: project.folderURL) else { return nil }
        guard requirement.manager == project.packageManager else {
            throw ProjectReliabilityError.message("Project requires \(requirement.manager.rawValue), but the saved launcher uses \(project.packageManager.rawValue). Update the launch command and package manager in settings.")
        }
        let range = try requirement.range
        func execute(_ command: String) async throws -> ShellResult {
            let protected = "\(corepackEnvironment(network: allowDownload)) /bin/zsh -c \(ProjectNodeRuntime.quote(command))"
            return try await Shell.run("/bin/zsh", arguments: ["-lc", node?.command(protected) ?? protected],
                                timeout: allowDownload ? 90 : 5, directory: project.folderURL, maximumOutputBytes: 16_384)
        }
        let managerName = requirement.manager.rawValue
        var candidates = (candidateDirectories ?? ProjectNodeRuntimeResolver().installedDirectories()).map { $0.appendingPathComponent(managerName) }
        if candidateDirectories == nil {
            let lookup = try await execute("command -v \(managerName)")
            if let path = lookup.stdout.split(whereSeparator: \.isNewline).last, path.hasPrefix("/") {
                candidates.insert(URL(fileURLWithPath: String(path)), at: 0)
            }
        }
        var visited = Set<String>()
        let deadline = Date().addingTimeInterval(20)
        for candidate in candidates.prefix(256) {
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            let path = candidate.resolvingSymlinksInPath().path
            guard FileManager.default.isExecutableFile(atPath: path), visited.insert(path).inserted else { continue }
            let probe = try await execute("\(ProjectNodeRuntime.quote(path)) --version")
            if let value = probe.stdout.split(whereSeparator: \.isNewline).last,
               let version = try? NodeVersion(String(value).trimmingCharacters(in: .whitespaces)), range.contains(version), probe.status == 0 {
                return try makeShim(requirement, version: version.description, executable: path, arguments: [], network: false)
            }
        }
        // Corepack can resolve exact pins from its cache. Normal Start never downloads or changes global pins.
        if allowCorepack, requirement.manager != .bun {
            let corepack = try await execute("command -v corepack")
            if let path = corepack.stdout.split(whereSeparator: \.isNewline).last, path.hasPrefix("/") {
                let selector = "\(managerName)@\(requirement.version)"
                let args = [selector, "--version"].map(ProjectNodeRuntime.quote).joined(separator: " ")
                let settings = corepackEnvironment(network: allowDownload)
                let probe = try await execute("\(settings) \(ProjectNodeRuntime.quote(String(path))) \(args)")
                if let value = probe.stdout.split(whereSeparator: \.isNewline).last,
                   let version = try? NodeVersion(String(value)), range.contains(version), probe.status == 0 {
                    return try makeShim(requirement, version: version.description, executable: String(path),
                                        arguments: [selector], network: allowDownload)
                }
            }
        }
        throw ProjectReliabilityError.message("\(managerName) \(requirement.version) required by package.json is unavailable. Install that version, or use Install Dependencies to download it through an installed Corepack.")
    }

    private func corepackEnvironment(network: Bool) -> String {
        "/usr/bin/env COREPACK_ENABLE_NETWORK=\(network ? 1 : 0) COREPACK_ENABLE_AUTO_PIN=0 COREPACK_DEFAULT_TO_LATEST=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0"
    }

    private func makeShim(_ requirement: ProjectPackageRequirement, version: String, executable: String,
                          arguments: [String], network: Bool) throws -> ProjectPackageRuntime {
        let signature = ([executable, requirement.manager.rawValue, version, String(network)] + arguments).joined(separator: "\n")
        let key = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = shimRoot.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let command = ([executable] + arguments).map(ProjectNodeRuntime.quote).joined(separator: " ")
        let prefix = corepackEnvironment(network: network) + " "
        let script = "#!/bin/sh\nexec \(prefix)\(command) \"$@\"\n"
        let file = directory.appendingPathComponent(requirement.manager.rawValue)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return ProjectPackageRuntime(manager: requirement.manager, version: version, shimDirectory: directory)
    }
}
