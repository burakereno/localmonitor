import Foundation

enum PortScannerError: LocalizedError {
    case lsofFailed(String)

    var errorDescription: String? {
        switch self {
        case .lsofFailed(let message):
            return "Could not read listening ports: \(message)"
        }
    }
}

struct PortScanner {
    func scan() async throws -> [DiscoveredPort] {
        let result = try await Shell.run(
            "/bin/zsh",
            arguments: ["-lc", "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null"]
        )

        if result.status != 0, result.stdout.isEmpty {
            throw PortScannerError.lsofFailed(result.stderr.nilIfBlank ?? "lsof exited with \(result.status)")
        }

        let ports = Self.parseLsofOutput(result.stdout)
        return await enrich(ports)
    }

    static func parseLsofOutput(_ output: String) -> [DiscoveredPort] {
        let parsed = output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap(parseLine)

        return deduplicate(parsed)
            .sorted { lhs, rhs in
                if lhs.port == rhs.port {
                    return lhs.pid < rhs.pid
                }
                return lhs.port < rhs.port
            }
    }

    private func enrich(_ ports: [DiscoveredPort]) async -> [DiscoveredPort] {
        let pids = Array(Set(ports.map(\.pid)))
        var metadataByPID: [Int32: ProcessPortMetadata] = [:]

        for pid in pids {
            metadataByPID[pid] = await metadata(for: pid)
        }

        return ports.map { port in
            guard let metadata = metadataByPID[port.pid] else { return port }

            var copy = port
            copy.workingDirectory = metadata.workingDirectory
            copy.commandLine = metadata.commandLine
            copy.startedAt = metadata.startedAt
            copy.inferredProjectName = Self.inferProjectName(
                workingDirectory: metadata.workingDirectory,
                command: port.command
            )
            return copy
        }
    }

    private func metadata(for pid: Int32) async -> ProcessPortMetadata {
        async let cwd = workingDirectory(for: pid)
        async let commandLine = commandLine(for: pid)
        async let startedAt = startedAt(for: pid)
        return await ProcessPortMetadata(
            workingDirectory: cwd,
            commandLine: commandLine,
            startedAt: startedAt
        )
    }

    private func workingDirectory(for pid: Int32) async -> String? {
        guard
            let result = try? await Shell.run(
                "/usr/sbin/lsof",
                arguments: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
            ),
            result.status == 0
        else {
            return nil
        }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let text = String(line)
                guard text.hasPrefix("n") else { return nil }
                return String(text.dropFirst()).nilIfBlank
            }
            .first
    }

    private func commandLine(for pid: Int32) async -> String? {
        guard
            let result = try? await Shell.run(
                "/bin/ps",
                arguments: ["-p", "\(pid)", "-o", "command="]
            ),
            result.status == 0
        else {
            return nil
        }

        return Self.shortCommandLine(result.stdout.nilIfBlank)
    }

    private func startedAt(for pid: Int32) async -> Date? {
        guard
            let result = try? await Shell.run(
                "/bin/ps",
                arguments: ["-p", "\(pid)", "-o", "lstart="]
            ),
            result.status == 0,
            let startDate = Self.parseProcessStartDate(result.stdout)
        else {
            return nil
        }

        return startDate
    }

    static func parseProcessStartDate(_ output: String) -> Date? {
        let normalized = output
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.isLenient = true
        return formatter.date(from: normalized)
    }

    static func inferProjectName(workingDirectory: String?, command: String) -> String? {
        guard let workingDirectory, isProjectLikeCommand(command) else { return nil }
        let url = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        return projectNameFromPath(startingAt: url)
    }

    private static func parseLine(_ line: Substring) -> DiscoveredPort? {
        let raw = String(line)
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, let pid = Int32(parts[1]) else { return nil }

        guard
            let portRange = raw.range(of: #":(\d+)\s+\(LISTEN\)"#, options: .regularExpression),
            let port = Int(raw[portRange].replacingOccurrences(
                of: #"^\:(\d+)\s+\(LISTEN\)$"#,
                with: "$1",
                options: .regularExpression
            ))
        else {
            return nil
        }

        let endpoint: String
        if let tcpRange = raw.range(of: "TCP ") {
            endpoint = String(raw[tcpRange.upperBound...])
                .replacingOccurrences(of: " (LISTEN)", with: "")
        } else {
            endpoint = "*:\(port)"
        }

        return DiscoveredPort(
            port: port,
            pid: pid,
            command: String(parts[0]),
            user: String(parts[2]),
            endpoint: endpoint,
            workingDirectory: nil,
            inferredProjectName: nil,
            commandLine: nil,
            startedAt: nil,
            pinnedName: nil,
            isIgnored: false,
            isManaged: false,
            projectId: nil,
            projectName: nil
        )
    }

    private static func deduplicate(_ ports: [DiscoveredPort]) -> [DiscoveredPort] {
        var seen = Set<String>()
        var unique: [DiscoveredPort] = []

        for port in ports {
            let key = "\(port.pid)-\(port.port)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(port)
        }

        return unique
    }

    private static func projectNameFromPath(startingAt url: URL) -> String? {
        var cursor = url
        var fallback: String?

        for _ in 0..<6 {
            let name = cursor.lastPathComponent
            let normalized = name.lowercased()

            if !name.isEmpty, name != "/" {
                if !genericFolderNames.contains(normalized) {
                    return name
                }
                fallback = fallback ?? name
            }

            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { break }
            cursor = parent
        }

        return fallback
    }

    private static func isProjectLikeCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return projectCommandTokens.contains { normalized.contains($0) }
    }

    private static func shortCommandLine(_ commandLine: String?) -> String? {
        guard let commandLine else { return nil }
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.count <= 42 {
            return trimmed
        }

        if let first = trimmed.split(separator: " ", omittingEmptySubsequences: true).first {
            return String(first)
        }

        return String(trimmed.prefix(42))
    }

    private static let genericFolderNames: Set<String> = [
        ".bin",
        ".next",
        "app",
        "apps",
        "build",
        "client",
        "dist",
        "frontend",
        "node_modules",
        "public",
        "site",
        "src",
        "web",
        "www"
    ]

    private static let projectCommandTokens: Set<String> = [
        "astro",
        "bun",
        "deno",
        "django",
        "flask",
        "gunicorn",
        "next",
        "node",
        "npm",
        "nuxt",
        "pnpm",
        "python",
        "remix",
        "svelte",
        "tsx",
        "uvicorn",
        "vite",
        "yarn"
    ]
}

private struct ProcessPortMetadata {
    let workingDirectory: String?
    let commandLine: String?
    let startedAt: Date?
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
