import Foundation
import XCTest
@testable import LocalMonitor

final class QuickLaunchOrderingTests: XCTestCase {
    @MainActor
    func testPinnedProjectsUseManualOrderBeforeRecentProjects() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        let oldest = Date(timeIntervalSince1970: 100)
        let newest = Date(timeIntervalSince1970: 300)
        let projects = [
            project(name: "recent", lastUsedAt: newest),
            project(name: "pinned-second", isPinned: true, order: 1, lastUsedAt: newest),
            project(name: "pinned-first", isPinned: true, order: 0, lastUsedAt: oldest),
            project(name: "older", lastUsedAt: oldest)
        ]
        context.store.save(ProjectLibrary(projects: projects, groups: []))

        let model = LocalMonitorModel(store: context.store, userDefaults: context.defaults)

        XCTAssertEqual(
            model.quickLaunchProjects.map(\.name),
            ["pinned-first", "pinned-second", "recent", "older"]
        )
    }

    @MainActor
    func testDraggingProjectPinsItAndPersistsManualOrder() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        let first = project(name: "first")
        let second = project(name: "second")
        let third = project(name: "third")
        context.store.save(ProjectLibrary(projects: [first, second, third], groups: []))

        let model = LocalMonitorModel(store: context.store, userDefaults: context.defaults)
        model.setQuickLaunchPinned(second, pinned: true)

        XCTAssertTrue(model.moveQuickLaunchProject(third.id, before: second.id))
        XCTAssertEqual(model.quickLaunchProjects.map(\.name), ["third", "second", "first"])

        let reloadedModel = LocalMonitorModel(store: context.store, userDefaults: context.defaults)
        XCTAssertEqual(reloadedModel.quickLaunchProjects.map(\.name), ["third", "second", "first"])
        XCTAssertEqual(
            reloadedModel.quickLaunchProjects.prefix(2).map(\.quickLaunchOrder),
            [0, 1]
        )
    }

    @MainActor
    func testRecentUseOrderPersistsForUnpinnedProjects() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        let first = project(name: "first")
        let second = project(name: "second")
        let third = project(name: "third")
        context.store.save(ProjectLibrary(projects: [first, second, third], groups: []))

        let model = LocalMonitorModel(store: context.store, userDefaults: context.defaults)
        model.recordProjectUse(third, at: Date(timeIntervalSince1970: 100))
        model.recordProjectUse(second, at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(model.quickLaunchProjects.map(\.name), ["second", "third", "first"])

        let reloadedModel = LocalMonitorModel(store: context.store, userDefaults: context.defaults)
        XCTAssertEqual(reloadedModel.quickLaunchProjects.map(\.name), ["second", "third", "first"])
    }

    func testLegacyProjectJSONDefaultsQuickLaunchMetadata() throws {
        let data = Data(
            """
            {
              "name": "legacy",
              "path": "/tmp/legacy",
              "port": 3000,
              "commandTemplate": "npm run dev"
            }
            """.utf8
        )

        let project = try JSONDecoder().decode(LocalProject.self, from: data)

        XCTAssertFalse(project.isQuickLaunchPinned)
        XCTAssertNil(project.quickLaunchOrder)
        XCTAssertNil(project.lastUsedAt)
    }

    func testPinnedAndRunningProjectsUsePriorityRows() {
        let pinnedOffline = project(name: "pinned-offline", isPinned: true, order: 0)
        let pinnedRunning = project(name: "pinned-running", isPinned: true, order: 1)
        let running = project(name: "running")
        let offlineProjects = (1...9).map { project(name: "offline-\($0)") }
        let projects = [pinnedOffline, pinnedRunning, running] + offlineProjects

        let plan = QuickLaunchRowPlan.make(
            projects: projects,
            onlineProjectIDs: [pinnedRunning.id, running.id],
            projectsPerRow: 10,
            maximumVisibleItems: 20
        )

        XCTAssertEqual(
            plan.priorityProjectRows.flatMap { $0 }.map(\.name),
            ["pinned-offline", "pinned-running", "running"]
        )
        XCTAssertEqual(
            plan.regularProjectRows.flatMap { $0 }.map(\.name),
            offlineProjects.map(\.name)
        )
        XCTAssertEqual(plan.priorityProjectRows.count, 1)
        XCTAssertEqual(plan.regularProjectRows.count, 1)
        XCTAssertEqual(plan.hiddenProjectCount, 0)
    }

    private func project(
        name: String,
        isPinned: Bool = false,
        order: Int? = nil,
        lastUsedAt: Date? = nil
    ) -> LocalProject {
        LocalProject(
            name: name,
            path: "/tmp/\(name)",
            kind: .nextjs,
            packageManager: .npm,
            port: 3_000 + name.count,
            commandTemplate: "npm run dev",
            isQuickLaunchPinned: isPinned,
            quickLaunchOrder: order,
            lastUsedAt: lastUsedAt
        )
    }
}

private final class TestContext {
    let rootURL: URL
    let store: ProjectStore
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMonitorQuickLaunchTests-\(UUID().uuidString)", isDirectory: true)
        store = ProjectStore(storageDirectoryURL: rootURL.appendingPathComponent("store", isDirectory: true))
        suiteName = "LocalMonitorQuickLaunchTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
