import Foundation
import XCTest
@testable import LocalMonitor

final class ProjectDetectorTests: XCTestCase {
    func testDetectsNextProjectAndBuildsPortTemplate() throws {
        let folder = try makeTempProject(files: [
            "package.json": """
            {
              "name": "site",
              "scripts": { "dev": "next dev" },
              "dependencies": { "next": "latest" }
            }
            """,
            "pnpm-lock.yaml": ""
        ])

        let result = ProjectDetector.detect(folderURL: folder, preferredPort: 3000)

        XCTAssertEqual(result.name, "site")
        XCTAssertEqual(result.kind, .nextjs)
        XCTAssertEqual(result.packageManager, .pnpm)
        XCTAssertEqual(result.defaultPort, 3000)
        XCTAssertEqual(result.commandTemplate, "pnpm dev -p {port}")
    }

    func testDetectsHonoProjectFromDependency() throws {
        let folder = try makeTempProject(files: [
            "package.json": """
            {
              "scripts": { "dev": "tsx watch src/index.ts" },
              "dependencies": { "hono": "latest" }
            }
            """,
            "bun.lock": ""
        ])

        let result = ProjectDetector.detect(folderURL: folder, preferredPort: 3000)

        XCTAssertEqual(result.kind, .hono)
        XCTAssertEqual(result.packageManager, .bun)
        XCTAssertEqual(result.commandTemplate, "PORT={port} bun run dev")
    }

    func testDetectsViteProjectAndStorybookPreset() throws {
        let folder = try makeTempProject(files: [
            "package.json": """
            {
              "name": "console",
              "scripts": {
                "dev": "vite",
                "storybook": "storybook dev"
              },
              "devDependencies": {
                "vite": "latest",
                "@storybook/react": "latest"
              }
            }
            """,
            "package-lock.json": ""
        ])

        let result = ProjectDetector.detect(folderURL: folder, preferredPort: 5173)

        XCTAssertEqual(result.kind, .vite)
        XCTAssertEqual(result.commandTemplate, "npm run dev -- --host 0.0.0.0 --port {port}")
        XCTAssertTrue(result.suggestedPresets.contains { $0.title == "Storybook" && $0.port == 6006 })
    }

    func testDetectsAstroPnpmProjectAndPassesPortDirectly() throws {
        let folder = try makeTempProject(files: [
            "package.json": """
            {
              "name": "lovacolors",
              "scripts": { "dev": "astro dev --host 0.0.0.0" },
              "dependencies": { "astro": "latest" }
            }
            """,
            "pnpm-lock.yaml": ""
        ])

        let result = ProjectDetector.detect(folderURL: folder, preferredPort: 3001)

        XCTAssertEqual(result.kind, .astro)
        XCTAssertEqual(result.packageManager, .pnpm)
        XCTAssertEqual(result.commandTemplate, "pnpm dev --host 0.0.0.0 --port {port}")
    }

    func testSvelteKitTakesPrecedenceOverItsViteDependency() throws {
        let folder = try makeTempProject(files: [
            "package.json": #"{"scripts":{"dev":"vite dev"},"devDependencies":{"@sveltejs/kit":"2","vite":"7"}}"#
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let detection = ProjectDetector.detect(folderURL: folder)
        XCTAssertEqual(detection.kind, .sveltekit)
        let legacy = LocalProject(name: "web", path: folder.path, kind: .vite, packageManager: .npm,
                                  port: 5173, commandTemplate: detection.commandTemplate)
        XCTAssertEqual(ProjectDetector.repairDetectedDefaults(in: legacy).kind, .sveltekit)
    }

    func testExpoWithOnlyAStartScriptRepairsOnlyTheGeneratedTemplate() throws {
        let folder = try makeTempProject(files: [
            "package.json": #"{"scripts":{"start":"expo start"},"dependencies":{"expo":"latest"}}"#
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let detection = ProjectDetector.detect(folderURL: folder)
        XCTAssertEqual(detection.commandTemplate, "EXPO_DEVTOOLS_LISTEN_ADDRESS=0.0.0.0 PORT={port} npm run start")
        var saved = LocalProject(name: "mobile", path: folder.path, kind: .expo, packageManager: .npm, port: 8081,
                                 commandTemplate: "EXPO_DEVTOOLS_LISTEN_ADDRESS=0.0.0.0 PORT={port} npm run dev")
        XCTAssertEqual(ProjectDetector.repairDetectedDefaults(in: saved).commandTemplate, detection.commandTemplate)
        saved.commandTemplate = "npx expo start --offline"
        XCTAssertEqual(ProjectDetector.repairDetectedDefaults(in: saved), saved)
    }

    func testSwitchingManagersPreservesEnvironmentAndPassesScriptArguments() {
        XCTAssertEqual(ProjectDetector.switchPackageManager(in: "PORT={port} npm run dev", from: .npm, to: .pnpm),
                       "PORT={port} pnpm dev")
        XCTAssertEqual(ProjectDetector.switchPackageManager(in: "EXPO_DEVTOOLS_LISTEN_ADDRESS=0.0.0.0 PORT={port} yarn start",
                                                            from: .yarn, to: .bun),
                       "EXPO_DEVTOOLS_LISTEN_ADDRESS=0.0.0.0 PORT={port} bun run start")
        XCTAssertEqual(ProjectDetector.switchPackageManager(in: "npm run storybook -- -p {port}", from: .npm, to: .pnpm),
                       "pnpm run storybook -p {port}")
        XCTAssertEqual(ProjectDetector.switchPackageManager(in: "node custom.mjs", from: .npm, to: .pnpm), "node custom.mjs")
    }

    func testNormalizesLegacyPnpmDoubleDashCommandTemplate() {
        XCTAssertEqual(
            ProjectDetector.normalizeCommandTemplate(
                "pnpm dev -- --host 0.0.0.0 --port {port}",
                packageManager: .pnpm
            ),
            "pnpm dev --host 0.0.0.0 --port {port}"
        )

        XCTAssertEqual(
            ProjectDetector.normalizeCommandTemplate(
                "npm run dev -- --host 0.0.0.0 --port {port}",
                packageManager: .npm
            ),
            "npm run dev -- --host 0.0.0.0 --port {port}"
        )
    }

    private func makeTempProject(files: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (relativePath, contents) in files {
            let url = folder.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.data(using: .utf8)?.write(to: url)
        }

        return folder
    }
}
