import Foundation

/// Downloads only after an explicit installation request. Normal launch discovery stays offline.
struct ProjectNodeInstaller {
    var loadReleaseIndex: () async throws -> Data = {
        let url = URL(string: "https://nodejs.org/dist/index.json")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 2_097_152 else {
            throw ProjectReliabilityError.message("Could not fetch available Node.js releases. Check your connection and try again.")
        }
        return data
    }
    var execute: (String, URL) async throws -> ShellResult = { command, folder in
        try await Shell.run("/bin/zsh", arguments: ["-lc", command], timeout: 300,
                            directory: folder, maximumOutputBytes: 32_768)
    }

    func install(_ requirement: ProjectNodeRequirement, in folder: URL,
                 resolver: ProjectNodeRuntimeResolver) async throws -> ProjectNodeRuntime {
        try checkRequirement(requirement, in: folder)
        // Another project or a terminal may already have installed it since the error was shown.
        do {
            if let runtime = try await resolver.resolve(in: folder) {
                try Task.checkCancellation()
                try checkRequirement(requirement, in: folder)
                return runtime
            }
        } catch NodeRuntimeError.unavailable { /* Continue with the explicitly requested installation. */ }
        try Task.checkCancellation()

        let version: NodeVersion
        if let exact = try? NodeVersion(requirement.selector) {
            version = exact
        } else {
            // Validate before fetching, so malformed declarations never trigger network activity.
            _ = try releaseFilter(for: requirement)
            version = try selectVersion(for: requirement, index: await loadReleaseIndex())
        }
        try Task.checkCancellation()
        try checkRequirement(requirement, in: folder)
        let result = try await execute(Self.command(for: version), folder)
        try Task.checkCancellation()
        guard result.status == 0 else {
            let detail = [result.stderr, result.stdout].filter { !$0.isEmpty }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProjectReliabilityError.message("Node.js \(version) installation failed. " +
                (detail.isEmpty ? "Try again or check your Node version manager." : String(detail.suffix(2_000))))
        }
        try checkRequirement(requirement, in: folder)
        guard let runtime = try await resolver.resolve(in: folder) else {
            throw ProjectReliabilityError.message("Node.js installation could not be verified. Check Requirements before retrying.")
        }
        try Task.checkCancellation()
        return runtime
    }

    func selectVersion(for requirement: ProjectNodeRequirement, index: Data) throws -> NodeVersion {
        let filter = try releaseFilter(for: requirement)
        guard let releases = try JSONSerialization.jsonObject(with: index) as? [[String: Any]] else {
            throw ProjectReliabilityError.message("The Node.js release list could not be read. Try again.")
        }
        let versions = releases.compactMap { release -> NodeVersion? in
            guard let value = release["version"] as? String, let version = try? NodeVersion(value),
                  filter(version, release["lts"] as? String) else { return nil }
            return version
        }
        guard let version = versions.max() else {
            throw ProjectReliabilityError.message("No published stable Node.js release matches \(requirement.selector). Review \(requirement.source.lastPathComponent).")
        }
        return version
    }

    private func releaseFilter(for requirement: ProjectNodeRequirement) throws -> (NodeVersion, String?) -> Bool {
        if let range = try? NodeVersionRange(requirement.selector) {
            return { version, _ in range.contains(version) }
        }
        let alias = requirement.selector.lowercased()
        guard requirement.allowsAliases else { throw NodeRuntimeError.unsupported(requirement.selector) }
        if ["node", "stable"].contains(alias) { return { _, _ in true } }
        if alias == "lts/*" { return { _, lts in lts != nil } }
        if alias.hasPrefix("lts/"), alias.range(of: #"^lts/[a-z]+$"#, options: .regularExpression) != nil {
            let name = String(alias.dropFirst(4))
            return { _, lts in lts?.lowercased() == name }
        }
        throw ProjectReliabilityError.message("Install the Node.js alias '\(requirement.selector)' with your version manager, or use a numeric version in \(requirement.source.lastPathComponent).")
    }

    private func checkRequirement(_ requirement: ProjectNodeRequirement, in folder: URL) throws {
        guard try ProjectNodeRequirement.read(in: folder) == requirement else {
            throw ProjectReliabilityError.message("The project's Node.js requirement changed. Check Requirements before installing again.")
        }
    }

    static func command(for version: NodeVersion) -> String {
        let version = ProjectNodeRuntime.quote(version.description)
        return """
        if command -v fnm >/dev/null 2>&1; then
          fnm install \(version) --progress never
          exit $?
        fi
        if ! command -v nvm >/dev/null 2>&1; then
          for lm_nvm_script in "${NVM_DIR:-$HOME/.nvm}/nvm.sh" "${XDG_CONFIG_HOME:-$HOME/.config}/nvm/nvm.sh" /opt/homebrew/opt/nvm/nvm.sh /usr/local/opt/nvm/nvm.sh; do
            if [ -r "$lm_nvm_script" ]; then . "$lm_nvm_script" --no-use; break; fi
          done
        fi
        if command -v nvm >/dev/null 2>&1; then
          nvm install \(version)
          exit $?
        fi
        for lm_fnm in /opt/homebrew/bin/fnm /usr/local/bin/fnm "${FNM_DIR:-$HOME/.local/share/fnm}/fnm"; do
          if [ -x "$lm_fnm" ]; then "$lm_fnm" install \(version) --progress never; exit $?; fi
        done
        printf '%s\\n' 'No supported Node version manager found. Install fnm or nvm once, then retry Install Node.js.' >&2
        exit 127
        """
    }
}
