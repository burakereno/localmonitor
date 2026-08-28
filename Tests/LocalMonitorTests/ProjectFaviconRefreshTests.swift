import AppKit
import SwiftUI
import XCTest
@testable import LocalMonitor

final class ProjectFaviconRefreshTests: XCTestCase {
    @MainActor
    func testAvatarReloadsFaviconWhenFileChanges() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMonitorFaviconTests-\(UUID().uuidString)", isDirectory: true)
        let publicDirectory = temporaryDirectory.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let faviconURL = publicDirectory.appendingPathComponent("favicon.png")
        let project = LocalProject(
            name: "favicon-fixture",
            path: temporaryDirectory.path,
            kind: .unknown,
            packageManager: .npm,
            port: 65_002,
            commandTemplate: "npm run dev"
        )
        let store = ProjectStore(storageDirectoryURL: temporaryDirectory.appendingPathComponent("store"))
        store.save(ProjectLibrary(projects: [project], groups: []))

        let suiteName = "LocalMonitorFaviconTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = LocalMonitorModel(store: store, userDefaults: defaults)

        try faviconData(color: .systemRed).write(to: faviconURL, options: .atomic)
        let originalAvatar = try renderAvatar(for: project)

        try faviconData(color: .systemBlue).write(to: faviconURL, options: .atomic)
        await model.refresh()
        let refreshedAvatar = try renderAvatar(for: project)

        XCTAssertNotEqual(originalAvatar, refreshedAvatar)
    }

    @MainActor
    private func renderAvatar(for project: LocalProject) throws -> Data {
        let renderer = ImageRenderer(content: ProjectAvatarView(project: project, tint: .blue))
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
    }

    private func faviconData(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
