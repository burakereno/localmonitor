import Foundation
import XCTest
@testable import LocalMonitor

final class ProjectNameRefreshTests: XCTestCase {
    @MainActor
    func testRefreshUpdatesProjectNameFromPackageJSON() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMonitorProjectNameTests-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = temporaryDirectory.appendingPathComponent("project-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try writePackageJSON(name: "old-name", to: projectDirectory)
        let project = LocalProject(
            name: "old-name",
            path: projectDirectory.path,
            kind: .unknown,
            packageManager: .npm,
            port: 65_000,
            commandTemplate: "npm run dev"
        )
        let store = ProjectStore(storageDirectoryURL: temporaryDirectory.appendingPathComponent("store"))
        store.save(ProjectLibrary(projects: [project], groups: []))

        let suiteName = "LocalMonitorProjectNameTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = LocalMonitorModel(store: store, userDefaults: defaults)

        try writePackageJSON(name: "renamed-project", to: projectDirectory)
        await model.refresh()

        XCTAssertEqual(model.projects.first?.name, "renamed-project")
    }

    @MainActor
    func testRefreshKeepsProjectNameWhilePackageJSONIsInvalid() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMonitorProjectNameTests-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = temporaryDirectory.appendingPathComponent("project-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try writePackageJSON(name: "stable-name", to: projectDirectory)
        let project = LocalProject(
            name: "stable-name",
            path: projectDirectory.path,
            kind: .unknown,
            packageManager: .npm,
            port: 65_001,
            commandTemplate: "npm run dev"
        )
        let store = ProjectStore(storageDirectoryURL: temporaryDirectory.appendingPathComponent("store"))
        store.save(ProjectLibrary(projects: [project], groups: []))

        let suiteName = "LocalMonitorProjectNameTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = LocalMonitorModel(store: store, userDefaults: defaults)

        try Data("{\"name\":".utf8).write(
            to: projectDirectory.appendingPathComponent("package.json"),
            options: .atomic
        )
        await model.refresh()

        XCTAssertEqual(model.projects.first?.name, "stable-name")
    }

    private func writePackageJSON(name: String, to folderURL: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": name])
        try data.write(to: folderURL.appendingPathComponent("package.json"), options: .atomic)
    }
}
