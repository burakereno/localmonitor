import Foundation
import XCTest
@testable import LocalMonitor

final class WorkspaceLaunchTests: XCTestCase {
    func testDiscoversAppsAndKeepsTheirPortsAndHostsSeparate() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        let profiles = ProjectDetector.launchProfiles(in: fixture.root)
        XCTAssertEqual(profiles.map(\.relativePath), ["apps/mirayoga", "apps/theme-preview"])
        let mira = try XCTUnwrap(profiles.first)
        XCTAssertEqual(mira.detection.defaultPort, 3100)
        XCTAssertEqual(mira.detection.hostname, "mirayoga.localhost")
        XCTAssertEqual(mira.detection.commandTemplate, "npm run dev -- -p {port}")
        XCTAssertEqual(profiles.last?.detection.defaultPort, 3101)
        XCTAssertEqual(profiles.last?.detection.hostname, "localhost")
        XCTAssertEqual(ProjectWorkspace.preferredProfile(in: fixture.root, profiles: profiles)?.id, mira.id)
    }

    func testObjectWorkspacesAndHoistedPackageManagerAreRecognized() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        try fixture.write("package.json", #"{"name":"workspace","packageManager":"pnpm@10.0.0","workspaces":{"packages":["apps/*"]}}"#)
        let profiles = ProjectDetector.launchProfiles(in: fixture.root)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertTrue(profiles.allSatisfy { $0.detection.packageManager == .pnpm })
        XCTAssertEqual(profiles.first?.detection.commandTemplate, "pnpm dev -p {port}")
    }

    func testWorkspaceDiscoveryRejectsExternalSymlinksAndParentPaths() throws {
        let fixture = try WorkspaceLaunchFixture()
        let external = try WorkspaceLaunchFixture()
        defer { fixture.cleanup(); external.cleanup() }
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("apps/external"),
                                                   withDestinationURL: external.root.appendingPathComponent("apps/mirayoga"))
        try fixture.write("package.json", #"{"workspaces":["apps/*","../*","/tmp/*","!apps/theme-preview"]}"#)
        XCTAssertEqual(ProjectDetector.launchProfiles(in: fixture.root).map(\.relativePath), ["apps/mirayoga"])
    }

    func testLegacyDefaultMigratesButCustomLaunchCommandIsPreserved() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        var original = fixture.legacyProject()
        original.isQuickLaunchPinned = true
        original.port = 3200
        let migrated = ProjectLaunchMigration.migrate(original)
        XCTAssertEqual(migrated.id, original.id)
        XCTAssertEqual(migrated.port, 3200)
        XCTAssertTrue(migrated.isQuickLaunchPinned)
        XCTAssertEqual(migrated.path, fixture.root.appendingPathComponent("apps/mirayoga").path)
        XCTAssertEqual(migrated.workspaceRootPath, fixture.root.path)
        XCTAssertEqual(migrated.hostname, "mirayoga.localhost")
        XCTAssertEqual(migrated.resolvedCommand, "npm run dev -- -p 3200")
        XCTAssertEqual(ProjectLaunchMigration.migrate(migrated), migrated)
        original.commandTemplate = "node scripts/custom-launcher.mjs --port {port}"
        XCTAssertEqual(ProjectLaunchMigration.migrate(original), original)
    }

    func testBrowserAndHealthRequestUseSameTenantHostWithoutNativeDNS() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        var project = fixture.legacyProject()
        project.hostname = "mirayoga.localhost"
        project.healthPath = "/packages"
        XCTAssertEqual(project.localURL?.absoluteString, "http://mirayoga.localhost:3100")
        XCTAssertEqual(project.localURL(port: 3102)?.absoluteString, "http://mirayoga.localhost:3102")
        XCTAssertEqual(project.healthURL?.absoluteString, "http://mirayoga.localhost:3100/packages")
        let request = try XCTUnwrap(HealthChecker.request(for: project))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:3100/packages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "mirayoga.localhost:3100")
        XCTAssertEqual(request.httpMethod, "HEAD")
        project.hostname = "::1"
        XCTAssertEqual(project.localURL?.absoluteString, "http://[::1]:3100")
        XCTAssertEqual(HealthChecker.request(for: project)?.value(forHTTPHeaderField: "Host"), "[::1]:3100")
    }

    func testOnlyLocalHostnamesAreAccepted() {
        XCTAssertEqual(LocalHostname.normalize(" MiraYoga.Localhost "), "mirayoga.localhost")
        for host in ["https://mirayoga.localhost", "mirayoga.localhost:3100", "example.com", "a..localhost", "-a.localhost", "*.localhost", "localhost/path"] {
            XCTAssertNil(LocalHostname.normalize(host), host)
        }
    }

    @MainActor
    func testRealHealthCheckSendsTheCustomerHostToLoopbackServer() async throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        try fixture.write("host-server.py", """
        from http.server import HTTPServer, BaseHTTPRequestHandler
        class Handler(BaseHTTPRequestHandler):
            def do_HEAD(self):
                expected = 'mirayoga.localhost:' + str(self.server.server_port)
                self.send_response(200 if self.headers.get('Host') == expected and self.path == '/health?probe=1' else 404)
                self.end_headers()
        server = HTTPServer(('127.0.0.1', 0), Handler)
        print('SERVER_PORT:' + str(server.server_port), flush=True)
        server.serve_forever()
        """)
        let suite = "WorkspaceHTTPTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProjectProcessManager(userDefaults: defaults, storageDirectoryURL: fixture.root.appendingPathComponent("logs"))
        var project = fixture.legacyProject()
        project.commandTemplate = "/usr/bin/python3 -u host-server.py"
        project.hostname = "mirayoga.localhost"
        project.healthPath = "/health?probe=1"
        try manager.start(project: project)
        defer { manager.stopAll() }
        let deadline = Date().addingTimeInterval(5)
        var port: Int?
        while port == nil, Date() < deadline {
            port = manager.logLines(for: project.id).first { $0.hasPrefix("SERVER_PORT:") }
                .flatMap { Int($0.dropFirst("SERVER_PORT:".count)) }
            if port == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        project.port = try XCTUnwrap(port)
        let result = await HealthChecker().check(project)
        guard case .healthy(code: 200, milliseconds: _) = result else {
            XCTFail("Expected a healthy response from the customer Host, got \(result)")
            return
        }
    }

    func testOldSavedProjectsDefaultToLocalhostAndNewSettingsRoundTrip() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var project = fixture.legacyProject()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(project)) as? [String: Any])
        json.removeValue(forKey: "hostname")
        json.removeValue(forKey: "workspaceRootPath")
        let old = try decoder.decode(LocalProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.hostname, "localhost")
        XCTAssertNil(old.workspaceRootPath)
        project.hostname = "mirayoga.localhost"
        project.workspaceRootPath = fixture.root.path
        XCTAssertEqual(try decoder.decode(LocalProject.self, from: encoder.encode(project)), project)
    }

    func testHoistedNodeModulesDoNotProduceAMissingDependenciesWarning() async throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        let project = ProjectLaunchMigration.migrate(fixture.legacyProject())
        let result = await PreflightChecker().check(project)
        XCTAssertFalse(result.issues.contains { $0.message == "node_modules missing" })
    }

    @MainActor
    func testImportAndRefreshKeepSeparateAppsAndAvoidDuplicates() async throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        let suite = "WorkspaceLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("store"))
        let model = LocalMonitorModel(store: store,
                                      notificationService: NotificationService(isEnabled: { false }),
                                      userDefaults: defaults)
        await model.addProject(folderURL: fixture.root)
        XCTAssertEqual(model.projects.count, 2)
        XCTAssertEqual(model.projects.map(\.name), ["meetcase-sites", "meetcase-sites"])
        XCTAssertEqual(model.projects.map(\.profileName), ["mirayoga", "theme-preview"])
        XCTAssertEqual(model.projects.map(\.hostname), ["mirayoga.localhost", "localhost"])
        XCTAssertEqual(Set(model.projects.map(\.path)).count, 2)
        await model.addProject(folderURL: fixture.root)
        XCTAssertEqual(model.projects.count, 2)
        assertSavedLaunchProfiles(store.load().projects, match: model.projects)
    }

    @MainActor
    func testSavedRootEntryMigratesOnLoadingTheLibrary() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        let suite = "WorkspaceMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("store"))
        let original = fixture.legacyProject()
        store.save(ProjectLibrary(projects: [original]))
        let model = LocalMonitorModel(store: store, userDefaults: defaults)
        XCTAssertEqual(model.projects.first?.id, original.id)
        XCTAssertEqual(model.projects.first?.hostname, "mirayoga.localhost")
        assertSavedLaunchProfiles(store.load().projects, match: model.projects)
    }

    private func assertSavedLaunchProfiles(_ saved: [LocalProject], match projects: [LocalProject]) {
        // The store's ISO-8601 format rounds timestamps to seconds. Compare the
        // launch settings this regression protects without fractional dates.
        XCTAssertEqual(saved.map(\.id), projects.map(\.id))
        XCTAssertEqual(saved.map(\.name), projects.map(\.name))
        XCTAssertEqual(saved.map(\.profileName), projects.map(\.profileName))
        XCTAssertEqual(saved.map(\.path), projects.map(\.path))
        XCTAssertEqual(saved.map(\.port), projects.map(\.port))
        XCTAssertEqual(saved.map(\.commandTemplate), projects.map(\.commandTemplate))
        XCTAssertEqual(saved.map(\.hostname), projects.map(\.hostname))
        XCTAssertEqual(saved.map(\.workspaceRootPath), projects.map(\.workspaceRootPath))
    }

    @MainActor
    func testNpmGetsPortArgumentsFromAppDirectoryWithoutRootWrapper() async throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        try fixture.write("node_modules/.bin/next", "#!/bin/sh\nprintf 'ARG:%s\\n' \"$@\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fixture.root.appendingPathComponent("node_modules/.bin/next").path)
        let suite = "WorkspaceProcessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProjectProcessManager(userDefaults: defaults, storageDirectoryURL: fixture.root.appendingPathComponent("logs"))
        let project = ProjectLaunchMigration.migrate(fixture.legacyProject())
        try manager.start(project: project)
        defer { manager.stopAll() }
        let deadline = Date().addingTimeInterval(8)
        while manager.isRunning(projectId: project.id), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let args = manager.logLines(for: project.id).filter { $0.hasPrefix("ARG:") }
        XCTAssertEqual(args, ["ARG:dev", "ARG:--port", "ARG:3100", "ARG:-p", "ARG:3100"])
    }

    @MainActor
    func testManagedLauncherSupportsEnvironmentAssignments() async throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        let suite = "WorkspaceEnvironmentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProjectProcessManager(userDefaults: defaults, storageDirectoryURL: fixture.root.appendingPathComponent("logs"))
        var project = fixture.legacyProject()
        project.commandTemplate = "PORT={port} /bin/sh -c 'echo ENV_PORT:$PORT'"
        try manager.start(project: project)
        defer { manager.stopAll() }
        let deadline = Date().addingTimeInterval(5)
        while manager.isRunning(projectId: project.id), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(manager.logLines(for: project.id).contains("ENV_PORT:3100"))
    }
}

private struct WorkspaceLaunchFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceLaunch-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try write("package.json", #"{"name":"meetcase-sites","workspaces":["apps/*","packages/*"],"scripts":{"dev":"npm run dev --workspace=@meetcase-site/mirayoga"},"dependencies":{"next":"16.3.8"}}"#)
        try write("package-lock.json", "{}")
        try write("apps/mirayoga/package.json", #"{"name":"@meetcase-site/mirayoga","scripts":{"dev":"next dev --port 3100"},"dependencies":{"next":"16.3.8"}}"#)
        try write("apps/mirayoga/next.config.ts", #"export default { allowedDevOrigins: ["mirayoga.localhost"] }"#)
        try write("apps/theme-preview/package.json", #"{"name":"@meetcase-site/theme-preview","scripts":{"dev":"next dev --port 3101"},"dependencies":{"next":"16.3.8"}}"#)
        try write("apps/theme-preview/next.config.ts", #"export default { allowedDevOrigins: ["luma.localhost", "ritim.localhost"] }"#)
        try write("packages/core/package.json", #"{"name":"core","scripts":{"build":"tsc"}}"#)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    }

    func legacyProject() -> LocalProject {
        LocalProject(name: "meetcase-sites", path: root.path, kind: .nextjs, packageManager: .npm,
                     port: 3100, commandTemplate: "npm run dev -- -p {port}", openAfterStart: false)
    }

    func write(_ path: String, _ value: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
