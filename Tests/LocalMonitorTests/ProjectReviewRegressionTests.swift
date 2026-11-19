import Foundation
import XCTest
@testable import LocalMonitor

final class ProjectReviewRegressionTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder.resolvingSymlinksInPath().standardizedFileURL
    }

    private func project(at folder: URL, port: Int) -> LocalProject {
        LocalProject(name: "fixture", path: folder.path, kind: .unknown, packageManager: .npm,
                     port: port, commandTemplate: "npm run dev", openAfterStart: false)
    }

    func testRecoveryPreservesTheOriginalAndKeepsValidProjectsAndGroups() throws {
        let directory = try temporaryFolder()
        let url = directory.appendingPathComponent("projects.json")
        let store = ProjectStore(storageDirectoryURL: directory)
        let project = project(at: directory, port: 3000)
        let group = WorkspaceGroup(name: "work", projectIDs: [project.id])
        store.save(ProjectLibrary(projects: [project], groups: [group]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let goodRow = try XCTUnwrap((json["projects"] as? [[String: Any]])?.first)
        var corrupted = json
        var invalidPort = goodRow
        invalidPort["id"] = UUID().uuidString
        invalidPort["port"] = 70_000
        corrupted["projects"] = [goodRow, ["port": "bad"], NSNull(), goodRow, invalidPort] as [Any]
        let bytes = try JSONSerialization.data(withJSONObject: corrupted)
        try bytes.write(to: url)
        let recovered = store.load()
        XCTAssertEqual(recovered.projects.map(\.id), [project.id])
        XCTAssertEqual(recovered.groups, [group])
        XCTAssertNotNil(store.loadIssue)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        _ = store.load()
        store.save(recovered)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("projects-recovery-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
        XCTAssertEqual(store.load(), recovered)
        XCTAssertNil(store.loadIssue)
    }

    func testCacheCleanRejectsAnExternalSymlinkBeforeRemovingAnyCache() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        let astro = root.appendingPathComponent(".astro")
        let vite = outside.appendingPathComponent(".vite")
        let files = FileManager.default
        try files.createDirectory(at: astro, withIntermediateDirectories: false)
        try files.createDirectory(at: vite, withIntermediateDirectories: false)
        try files.createSymbolicLink(at: root.appendingPathComponent("node_modules"), withDestinationURL: outside)
        XCTAssertThrowsError(try ProjectCacheCleaner.remove(relativePaths: [".astro", "node_modules/.vite"], in: root))
        XCTAssertTrue(files.fileExists(atPath: astro.path))
        XCTAssertTrue(files.fileExists(atPath: vite.path))
    }

    func testCacheCleanRemovesOnlyExistingCacheEntries() throws {
        let folder = try temporaryFolder()
        let name = "node_modules/.vite"
        let cache = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([1]).write(to: cache.appendingPathComponent("cached"))
        XCTAssertEqual(try ProjectCacheCleaner.remove(relativePaths: [".astro", name], in: folder), [name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.deletingLastPathComponent().path))
    }

    @MainActor
    func testOneListenerProcessHasAtMostOneOwnerAcrossNestedAndSharedFolders() throws {
        let root = try temporaryFolder()
        let app = root.appendingPathComponent("apps/site", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let parent = project(at: root, port: 3000)
        let site = project(at: app, port: 3001)
        let storybook = project(at: app, port: 6006)
        let folders = [root.path: [parent], app.path: [site, storybook]]
        func listener(_ port: Int) -> DiscoveredPort {
            DiscoveredPort(port: port, pid: 500, command: "node", user: "fixture", endpoint: "*:\(port)",
                           workingDirectory: app.path, isIgnored: false, isManaged: false)
        }
        XCTAssertEqual(LocalMonitorModel.externalOwner(of: [listener(3001), listener(9000)], byFolder: folders)?.id, site.id)
        XCTAssertNil(LocalMonitorModel.externalOwner(of: [listener(3001), listener(6006)], byFolder: folders))
        XCTAssertNil(LocalMonitorModel.externalOwner(of: [listener(3000)], byFolder: folders))
        XCTAssertEqual(LocalMonitorModel.externalOwner(of: [listener(9000)], byFolder: [root.path: [parent]])?.id, parent.id)
    }

    @MainActor
    func testStopRequiresOneExternalProcessEvenIfSeveralUseTheSameProjectFolder() throws {
        let project = project(at: try temporaryFolder(), port: 3000)
        func listener(_ pid: Int32, _ port: Int) -> DiscoveredPort {
            DiscoveredPort(port: port, pid: pid, command: "node", user: "test", endpoint: "*:\(port)",
                           isIgnored: false, isManaged: false, projectId: project.id)
        }
        let auxiliary = [listener(21, 8080), listener(22, 9000)]
        XCTAssertNil(LocalMonitorModel.externalProcessToStop(for: project, in: auxiliary))
        XCTAssertEqual(LocalMonitorModel.externalProcessToStop(for: project, in: auxiliary + [listener(23, 3000)])?.pid, 23)
        XCTAssertNil(LocalMonitorModel.externalProcessToStop(for: project, in: [listener(23, 3000), listener(24, 3000)]))
    }

    @MainActor
    func testFailedPortScanLeavesTheCacheIntactAndReportsMaintenanceFailure() async throws {
        let folder = try temporaryFolder()
        var site = project(at: folder, port: 3000)
        site.kind = .nextjs
        let cache = folder.appendingPathComponent(".next")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let model = try model(with: [site], in: folder, scanner: FailedPortScan())
        await model.cleanRestartProject(site)
        XCTAssertEqual(model.cleanRestartStates[site.id]?.phase, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertNotNil(model.lastError)
        await model.restartProject(site)
        XCTAssertEqual(model.cleanRestartStates[site.id]?.phase, .failed)
        XCTAssertFalse(model.processManager.isRunning(projectId: site.id))
    }

    @MainActor
    func testRefreshKeepsSessionMetadataWhenTheLibraryCannotBeDecoded() async throws {
        let folder = try temporaryFolder()
        let store = ProjectStore(storageDirectoryURL: folder)
        try Data("broken".utf8).write(to: folder.appendingPathComponent("projects.json"))
        let suite = "RecoveredSessions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString
        let saved = try JSONSerialization.data(withJSONObject: [id: ["startedAt": "2026-11-19T09:00:00Z", "pid": 1234]])
        defaults.set(saved, forKey: "runtimeSessionsV1")
        let model = LocalMonitorModel(store: store, portScanner: FailedPortScan(), userDefaults: defaults)
        await model.refresh()
        XCTAssertEqual(defaults.data(forKey: "runtimeSessionsV1"), saved)
    }

    @MainActor
    func testHiddenSiblingListenerBlocksSharedCacheCleanup() async throws {
        let folder = try temporaryFolder()
        var site = project(at: folder, port: 3000)
        site.kind = .nextjs
        let sibling = project(at: folder, port: 6006)
        let owner = DiscoveredPort(port: 6006, pid: 42, command: "node", user: "test", endpoint: "*:6006",
                                   workingDirectory: folder.path, isIgnored: false, isManaged: false)
        let model = try model(with: [site, sibling], in: folder, scanner: HiddenListener(port: owner))
        let cache = folder.appendingPathComponent(".next")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        await model.cleanRestartProject(site)
        XCTAssertTrue(model.discoveredPorts.isEmpty)
        XCTAssertEqual(model.cleanRestartStates[site.id]?.phase, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    @MainActor
    func testRefreshReturnsAfterItsOwnScanWhileTheNextOneIsInFlight() async throws {
        let firstStarted = expectation(description: "first scan started")
        let secondStarted = expectation(description: "second scan started")
        let scanner = PausedPortScanner(started: [firstStarted, secondStarted])
        let model = try model(with: [], in: temporaryFolder(), scanner: scanner)
        let firstDone = expectation(description: "first refresh returned")
        let first = Task { await model.refresh(); firstDone.fulfill() }
        await fulfillment(of: [firstStarted], timeout: 3)
        let queued = expectation(description: "second request submitted")
        let second = Task { queued.fulfill(); await model.refresh() }
        await fulfillment(of: [queued], timeout: 3)
        await scanner.complete()
        await fulfillment(of: [secondStarted, firstDone], timeout: 3)
        await scanner.complete()
        await first.value
        await second.value
        XCTAssertFalse(model.isRefreshing)
    }

    func testLogRotationPreservesPreviousArchiveAndIgnoresSymlinks() async throws {
        let folder = try temporaryFolder()
        let log = folder.appendingPathComponent("project.log")
        let previous = folder.appendingPathComponent("project.previous.log")
        let other = folder.appendingPathComponent("other.log")
        let original = Data("older archive".utf8)
        try original.write(to: previous)
        try Data([7]).write(to: other)
        let handle = try FileHandle(forWritingTo: other)
        let length = ProjectProcessManager.maximumLogBytes + 1
        try handle.truncate(atOffset: length)
        try handle.close()
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: other)
        let reader = ProjectLogReader()
        await reader.rotateLargeLogs(at: [log])
        XCTAssertEqual(try Data(contentsOf: previous), original)
        XCTAssertEqual(try other.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(length))
        try FileManager.default.removeItem(at: log)
        try FileManager.default.moveItem(at: other, to: log)
        await reader.rotateLargeLogs(at: [log])
        XCTAssertEqual(try previous.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(length))
        XCTAssertEqual(try log.resourceValues(forKeys: [.fileSizeKey]).fileSize, 0)
    }

    @MainActor
    private func model(with projects: [LocalProject], in folder: URL, scanner: any PortScanning) throws -> LocalMonitorModel {
        let suite = "ProjectReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: AppPreference.scanExternalPortsKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(storageDirectoryURL: folder.appendingPathComponent("store"))
        store.save(.init(projects: projects))
        return LocalMonitorModel(store: store, portScanner: scanner, healthChecksEnabled: false,
                                 notificationService: NotificationService(isEnabled: { false }), userDefaults: defaults)
    }

    @MainActor
    func testPortAllocationWrapsAndReportsExhaustion() {
        XCTAssertEqual(LocalMonitorModel.availablePort(startingAt: 65_535, excluding: [65_535, 1024]), 1025)
        XCTAssertEqual(LocalMonitorModel.availablePort(startingAt: 65_536, excluding: []), 1024)
        XCTAssertNil(LocalMonitorModel.availablePort(startingAt: 3000, excluding: Set(1024...65_535)))
    }
}

private struct FailedPortScan: PortScanning {
    func scan(pids: Set<Int32>?, requireComplete: Bool) async throws -> [DiscoveredPort] {
        throw PortScannerError.lsofFailed("Test scan failed")
    }
}

private struct HiddenListener: PortScanning {
    let port: DiscoveredPort
    func scan(pids: Set<Int32>?, requireComplete: Bool) async throws -> [DiscoveredPort] {
        pids == nil && requireComplete ? [port] : []
    }
}

private actor PausedPortScanner: PortScanning {
    let started: [XCTestExpectation]
    var call = 0
    var gate: CheckedContinuation<Void, Never>?
    init(started: [XCTestExpectation]) { self.started = started }

    func scan(pids: Set<Int32>?, requireComplete: Bool) async throws -> [DiscoveredPort] {
        await withCheckedContinuation { continuation in
            gate = continuation
            started[call].fulfill()
            call += 1
        }
        return []
    }

    func complete() {
        gate?.resume()
        gate = nil
    }
}
