import Foundation

enum ProjectKind: String, Codable, CaseIterable, Identifiable {
    case nextjs
    case hono
    case vite
    case astro
    case remix
    case sveltekit
    case nuxt
    case expo
    case supabase
    case prisma
    case storybook
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nextjs:
            return "Next.js"
        case .hono:
            return "Hono"
        case .vite:
            return "Vite"
        case .astro:
            return "Astro"
        case .remix:
            return "Remix"
        case .sveltekit:
            return "SvelteKit"
        case .nuxt:
            return "Nuxt"
        case .expo:
            return "Expo"
        case .supabase:
            return "Supabase"
        case .prisma:
            return "Prisma"
        case .storybook:
            return "Storybook"
        case .unknown:
            return "Unknown"
        }
    }

    var shortName: String {
        switch self {
        case .nextjs:
            return "Next"
        case .hono:
            return "Hono"
        case .vite:
            return "Vite"
        case .astro:
            return "Astro"
        case .remix:
            return "Remix"
        case .sveltekit:
            return "Svelte"
        case .nuxt:
            return "Nuxt"
        case .expo:
            return "Expo"
        case .supabase:
            return "Supa"
        case .prisma:
            return "Prisma"
        case .storybook:
            return "Story"
        case .unknown:
            return "Web"
        }
    }

    var symbolName: String {
        switch self {
        case .nextjs:
            return "n.square.fill"
        case .hono:
            return "flame.fill"
        case .vite:
            return "bolt.fill"
        case .astro:
            return "sparkles"
        case .remix:
            return "arrow.triangle.branch"
        case .sveltekit:
            return "s.circle.fill"
        case .nuxt:
            return "triangle.fill"
        case .expo:
            return "iphone"
        case .supabase:
            return "bolt.horizontal.fill"
        case .prisma:
            return "cylinder.split.1x2.fill"
        case .storybook:
            return "book.pages.fill"
        case .unknown:
            return "globe"
        }
    }

    var supportsCleanRestart: Bool {
        switch self {
        case .nextjs, .astro:
            return true
        case .hono, .vite, .remix, .sveltekit, .nuxt, .expo, .supabase, .prisma, .storybook, .unknown:
            return false
        }
    }

    var cleanCacheRelativePaths: [String] {
        switch self {
        case .nextjs:
            return [".next"]
        case .astro:
            return [".astro", "dist", "node_modules/.vite"]
        case .hono, .vite, .remix, .sveltekit, .nuxt, .expo, .supabase, .prisma, .storybook, .unknown:
            return []
        }
    }

    var cacheSizeLimitBytes: Int64 {
        switch self {
        case .nextjs:
            return 1_500_000_000
        case .astro:
            return 750_000_000
        case .hono, .vite, .remix, .sveltekit, .nuxt, .expo, .supabase, .prisma, .storybook, .unknown:
            return 1_000_000_000
        }
    }

    var uptimeLimit: TimeInterval {
        switch self {
        case .hono:
            return 7 * 86_400
        case .vite, .sveltekit, .nuxt:
            return 3 * 86_400
        case .nextjs, .astro, .remix, .expo, .supabase, .prisma, .storybook, .unknown:
            return 5 * 86_400
        }
    }
}

enum PackageManager: String, Codable, CaseIterable, Identifiable {
    case pnpm
    case bun
    case yarn
    case npm

    var id: String { rawValue }

    var displayName: String { rawValue }

    var devCommand: String {
        switch self {
        case .pnpm:
            return "pnpm dev"
        case .bun:
            return "bun run dev"
        case .yarn:
            return "yarn dev"
        case .npm:
            return "npm run dev"
        }
    }

    var startCommand: String {
        switch self {
        case .pnpm:
            return "pnpm start"
        case .bun:
            return "bun run start"
        case .yarn:
            return "yarn start"
        case .npm:
            return "npm run start"
        }
    }

    func scriptArguments(_ arguments: String) -> String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        switch self {
        case .npm:
            return " -- \(trimmed)"
        case .pnpm, .bun, .yarn:
            return " \(trimmed)"
        }
    }
}

struct LocalProject: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var profileName: String
    var path: String
    var kind: ProjectKind
    var packageManager: PackageManager
    var port: Int
    var commandTemplate: String
    var healthPath: String
    var autoStart: Bool
    var autoRestart: Bool
    var openAfterStart: Bool
    var workspaceGroupIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        profileName: String = "dev",
        path: String,
        kind: ProjectKind,
        packageManager: PackageManager,
        port: Int,
        commandTemplate: String,
        healthPath: String = "/",
        autoStart: Bool = false,
        autoRestart: Bool = false,
        openAfterStart: Bool = true,
        workspaceGroupIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.profileName = profileName
        self.path = path
        self.kind = kind
        self.packageManager = packageManager
        self.port = port
        self.commandTemplate = commandTemplate
        self.healthPath = healthPath
        self.autoStart = autoStart
        self.autoRestart = autoRestart
        self.openAfterStart = openAfterStart
        self.workspaceGroupIDs = workspaceGroupIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case profileName
        case path
        case kind
        case packageManager
        case port
        case commandTemplate
        case healthPath
        case autoStart
        case autoRestart
        case openAfterStart
        case workspaceGroupIDs
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName) ?? "dev"
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .unknown
        packageManager = try container.decodeIfPresent(PackageManager.self, forKey: .packageManager) ?? .npm
        port = try container.decode(Int.self, forKey: .port)
        commandTemplate = try container.decode(String.self, forKey: .commandTemplate)
        healthPath = try container.decodeIfPresent(String.self, forKey: .healthPath) ?? "/"
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        autoRestart = try container.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? false
        openAfterStart = try container.decodeIfPresent(Bool.self, forKey: .openAfterStart) ?? true
        workspaceGroupIDs = try container.decodeIfPresent([UUID].self, forKey: .workspaceGroupIDs) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    var folderURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var localURL: URL? {
        URL(string: "http://localhost:\(port)")
    }

    var healthURL: URL? {
        let cleanedPath = healthPath.hasPrefix("/") ? healthPath : "/\(healthPath)"
        return URL(string: "http://localhost:\(port)\(cleanedPath)")
    }

    var displayName: String {
        if profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profileName == "dev" {
            return name
        }
        return "\(name) · \(profileName)"
    }

    var resolvedCommand: String {
        let trimmed = commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "PORT=\(port) \(packageManager.devCommand)" }
        return trimmed.replacingOccurrences(of: "{port}", with: String(port))
    }

    var compactPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

enum ProjectRunStatus: Equatable {
    case stopped
    case starting
    case running
    case portBusy
    case portMismatch
    case noPort
    case crashed

    var displayName: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .portBusy:
            return "Port Busy"
        case .portMismatch:
            return "Port Mismatch"
        case .noPort:
            return "No Port"
        case .crashed:
            return "Crashed"
        }
    }
}

struct ProjectRuntimeState: Equatable {
    var status: ProjectRunStatus = .stopped
    var pid: Int32?
    var startedAt: Date?
    var lastMessage: String?
    var observedPort: Int?
    var logs: [String] = []

    static let stopped = ProjectRuntimeState()
}

enum CleanRestartPhase: Equatable {
    case stopping
    case cleaning
    case starting
    case checking
    case done
    case failed
}

enum ProjectOperationKind: Equatable {
    case cacheClean
    case restart
}

struct CleanRestartState: Equatable {
    var operation: ProjectOperationKind = .cacheClean
    var phase: CleanRestartPhase
    var message: String
    var progress: Double
    var keepsOnlineGroup: Bool = false

    var isActive: Bool {
        phase != .done && phase != .failed
    }
}

struct ProjectCacheState: Equatable {
    var bytes: Int64
    var limitBytes: Int64
    var updatedAt: Date

    var fillRatio: Double {
        guard limitBytes > 0 else { return 0 }
        return min(max(Double(bytes) / Double(limitBytes), 0), 1)
    }
}

struct WorkspaceGroup: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var projectIDs: [UUID]
    var autoStart: Bool

    init(id: UUID = UUID(), name: String, projectIDs: [UUID] = [], autoStart: Bool = false) {
        self.id = id
        self.name = name
        self.projectIDs = projectIDs
        self.autoStart = autoStart
    }
}

struct ProjectIdentity: Equatable {
    var branch: String?
    var packageName: String?
    var framework: ProjectKind
    var hasNodeModules: Bool
    var hasEnvFile: Bool
}

enum HealthState: Equatable {
    case unknown
    case checking
    case healthy(code: Int, milliseconds: Int)
    case warning(code: Int, milliseconds: Int)
    case unreachable(String)

    var displayName: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .checking:
            return "Checking"
        case .healthy(let code, let milliseconds):
            return "\(code) · \(milliseconds)ms"
        case .warning(let code, let milliseconds):
            return "\(code) · \(milliseconds)ms"
        case .unreachable:
            return "No Response"
        }
    }
}

struct PreflightResult: Equatable {
    var issues: [PreflightIssue]

    var isClear: Bool {
        issues.allSatisfy { $0.severity != .error }
    }

    var summary: String {
        if issues.isEmpty { return "Preflight clear" }
        return issues.map(\.message).joined(separator: " · ")
    }
}

struct PreflightIssue: Identifiable, Equatable {
    enum Severity: String {
        case info
        case warning
        case error
    }

    var id = UUID()
    var severity: Severity
    var message: String
}

struct CommandPreset: Identifiable, Equatable {
    var id: String { "\(title)-\(commandTemplate)" }
    let title: String
    let kind: ProjectKind
    let commandTemplate: String
    let port: Int?
    let healthPath: String
}

struct DiscoveredPort: Identifiable, Equatable {
    let port: Int
    let pid: Int32
    let command: String
    let user: String
    let endpoint: String
    var workingDirectory: String?
    var inferredProjectName: String?
    var commandLine: String?
    var startedAt: Date?
    var pinnedName: String?
    var isIgnored: Bool
    var isManaged: Bool
    var projectId: UUID?
    var projectName: String?

    var id: String {
        "\(pid)-\(port)"
    }

    var displayOwner: String {
        if let projectName {
            return projectName
        }
        if let pinnedName {
            return pinnedName
        }
        if let inferredProjectName {
            return inferredProjectName
        }
        return command
    }

    var safety: PortSafety {
        let commandText = command.lowercased()
        let commandLineText = (commandLine ?? "").lowercased()
        let protectedTokens = [
            "adb",
            "docker",
            "emulator",
            "netsimd",
            "qemu",
            "rapportd",
            "controlcenter",
            "sharingd",
            "airplay",
            "postgres",
            "redis-server",
            "mysqld"
        ]

        if protectedTokens.contains(where: { commandText.contains($0) || commandLineText.contains($0) }) {
            return .protected
        }

        if [5432, 6379, 3306, 5554, 5555].contains(port) {
            return .caution
        }

        return .normal
    }

    var isSystemOrEmulatorPort: Bool {
        let commandText = command.lowercased()
        let commandLineText = (commandLine ?? "").lowercased()
        let endpointText = endpoint.lowercased()
        let tokens = [
            "adb",
            "controlcenter",
            "emulator",
            "netsimd",
            "qemu",
            "rapportd",
            "sharingd"
        ]

        if tokens.contains(where: { commandText.contains($0) || commandLineText.contains($0) }) {
            return true
        }

        if [5554, 5555].contains(port) {
            return true
        }

        return endpointText.contains("[::1]") && port >= 49_152
    }

    var detailText: String {
        var parts = ["PID \(pid)"]

        if let commandLine, !commandLine.isEmpty, commandLine != command {
            parts.append(commandLine)
        } else {
            parts.append(command)
        }

        if let compactWorkingDirectory {
            parts.append(compactWorkingDirectory)
        }

        parts.append(endpoint)
        return parts.joined(separator: " - ")
    }

    private var compactWorkingDirectory: String? {
        guard let workingDirectory else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workingDirectory.hasPrefix(home) {
            return "~" + workingDirectory.dropFirst(home.count)
        }
        return workingDirectory
    }
}

enum PortSafety: Equatable {
    case normal
    case caution
    case protected

    var displayName: String {
        switch self {
        case .normal:
            return "Kill"
        case .caution:
            return "Confirm"
        case .protected:
            return "Protected"
        }
    }
}

struct DiscoveredPortGroup: Identifiable, Equatable {
    let key: String
    let title: String
    let primaryPort: DiscoveredPort
    let ports: [DiscoveredPort]

    var id: String { key }

    var secondaryPorts: [DiscoveredPort] {
        ports.filter { $0.id != primaryPort.id }
    }

    var portSummary: String {
        ports
            .map(\.port)
            .sorted()
            .map(String.init)
            .joined(separator: ", ")
    }

    var detailText: String {
        if ports.count == 1 {
            return primaryPort.detailText
        }

        let suffix = ports.count == 2 ? "port" : "ports"
        return "\(ports.count) \(suffix) · \(portSummary)"
    }
}

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case icon
    case count

    static let storageKey = "menuBarDisplayMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon:
            return "Icon"
        case .count:
            return "Count"
        }
    }
}

struct MenuBarTitle: Equatable {
    var runningCount: Int
    var totalCount: Int
    var externalCount: Int
    var displayMode: MenuBarDisplayMode

    var countText: String {
        "\(runningCount)"
    }

    var tooltip: String {
        if totalCount == 0 {
            return "Local Monitor"
        }
        let externalText = externalCount == 1 ? "1 external port" : "\(externalCount) external ports"
        let runningText = runningCount == 1 ? "1 running project" : "\(runningCount) running projects"
        return "\(runningText), \(externalText)"
    }
}

enum AppPreference {
    static let stopProjectsOnQuitKey = "stopProjectsOnQuit"
    static let autoStartSavedProjectsKey = "autoStartSavedProjects"
    static let openBrowserAfterStartKey = "openBrowserAfterStart"
    static let scanExternalPortsKey = "scanExternalPorts"
    static let showExternalInMenuBarKey = "showExternalInMenuBar"
    static let defaultPortKey = "defaultPort"
    static let refreshIntervalKey = "refreshInterval"
    static let showDockIconKey = "showDockIcon"
    static let showDockValuesKey = "showDockValues"
    static let safeKillKey = "safeKill"
    static let notificationsKey = "notifications"
    static let healthChecksKey = "healthChecks"

    static var defaultPort: Int {
        let value = UserDefaults.standard.integer(forKey: defaultPortKey)
        return value == 0 ? 3000 : value
    }

    static var refreshInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: refreshIntervalKey)
        return value <= 0 ? 15 : max(10, value)
    }

    static var scanExternalPorts: Bool {
        UserDefaults.standard.object(forKey: scanExternalPortsKey) as? Bool ?? true
    }

    static var showExternalInMenuBar: Bool {
        UserDefaults.standard.object(forKey: showExternalInMenuBarKey) as? Bool ?? true
    }

    static var stopProjectsOnQuit: Bool {
        UserDefaults.standard.object(forKey: stopProjectsOnQuitKey) as? Bool ?? false
    }

    static var autoStartSavedProjects: Bool {
        UserDefaults.standard.object(forKey: autoStartSavedProjectsKey) as? Bool ?? false
    }

    static var openBrowserAfterStart: Bool {
        UserDefaults.standard.object(forKey: openBrowserAfterStartKey) as? Bool ?? true
    }

    static var safeKill: Bool {
        UserDefaults.standard.object(forKey: safeKillKey) as? Bool ?? true
    }

    static var notifications: Bool {
        UserDefaults.standard.object(forKey: notificationsKey) as? Bool ?? true
    }

    static var healthChecks: Bool {
        UserDefaults.standard.object(forKey: healthChecksKey) as? Bool ?? false
    }
}
