import Foundation

struct ProjectEnvironmentChecker {
    func mode(for project: LocalProject) -> String {
        let command = project.resolvedCommand
        if let match = command.range(of: #"--mode(?:=|\s+)[A-Za-z0-9_-]+"#, options: .regularExpression) {
            return String(command[match]).replacingOccurrences(of: #"^--mode(?:=|\s+)"#, with: "", options: .regularExpression)
        }
        if isWrangler(project), let environment = wranglerEnvironment(for: project) { return environment }
        let configured = project.reliability.validated.environmentMode
        if configured != "auto" { return configured }
        if let match = command.range(of: #"NODE_ENV=['\"]?(production|development|test)"#, options: .regularExpression) {
            return String(command[match]).replacingOccurrences(of: #"^NODE_ENV=['\"]?"#, with: "", options: .regularExpression)
        }
        if command.range(of: #"(?:^|\s)(?:next\s+(?:start|build)|(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:start|build))(?:\s|$)"#, options: .regularExpression) != nil {
            return "production"
        }
        return "development"
    }

    func files(for project: LocalProject) -> [String] {
        let mode = mode(for: project)
        if project.kind == .nextjs {
            return [".env", ".env.\(mode)"] + (mode == "test" ? [] : [".env.local"]) + [".env.\(mode).local"]
        }
        if isWrangler(project) {
            let environment = wranglerEnvironment(for: project)
            if let environment, FileManager.default.fileExists(atPath: project.folderURL.appendingPathComponent(".dev.vars.\(environment)").path) {
                return [".dev.vars.\(environment)"]
            }
            if FileManager.default.fileExists(atPath: project.folderURL.appendingPathComponent(".dev.vars").path) { return [".dev.vars"] }
            return [".env"] + (environment.map { [".env.\($0)"] } ?? []) + [".env.local"]
                + (environment.map { [".env.\($0).local"] } ?? [])
        }
        return [".env", ".env.local", ".env.\(mode)", ".env.\(mode).local"]
    }

    /// Retains presence only. Values never enter diagnostics or persisted state.
    func presence(in text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for raw in text.components(separatedBy: .newlines).prefix(4_096) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard ProjectReliabilitySettings.validEnvironmentKey(key) else { continue }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") || value.hasPrefix("'") {
                let quote = value.first!
                value.removeFirst()
                value = String(value.prefix { $0 != quote })
            } else { value = value.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces) }
            result[key] = !value.isEmpty
        }
        return result
    }

    func issues(for project: LocalProject, shellPresence: [String: Bool] = [:]) throws -> [PreflightIssue] {
        var available: [String: Bool] = [:]
        for name in files(for: project) {
            if let data = try ProjectMetadata.data(at: project.folderURL.appendingPathComponent(name), limit: 262_144) {
                available.merge(presence(in: String(decoding: data, as: UTF8.self))) { _, new in new }
            }
        }
        available.merge(shellPresence) { _, new in new }
        let assignments = commandAssignments(project.resolvedCommand)
        available.merge(assignments.known) { _, new in new }
        let explicit = Set(project.reliability.validated.requiredEnvironmentKeys)
        var example = Set<String>()
        for name in [".env.example", ".env.sample"] {
            if let data = try ProjectMetadata.data(at: project.folderURL.appendingPathComponent(name), limit: 262_144) {
                example.formUnion(presence(in: String(decoding: data, as: UTF8.self)).keys)
            }
        }
        var issues: [PreflightIssue] = []
        let missing = explicit.filter { available[$0] != true && !assignments.computed.contains($0) }.sorted()
        if !missing.isEmpty {
            issues.append(PreflightIssue(severity: .error, message: "Required environment keys missing or empty: \(missing.joined(separator: ", ")). Set them for \(mode(for: project)) mode."))
        }
        let computed = explicit.intersection(assignments.computed).sorted()
        if !computed.isEmpty {
            issues.append(PreflightIssue(severity: .warning, message: "Environment keys computed by the launch command cannot be verified without executing it: \(computed.joined(separator: ", "))."))
        }
        let inferred = example.subtracting(explicit).filter { available[$0] != true }.sorted()
        if !inferred.isEmpty {
            issues.append(PreflightIssue(severity: .warning, message: "Environment template keys missing or empty: \(inferred.joined(separator: ", ")). Review whether they are required."))
        }
        return issues
    }

    /// Inspects only leading assignments; command substitutions and expansions are never executed.
    func commandAssignments(_ command: String) -> (known: [String: Bool], computed: Set<String>) {
        var remaining = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let exported = remaining.hasPrefix("export ")
        if exported { remaining = String(remaining.dropFirst(7)) }
        else if remaining.hasPrefix("env ") { remaining = String(remaining.dropFirst(4)) }
        var known: [String: Bool] = [:], computed = Set<String>()
        for _ in 0..<256 {
            guard let word = assignmentWord(in: remaining), let separator = word.text.firstIndex(of: "=") else { break }
            let key = String(word.text[..<separator])
            guard ProjectReliabilitySettings.validEnvironmentKey(key) else { break }
            if word.computed {
                computed.insert(key); known.removeValue(forKey: key)
            } else { known[key] = word.text.index(after: separator) != word.text.endIndex; computed.remove(key) }
            remaining = String(remaining[word.end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A shell-local assignment followed by a separate command is not exported to that command.
        if !exported, remaining.hasPrefix(";") || remaining.hasPrefix("&") || remaining.hasPrefix("|") { return ([:], []) }
        return (known, computed)
    }

    private func assignmentWord(in text: String) -> (text: String, computed: Bool, end: String.Index)? {
        var index = text.startIndex, value = "", contexts: [Character] = []
        var escaped = false, computed = false
        while index < text.endIndex {
            let character = text[index], next = text.index(after: index)
            let context = contexts.last
            if escaped { value.append(character); escaped = false }
            else if context == "'" {
                if character == "'" { contexts.removeLast() } else { value.append(character) }
            } else if character == "\\" { escaped = true }
            else if context == "`" {
                if character == "`" { contexts.removeLast() } else { value.append(character) }
            } else if character == "`" { computed = true; contexts.append("`") }
            else if character == "$", next < text.endIndex, text[next] == "(" {
                computed = true; contexts.append("("); value += "$("; index = text.index(after: next); continue
            } else if context == "\"" {
                if character == "\"" { contexts.removeLast() }
                else { if character == "$" { computed = true }; value.append(character) }
            } else if character == "'" || character == "\"" { contexts.append(character) }
            else if context == "(" {
                if character == "(" { contexts.append("(") }
                else if character == ")" { contexts.removeLast() }
                value.append(character)
            } else if character.isWhitespace || ";&|<>".contains(character) { break }
            else { if character == "$" { computed = true }; value.append(character) }
            index = next
        }
        guard index > text.startIndex, contexts.isEmpty, !escaped else { return nil }
        return (value, computed, index)
    }

    private func isWrangler(_ project: LocalProject) -> Bool {
        guard project.kind == .hono else { return false }
        return project.resolvedCommand.contains("wrangler") || ["wrangler.toml", "wrangler.json", "wrangler.jsonc"].contains {
            FileManager.default.fileExists(atPath: project.folderURL.appendingPathComponent($0).path)
        }
    }

    private func wranglerEnvironment(for project: LocalProject) -> String? {
        let command = project.resolvedCommand
        if let match = command.range(of: #"(?:--env(?:=|\s+)|-e\s+|CLOUDFLARE_ENV=['"]?)[A-Za-z0-9_-]+"#, options: .regularExpression) {
            return String(command[match]).replacingOccurrences(of: #"^(?:--env(?:=|\s+)|-e\s+|CLOUDFLARE_ENV=['"]?)"#, with: "", options: .regularExpression)
        }
        let configured = project.reliability.validated.environmentMode
        return configured == "auto" ? nil : configured
    }

    func shellPresence(for project: LocalProject) async throws -> [String: Bool] {
        var keys = Set(project.reliability.validated.requiredEnvironmentKeys)
        for name in [".env.example", ".env.sample"] {
            if let data = try ProjectMetadata.data(at: project.folderURL.appendingPathComponent(name), limit: 262_144) {
                keys.formUnion(presence(in: String(decoding: data, as: UTF8.self)).keys)
            }
        }
        guard !keys.isEmpty else { return [:] }
        let arguments = keys.sorted().prefix(256).map(ProjectNodeRuntime.quote).joined(separator: " ")
        let command = """
        for lm_env_key in \(arguments); do
          if [[ "${(tP)lm_env_key}" == *export* ]]; then
            if [[ -n "${(P)lm_env_key}" ]]; then printf 'LM_ENV:%s:1\\n' "$lm_env_key"; else printf 'LM_ENV:%s:0\\n' "$lm_env_key"; fi
          fi
        done
        """
        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = String(project.port)
        environment["LOCALMONITOR"] = "1"
        let result = try await Shell.run("/bin/zsh", arguments: ["-lc", command], timeout: 4, directory: project.folderURL, environment: environment)
        guard result.status == 0 else { throw ProjectReliabilityError.message("The login shell environment could not be checked.") }
        var values: [String: Bool] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("LM_ENV:") {
            let parts = line.split(separator: ":")
            if parts.count == 3 { values[String(parts[1])] = parts[2] == "1" }
        }
        return values
    }
}
