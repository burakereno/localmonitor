import Foundation

enum NodeRuntimeError: LocalizedError {
    case unsupported(String)
    case invalidFile(String)
    case unavailable(ProjectNodeRequirement)

    var errorDescription: String? {
        switch self {
        case .unsupported(let value):
            return "Unsupported Node.js version declaration: \(value). Use a stable numeric version or semver range."
        case .invalidFile(let path):
            return "Cannot read a Node.js version from \(path)."
        case .unavailable(let requirement):
            return "Node.js \(requirement.selector) required by \(requirement.source.path) is not installed. Install a matching version with your Node version manager, then start again."
        }
    }
}

struct ProjectNodeRequirement: Equatable {
    let selector: String
    let source: URL
    let allowsAliases: Bool

    static func read(in folder: URL) throws -> Self? {
        var engineRequirement: Self?
        for directory in ProjectMetadata.ancestors(of: folder) {
            for filename in [".nvmrc", ".node-version"] {
                let file = directory.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: file.path) {
                    guard let data = try ProjectMetadata.data(at: file, limit: 8_192),
                          let text = String(data: data, encoding: .utf8) else {
                        throw NodeRuntimeError.invalidFile(file.path)
                    }
                    let values = text.components(separatedBy: .newlines).compactMap { line -> String? in
                        let value = line.components(separatedBy: "#")[0]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return value.isEmpty ? nil : value
                    }
                    guard values.count == 1 else { throw NodeRuntimeError.invalidFile(file.path) }
                    return Self(selector: values[0], source: file, allowsAliases: true)
                }
            }
            let packageURL = directory.appendingPathComponent("package.json")
            if let package = try ProjectMetadata.package(at: directory) {
                if let version = (package["volta"] as? [String: Any])?["node"] as? String {
                    return Self(selector: version, source: packageURL, allowsAliases: false)
                }
                if engineRequirement == nil,
                   let version = (package["engines"] as? [String: Any])?["node"] as? String {
                    engineRequirement = Self(selector: version, source: packageURL, allowsAliases: false)
                }
            }
        }
        return engineRequirement
    }
}

struct ProjectNodeRuntime: Equatable {
    let executable: URL
    let version: NodeVersion
    let requirement: ProjectNodeRequirement

    /// Login-shell startup may reset PATH; apply the project selection afterwards.
    func command(_ command: String) -> String {
        let message = "[Local Monitor] Node.js \(version) (\(executable.path)); requested \(requirement.selector) by \(requirement.source.path)"
        return """
        export PATH=\(Self.quote(executable.deletingLastPathComponent().path)):"$PATH"
        rehash
        printf '%s\\n' \(Self.quote(message))
        \(command)
        """
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ProjectNodeRuntimeResolver {
    /// Supplying directories disables machine discovery, keeping integration tests isolated.
    var candidateDirectories: [URL]?

    func resolve(in folder: URL) async throws -> ProjectNodeRuntime? {
        guard let requirement = try ProjectNodeRequirement.read(in: folder) else { return nil }
        let range: NodeVersionRange
        do {
            range = try NodeVersionRange(requirement.selector)
        } catch {
            guard requirement.allowsAliases,
                  requirement.selector.range(of: #"^[A-Za-z][A-Za-z0-9_/*.-]*$"#, options: .regularExpression) != nil else {
                throw error
            }
            if candidateDirectories == nil, let executable = await aliasExecutable(requirement.selector),
               let runtime = await runtime(of: executable, requirement: requirement) {
                return runtime
            }
            throw NodeRuntimeError.unavailable(requirement)
        }

        var directories = candidateDirectories ?? installedDirectories()
        if candidateDirectories == nil,
           let current = try? await Shell.run("/bin/zsh", arguments: ["-lc", "command -v node"], timeout: 3),
           current.status == 0,
           let path = current.stdout.split(whereSeparator: \.isNewline).last, path.hasPrefix("/") {
            directories.insert(URL(fileURLWithPath: String(path)).deletingLastPathComponent(), at: 0)
        }

        var visited = Set<String>()
        var matches: [ProjectNodeRuntime] = []
        let deadline = Date().addingTimeInterval(20)
        for directory in directories.prefix(256) {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ProjectReliabilityError.message("Node runtime discovery timed out. Check the installed runtime paths and try again.") }
            // Retain the bin directory of the actual installation, not an fnm multishell/shim.
            let executable = directory.appendingPathComponent("node").resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  visited.insert(executable.path).inserted,
                  let runtime = await runtime(of: executable, requirement: requirement),
                  range.contains(runtime.version) else { continue }
            matches.append(runtime)
        }
        guard let selected = matches.max(by: { $0.version < $1.version }) else {
            throw NodeRuntimeError.unavailable(requirement)
        }
        return selected
    }

    private func runtime(of executable: URL, requirement: ProjectNodeRequirement) async -> ProjectNodeRuntime? {
        // Resolve manager shims to the actual runtime; their chosen version can otherwise
        // change when launched from a different project folder.
        let expression = "JSON.stringify({version:process.versions.node,executable:process.execPath})"
        guard let result = try? await Shell.run(executable.path, arguments: ["-p", expression], timeout: 2),
              result.status == 0, let data = result.stdout.data(using: .utf8),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let value = info["version"], let version = try? NodeVersion(value),
              let path = info["executable"], path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return ProjectNodeRuntime(executable: URL(fileURLWithPath: path).resolvingSymlinksInPath(),
                                  version: version, requirement: requirement)
    }

    func installedDirectories() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        func location(_ key: String, _ fallback: String) -> URL {
            environment[key].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(fallback)
        }
        func children(_ folder: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        var directories = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let fnm = environment["FNM_DIR"].map { URL(fileURLWithPath: $0) }
            ?? environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("fnm") }
            ?? home.appendingPathComponent(".local/share/fnm")
        directories += children(fnm.appendingPathComponent("node-versions")).map { $0.appendingPathComponent("installation/bin") }
        for root in [location("NVM_DIR", ".nvm").appendingPathComponent("versions/node"),
                     location("VOLTA_HOME", ".volta").appendingPathComponent("tools/image/node"),
                     location("MISE_DATA_DIR", ".local/share/mise").appendingPathComponent("installs/node"),
                     location("ASDF_DATA_DIR", ".asdf").appendingPathComponent("installs/nodejs")] {
            directories += children(root).map { $0.appendingPathComponent("bin") }
        }
        // fnm's macOS default can also be the platform application-support directory.
        directories += children(home.appendingPathComponent("Library/Application Support/fnm/node-versions"))
            .map { $0.appendingPathComponent("installation/bin") }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            directories.append(URL(fileURLWithPath: prefix + "/bin"))
            directories += children(URL(fileURLWithPath: prefix + "/opt"))
                .filter { $0.lastPathComponent == "node" || $0.lastPathComponent.hasPrefix("node@") }
                .map { $0.appendingPathComponent("bin") }
        }
        return directories
    }

    private func aliasExecutable(_ selector: String) async -> URL? {
        let quoted = ProjectNodeRuntime.quote(selector)
        // Explicit selectors avoid depending on the shell's default version; neither command installs anything.
        let command = """
        if command -v fnm >/dev/null 2>&1; then
          fnm exec --using \(quoted) node -p 'process.execPath' 2>/dev/null && exit 0
        fi
        if ! command -v nvm >/dev/null 2>&1; then
          for lm_nvm_script in "${NVM_DIR:-$HOME/.nvm}/nvm.sh" /opt/homebrew/opt/nvm/nvm.sh /usr/local/opt/nvm/nvm.sh; do
            if [ -r "$lm_nvm_script" ]; then . "$lm_nvm_script" --no-use; break; fi
          done
        fi
        if command -v nvm >/dev/null 2>&1; then nvm which \(quoted); else exit 1; fi
        """
        guard let result = try? await Shell.run("/bin/zsh", arguments: ["-lc", command], timeout: 4),
              result.status == 0,
              let path = result.stdout.split(whereSeparator: \.isNewline).last, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: String(path)).resolvingSymlinksInPath()
    }
}
