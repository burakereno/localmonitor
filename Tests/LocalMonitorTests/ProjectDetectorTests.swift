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
