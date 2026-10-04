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

    func testRootApplicationIsRetainedAndNeverMigratesWithoutAnExplicitWorkspaceSelector() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        try fixture.write("package.json", #"{"name":"root-site","workspaces":["apps/*"],"scripts":{"dev":"next dev"},"dependencies":{"next":"16.3.8"}}"#)
        let profiles = ProjectDetector.launchProfiles(in: fixture.root)
        XCTAssertEqual(profiles.map(\.relativePath), [".", "apps/mirayoga", "apps/theme-preview"])
        let original = fixture.legacyProject()
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

    func testBrowserHostsAreLocalUniqueAndDoNotChangeTheDefaultHost() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        let app = fixture.root.appendingPathComponent("apps/theme-preview")
        try fixture.write("apps/theme-preview/next.config.ts", #"export default { allowedDevOrigins: ['ritim.localhost', 'Luma.Localhost', 'luma.localhost', '*.localhost', 'example.com', 'bad..localhost'] }"#)
        XCTAssertEqual(LocalHostname.detectedHosts(in: app), ["luma.localhost", "ritim.localhost"])
        XCTAssertEqual(LocalHostname.detect(in: app), "localhost")
        XCTAssertEqual(LocalHostname.detectedHosts(in: fixture.root.appendingPathComponent("apps/mirayoga")), ["mirayoga.localhost"])
    }

    func testWorkspaceSelectionExcludesSavedAppsAndRetainsTheirCustomSettings() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        let profiles = ProjectDetector.launchProfiles(in: fixture.root)
        var saved = ProjectLaunchMigration.migrate(fixture.legacyProject())
        saved.port = 3300
        saved.hostname = "custom.localhost"
        saved.commandTemplate = "PORT={port} node launcher.mjs"
        // A saved alias of the same folder must also count as already added.
        let alias = fixture.root.appendingPathComponent("saved-mirayoga")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: saved.folderURL)
        saved.path = alias.path
        let workspace = WorkspaceImport(rootURL: fixture.root, profiles: profiles, savedProjects: [saved])
        XCTAssertEqual(workspace.availableProfiles.map(\.relativePath), ["apps/theme-preview"])
        let existing = try XCTUnwrap(workspace.savedProject(for: profiles[0]))
        XCTAssertEqual(existing.port, 3300)
        XCTAssertEqual(existing.hostname, "custom.localhost")
        XCTAssertEqual(existing.commandTemplate, "PORT={port} node launcher.mjs")
    }

    @MainActor
    func testBrowserShortcutsUseTheProfilePortAndPreserveItsDefaultHostname() throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        var project = fixture.legacyProject()
        project.path = fixture.root.appendingPathComponent("apps/theme-preview").path
        project.hostname = "catalog.localhost"
        project.port = 3201
        let suite = "WorkspaceBrowserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("store"))
        store.save(ProjectLibrary(projects: [project]))
        let model = LocalMonitorModel(store: store, userDefaults: defaults)
        XCTAssertEqual(model.browserHostnames(for: project), ["catalog.localhost", "luma.localhost", "ritim.localhost"])
        XCTAssertEqual(model.browserURL(for: project, hostname: "luma.localhost")?.absoluteString, "http://luma.localhost:3201")
        XCTAssertNil(model.browserURL(for: project, hostname: "example.com"))
        XCTAssertNil(model.browserURL(for: project, hostname: "unknown.localhost"))
        XCTAssertEqual(model.projects.first?.hostname, "catalog.localhost")
    }

    @MainActor
    func testAddingAnAlreadyRunningSiblingKeepsItsPortAndProcessWithoutChangingTheSavedApp() async throws {
        let fixture = try WorkspaceLaunchFixture()
        defer { fixture.cleanup() }
        let app = fixture.root.appendingPathComponent("apps/theme-preview")
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        external.currentDirectoryURL = app
        external.arguments = ["-u", "-c", """
        import socket, time
        from pathlib import Path
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        Path('listener-port').write_text(str(listener.getsockname()[1]))
        time.sleep(60)
        """]
        external.standardOutput = Pipe()
        external.standardError = Pipe()
        try external.run()
        defer {
            if external.isRunning { external.terminate() }
            external.waitUntilExit()
        }
        let originalPID = external.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        var port: Int?
        while port == nil, Date() < deadline, external.isRunning {
            port = (try? String(contentsOf: app.appendingPathComponent("listener-port"), encoding: .utf8)).flatMap { Int($0) }
            if port == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let runningPort = try XCTUnwrap(port)
        try fixture.write("apps/theme-preview/package.json", """
        {"name":"@meetcase-site/theme-preview","scripts":{"dev":"next dev --port \(runningPort)"},"dependencies":{"next":"16.3.8"}}
        """)
        let savedScanning = UserDefaults.standard.object(forKey: AppPreference.scanExternalPortsKey)
        UserDefaults.standard.set(true, forKey: AppPreference.scanExternalPortsKey)
        defer {
            if let savedScanning { UserDefaults.standard.set(savedScanning, forKey: AppPreference.scanExternalPortsKey) }
            else { UserDefaults.standard.removeObject(forKey: AppPreference.scanExternalPortsKey) }
        }
        var mira = ProjectLaunchMigration.migrate(fixture.legacyProject())
        mira.port = 3300
        mira.commandTemplate = "PORT={port} node custom.mjs"
        let suite = "WorkspaceLiveImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("store"))
        store.save(ProjectLibrary(projects: [mira]))
        let model = LocalMonitorModel(store: store, healthChecksEnabled: false,
                                      notificationService: NotificationService(isEnabled: { false }), userDefaults: defaults)
        let savedMira = try XCTUnwrap(model.projects.first)
        // No refresh before import: the import itself must discover the listener.
        let profiles = ProjectDetector.launchProfiles(in: fixture.root)
        await model.addWorkspaceProfiles(profiles, rootURL: fixture.root)
        let theme = try XCTUnwrap(model.projects.first { $0.profileName == "theme-preview" })
        XCTAssertEqual(theme.port, runningPort)
        XCTAssertEqual(model.runtimeState(for: theme).pid, originalPID)
        XCTAssertEqual(model.runtimeState(for: theme).ownership, .external)
        XCTAssertEqual(model.projects.first { $0.id == mira.id }, savedMira)
        await model.startProject(theme, recordsUsage: false)
        XCTAssertTrue(external.isRunning)
        XCTAssertEqual(model.runtimeState(for: theme).pid, originalPID)
        await model.addWorkspaceProfiles(profiles, rootURL: fixture.root)
        XCTAssertEqual(model.projects.count, 2)
        XCTAssertTrue(external.isRunning)
        XCTAssertEqual(model.browserURL(for: theme, hostname: "luma.localhost")?.port, runningPort)
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
