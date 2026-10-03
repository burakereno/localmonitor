import Foundation

struct ProjectDetectionResult: Equatable {
    let name: String
    let kind: ProjectKind
    let packageManager: PackageManager
    let defaultPort: Int
    let commandTemplate: String
    let suggestedPresets: [CommandPreset]
    let hostname: String
}

enum ProjectDetector {
    static func detect(folderURL: URL, preferredPort: Int = AppPreference.defaultPort) -> ProjectDetectionResult {
        let package = readPackageJSON(in: folderURL)
        let name = package?.name?.nilIfBlank ?? folderURL.lastPathComponent
        let dependencies = package?.allDependencies ?? []
        let packageManager = detectPackageManager(in: folderURL)
        let kind = detectKind(folderURL: folderURL, dependencies: dependencies)
        let defaultPort = scriptPort(package?.scripts["dev"] ?? package?.scripts["start"])
            ?? defaultPort(for: kind, folderURL: folderURL, preferredPort: preferredPort)
        let commandTemplate = detectCommandTemplate(
            package: package,
            kind: kind,
            packageManager: packageManager
        )
        let presets = buildPresets(
            package: package,
            kind: kind,
            packageManager: packageManager,
            defaultPort: defaultPort
        )

        return ProjectDetectionResult(
            name: name,
            kind: kind,
            packageManager: packageManager,
            defaultPort: defaultPort,
            commandTemplate: commandTemplate,
            suggestedPresets: presets,
            hostname: LocalHostname.detect(in: folderURL)
        )
    }

    static func launchProfiles(in folder: URL, preferredPort: Int = AppPreference.defaultPort) -> [ProjectLaunchProfile] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        return ProjectWorkspace.directories(in: root).compactMap { app in
            let scripts = ProjectWorkspace.package(in: app)?["scripts"] as? [String: String] ?? [:]
            guard scripts["dev"] != nil || scripts["start"] != nil else { return nil }
            return ProjectLaunchProfile(
                folderURL: app,
                relativePath: String(app.path.dropFirst(root.path.count + 1)),
                detection: detect(folderURL: app, preferredPort: preferredPort)
            )
        }
    }

    private static func scriptPort(_ script: String?) -> Int? {
        guard let script,
              let range = script.range(of: #"(?:--port(?:=|\s+)|-p\s+)[0-9]+"#, options: .regularExpression),
              let digits = script[range].range(of: #"[0-9]+$"#, options: .regularExpression),
              let port = Int(script[digits]), (1_024...65_535).contains(port) else { return nil }
        return port
    }

    static func presets(for project: LocalProject) -> [CommandPreset] {
        let folderURL = project.folderURL
        let package = readPackageJSON(in: folderURL)
        return buildPresets(
            package: package,
            kind: project.kind,
            packageManager: project.packageManager,
            defaultPort: project.port
        )
    }

    static func packageName(in folderURL: URL) -> String? {
        readPackageJSON(in: folderURL)?.name?.nilIfBlank
    }

    private static func detectKind(folderURL: URL, dependencies: Set<String>) -> ProjectKind {
        if dependencies.contains("next") || fileExists("next.config.js", in: folderURL)
            || fileExists("next.config.mjs", in: folderURL)
            || fileExists("next.config.ts", in: folderURL) {
            return .nextjs
        }

        if dependencies.contains("hono") || fileContainsHonoReference(folderURL: folderURL) {
            return .hono
        }

        if dependencies.contains("vite") || fileExists("vite.config.ts", in: folderURL)
            || fileExists("vite.config.js", in: folderURL)
            || fileExists("vite.config.mjs", in: folderURL) {
            return .vite
        }

        if dependencies.contains("astro") || fileExists("astro.config.mjs", in: folderURL)
            || fileExists("astro.config.ts", in: folderURL) {
            return .astro
        }

        if dependencies.contains("@remix-run/dev") || dependencies.contains("@remix-run/node")
            || fileExists("remix.config.js", in: folderURL) {
            return .remix
        }

        if dependencies.contains("@sveltejs/kit") || fileExists("svelte.config.js", in: folderURL) {
            return .sveltekit
        }

        if dependencies.contains("nuxt") || fileExists("nuxt.config.ts", in: folderURL)
            || fileExists("nuxt.config.js", in: folderURL) {
            return .nuxt
        }

        if dependencies.contains("expo") || fileExists("app.json", in: folderURL)
            || fileExists("app.config.js", in: folderURL)
            || fileExists("app.config.ts", in: folderURL) {
            return .expo
        }

        if fileExists("supabase/config.toml", in: folderURL) {
            return .supabase
        }

        if dependencies.contains("prisma") || fileExists("prisma/schema.prisma", in: folderURL) {
            return .prisma
        }

        if dependencies.contains("@storybook/react") || dependencies.contains("@storybook/nextjs")
            || dependencies.contains("@storybook/vue3")
            || fileExists(".storybook/main.ts", in: folderURL)
            || fileExists(".storybook/main.js", in: folderURL) {
            return .storybook
        }

        return .unknown
    }

    private static func detectPackageManager(in folderURL: URL) -> PackageManager {
        let root = ProjectWorkspace.root(containing: folderURL) ?? folderURL
        let declared = ProjectWorkspace.package(in: root)?["packageManager"] as? String
        if let manager = declared?.split(separator: "@").first.flatMap({ PackageManager(rawValue: String($0)) }) { return manager }
        if fileExists("pnpm-lock.yaml", in: root) { return .pnpm }
        if fileExists("bun.lock", in: root) || fileExists("bun.lockb", in: root) { return .bun }
        if fileExists("yarn.lock", in: root) { return .yarn }
        return .npm
    }

    private static func defaultPort(
        for kind: ProjectKind,
        folderURL: URL,
        preferredPort: Int
    ) -> Int {
        if kind == .hono, fileExists("wrangler.toml", in: folderURL) {
            return 8787
        }
        if kind == .prisma {
            return 5555
        }
        if kind == .storybook {
            return 6006
        }
        if kind == .supabase {
            return 54323
        }
        return preferredPort
    }

    private static func detectCommandTemplate(
        package: PackageJSON?,
        kind: ProjectKind,
        packageManager: PackageManager
    ) -> String {
        let hasDev = package?.scripts.keys.contains("dev") ?? false
        let hasStart = package?.scripts.keys.contains("start") ?? false

        switch kind {
        case .nextjs:
            let base = hasDev ? packageManager.devCommand : (hasStart ? packageManager.startCommand : packageManager.devCommand)
            let script = hasDev ? package?.scripts["dev"] : package?.scripts["start"]
            if let script, !script.contains("next dev"), !script.contains("next start") { return "PORT={port} \(base)" }
            return "\(base)\(packageManager.scriptArguments("-p {port}"))"
        case .hono:
            let base = hasDev ? packageManager.devCommand : (hasStart ? packageManager.startCommand : packageManager.devCommand)
            return "PORT={port} \(base)"
        case .vite, .astro, .sveltekit:
            let base = hasDev ? packageManager.devCommand : (hasStart ? packageManager.startCommand : packageManager.devCommand)
            return "\(base)\(packageManager.scriptArguments("--host 0.0.0.0 --port {port}"))"
        case .remix, .nuxt:
            let base = hasDev ? packageManager.devCommand : (hasStart ? packageManager.startCommand : packageManager.devCommand)
            return "PORT={port} \(base)"
        case .expo:
            let base = hasDev ? packageManager.devCommand : packageManager.devCommand
            return "EXPO_DEVTOOLS_LISTEN_ADDRESS=0.0.0.0 PORT={port} \(base)"
        case .supabase:
            return "supabase start"
        case .prisma:
            return "npx prisma studio --port {port}"
        case .storybook:
            let hasStorybook = package?.scripts.keys.contains("storybook") ?? false
            let base = hasStorybook ? "\(packageManager.rawValue) run storybook" : "\(packageManager.devCommand)"
            return "\(base)\(packageManager.scriptArguments("-p {port}"))"
        case .unknown:
            let base = hasDev ? packageManager.devCommand : (hasStart ? packageManager.startCommand : packageManager.devCommand)
            return "PORT={port} \(base)"
        }
    }

    static func normalizeCommandTemplate(_ commandTemplate: String, packageManager: PackageManager) -> String {
        guard packageManager != .npm else { return commandTemplate }

        var normalized = commandTemplate
        let commandPrefixes = [
            packageManager.devCommand,
            packageManager.startCommand,
            "\(packageManager.rawValue) run storybook"
        ]

        for prefix in commandPrefixes {
            normalized = normalized.replacingOccurrences(
                of: "\(prefix) -- --",
                with: "\(prefix) --"
            )
            normalized = normalized.replacingOccurrences(
                of: "\(prefix) -- -",
                with: "\(prefix) -"
            )
        }

        return normalized
    }

    private static func buildPresets(
        package: PackageJSON?,
        kind: ProjectKind,
        packageManager: PackageManager,
        defaultPort: Int
    ) -> [CommandPreset] {
        var presets: [CommandPreset] = [
            CommandPreset(
                title: "\(kind.shortName) Dev",
                kind: kind,
                commandTemplate: detectCommandTemplate(package: package, kind: kind, packageManager: packageManager),
                port: defaultPort,
                healthPath: "/"
            )
        ]

        if package?.scripts.keys.contains("start") == true {
            presets.append(CommandPreset(
                title: "Start",
                kind: kind,
                commandTemplate: "PORT={port} \(packageManager.startCommand)",
                port: defaultPort,
                healthPath: "/"
            ))
        }

        if package?.scripts.keys.contains("storybook") == true {
            presets.append(CommandPreset(
                title: "Storybook",
                kind: .storybook,
                commandTemplate: "\(packageManager.rawValue) run storybook -- -p {port}",
                port: 6006,
                healthPath: "/"
            ))
        }

        if package?.allDependencies.contains("prisma") == true {
            presets.append(CommandPreset(
                title: "Prisma Studio",
                kind: .prisma,
                commandTemplate: "npx prisma studio --port {port}",
                port: 5555,
                healthPath: "/"
            ))
        }

        return uniquePresets(presets)
    }

    private static func uniquePresets(_ presets: [CommandPreset]) -> [CommandPreset] {
        var seen = Set<String>()
        return presets.filter { preset in
            guard !seen.contains(preset.commandTemplate) else { return false }
            seen.insert(preset.commandTemplate)
            return true
        }
    }

    private static func readPackageJSON(in folderURL: URL) -> PackageJSON? {
        let url = folderURL.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PackageJSON.self, from: data)
    }

    private static func fileExists(_ name: String, in folderURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(name).path)
    }

    private static func fileContainsHonoReference(folderURL: URL) -> Bool {
        let candidates = [
            "src/index.ts",
            "src/index.js",
            "src/app.ts",
            "src/app.js",
            "index.ts",
            "index.js"
        ]

        return candidates.contains { relativePath in
            let url = folderURL.appendingPathComponent(relativePath)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains("from 'hono'") || text.contains("from \"hono\"") || text.contains("new Hono")
        }
    }
}

private struct PackageJSON: Decodable {
    let name: String?
    let scripts: [String: String]
    let dependencies: [String: String]
    let devDependencies: [String: String]

    enum CodingKeys: String, CodingKey {
        case name
        case scripts
        case dependencies
        case devDependencies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.scripts = try container.decodeIfPresent([String: String].self, forKey: .scripts) ?? [:]
        self.dependencies = try container.decodeIfPresent([String: String].self, forKey: .dependencies) ?? [:]
        self.devDependencies = try container.decodeIfPresent([String: String].self, forKey: .devDependencies) ?? [:]
    }

    var allDependencies: Set<String> {
        Set(dependencies.keys).union(devDependencies.keys)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
