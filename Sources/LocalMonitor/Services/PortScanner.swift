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

protocol PortScanning {
    func scan(pids: Set<Int32>?, requireComplete: Bool) async throws -> [DiscoveredPort]
}

extension PortScanning {
    func scan() async throws -> [DiscoveredPort] { try await scan(pids: nil, requireComplete: false) }
}

struct PortScanner: PortScanning {
    func scan(pids: Set<Int32>? = nil, requireComplete: Bool = false) async throws -> [DiscoveredPort] {
        var arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
        if let pids {
            guard !pids.isEmpty else { return [] }
            arguments += ["-a", "-p", pids.map(String.init).joined(separator: ",")]
        }
        let scanStarted = Date()
        let result = try await Shell.run(
            "/usr/sbin/lsof",
            arguments: arguments, maximumOutputBytes: 2_097_152
        )

        return try await enrich(Self.ports(from: result, requireComplete: requireComplete), scanStarted: scanStarted, requireComplete: requireComplete)
    }

    static func ports(from result: ShellResult, requireComplete: Bool = false) throws -> [DiscoveredPort] {
        // lsof also exits with 1 when its filters match no open sockets.
        if result.status == 1, result.stdout.nilIfBlank == nil, result.stderr.nilIfBlank == nil {
            return []
        }
        if requireComplete, result.stdout.hasSuffix("\n[Output truncated]") {
            throw PortScannerError.lsofFailed("The list of listening ports was truncated.")
        }
        if result.status != 0 && (result.status != 1 || requireComplete || result.stdout.nilIfBlank == nil) {
            throw PortScannerError.lsofFailed(result.stderr.nilIfBlank ?? "lsof exited with \(result.status)")
        }

        return parseLsofOutput(result.stdout)
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

    private func enrich(_ ports: [DiscoveredPort], scanStarted: Date, requireComplete: Bool) async throws -> [DiscoveredPort] {
        guard !ports.isEmpty else { return [] }
        let listenerPIDs = Set(ports.map(\.pid))
        let startDates = Dictionary(uniqueKeysWithValues: listenerPIDs.compactMap { pid in
            ProcessTree.startDate(of: pid).map { (pid, $0) }
        })
        let pids = listenerPIDs.map(String.init).joined(separator: ",")
        async let cwd = Shell.run("/usr/sbin/lsof", arguments: ["-nP", "-a", "-p", pids, "-d", "cwd", "-Fpn"],
                                  maximumOutputBytes: 2_097_152)
        async let commands = Shell.run("/bin/ps", arguments: ["-ww", "-p", pids, "-o", "pid=,command="],
                                       maximumOutputBytes: 2_097_152)
        var directories: [Int32: String] = [:]
        var pid: Int32?
        let cwdResult = try? await cwd
        if requireComplete {
            guard let cwdResult, cwdResult.status == 0 || (cwdResult.status == 1 && !cwdResult.stdout.isEmpty),
                  !cwdResult.stdout.hasSuffix("\n[Output truncated]") else {
                throw PortScannerError.lsofFailed("Could not read the working directories of listening processes.")
            }
        }
        for line in cwdResult?.stdout.split(whereSeparator: \.isNewline) ?? [] {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if line.first == "n", let pid { directories[pid] = String(line.dropFirst()) }
        }
        var commandLines: [Int32: String] = [:]
        for line in (try? await commands.stdout)?.split(whereSeparator: \.isNewline) ?? [] {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if fields.count == 2, let pid = Int32(fields[0]) {
                commandLines[pid] = Self.shortCommandLine(String(fields[1]))
            }
        }
        let stablePIDs = listenerPIDs.filter { pid in
            let birth = startDates[pid]
            return birth == ProcessTree.startDate(of: pid) && (birth.map { $0 <= scanStarted } ?? true)
        }
        return ports.compactMap { port in
            guard stablePIDs.contains(port.pid) else { return nil }
            var copy = port
            copy.workingDirectory = directories[port.pid]
            copy.commandLine = commandLines[port.pid]
            copy.startedAt = startDates[port.pid]
            copy.inferredProjectName = Self.inferProjectName(workingDirectory: copy.workingDirectory, command: port.command)
            return copy
        }
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
