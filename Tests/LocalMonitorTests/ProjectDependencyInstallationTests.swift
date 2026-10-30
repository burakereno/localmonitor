import Foundation
import Testing
@testable import LocalMonitor

struct ProjectDependencyInstallationTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "remove", "caller"]) @MainActor func cancelledInstallDoesNotRestoreRemovedProjectState(_ action: String) async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let node = try fixture.node()
        try fixture.write(".node-version", "24\n")
        try fixture.write("package.json", #"{"packageManager":"npm@10.9.8"}"#)
        try fixture.write("tools/npm", """
        #!/bin/sh
        if [ "$1" = '--version' ]; then echo 10.9.8; else /usr/bin/touch installing; /bin/sleep 30; fi

        """, executable: true)
        let suite = "CancelledInstall-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let project = fixture.project()
        let store = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("projects"))
        store.save(.init(projects: [project]))
        let checker = PreflightChecker(nodeRuntimeResolver: .init(candidateDirectories: [node.executable.deletingLastPathComponent()]),
            packageRuntimeResolver: .init(shimRoot: fixture.root.appendingPathComponent("shims"),
                candidateDirectories: [node.executable.deletingLastPathComponent()], allowCorepack: false))
        let manager = ProjectProcessManager(userDefaults: defaults, storageDirectoryURL: fixture.root.appendingPathComponent("logs"))
        let model = LocalMonitorModel(store: store, preflightChecker: checker, processManager: manager, userDefaults: defaults)
        model.dependencyInstallation.storageRoot = fixture.root.appendingPathComponent("records")
        defer { model.stopAllProjects() }
        let install = Task { await model.installDependencies(for: project) }
        let marker = fixture.root.appendingPathComponent("installing")
        // Runtime discovery launches several probes; busy CI hosts can take more than four seconds.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while !FileManager.default.fileExists(atPath: marker.path), clock.now < deadline {
            if let state = model.installationStates[project.id], state != .running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: marker.path),
                     "Fixture installer did not start; state: \(String(describing: model.installationStates[project.id]))")
        if action == "remove" { model.removeProject(project) }
        else if action == "caller" { install.cancel() }
        else { model.cancelInstallation(for: project) }
        await install.value
        #expect(model.installationTasks.isEmpty)
        if action == "remove" {
            #expect(model.installationStates[project.id] == nil)
            #expect(model.runtimeStates[project.id] == nil)
        } else { #expect(model.installationStates[project.id] == .cancelled) }
    }

    @Test func siblingReinstallationInvalidatesTheSharedNodeRuntime() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write("package.json", #"{"workspaces":["apps/*"]}"#)
        try fixture.write("apps/one/package.json", "{}")
        try fixture.write("apps/two/package.json", "{}")
        try fixture.write("node_modules/.keep", "")
        var one = fixture.project(), two = fixture.project()
        one.path = fixture.root.appendingPathComponent("apps/one").path
        two.path = fixture.root.appendingPathComponent("apps/two").path
        let store = ProjectDependencyInstallation(storageRoot: fixture.root.appendingPathComponent("records"))
        let first = ProjectLaunchEnvironment(node: nil, package: nil, observedNode: try NodeVersion("24.21.0"))
        let second = ProjectLaunchEnvironment(node: nil, package: nil, observedNode: try NodeVersion("22.23.2"))
        try store.recordSuccess(one, environment: first, fingerprint: store.fingerprint(one))
        try store.recordSuccess(two, environment: second, fingerprint: store.fingerprint(two))
        #expect(try store.issues(for: one, environment: first).contains { $0.message.contains("native packages") })
    }

    @Test func tracksLockfileChangesAndNodeMajorWithoutGuessingExistingInstalls() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write("package.json", "{}")
        try fixture.write("package-lock.json", "initial")
        try fixture.write("node_modules/.keep", "")
        let project = fixture.project()
        let store = ProjectDependencyInstallation(storageRoot: fixture.root.appendingPathComponent("records"))
        let environment = ProjectLaunchEnvironment(node: try fixture.node("22.23.2"), package: nil)
        #expect(try store.issues(for: project, environment: environment).first?.severity == .info)
        try store.recordSuccess(project, environment: environment, fingerprint: store.fingerprint(project))
        #expect(try store.issues(for: project, environment: environment).isEmpty)
        let changedNode = ProjectLaunchEnvironment(node: try fixture.node("24.21.0"), package: nil)
        #expect(try store.issues(for: project, environment: changedNode).contains { $0.message.contains("native packages") })
        let unpinned = ProjectLaunchEnvironment(node: nil, package: nil, observedNode: try NodeVersion("24.21.0"))
        #expect(try store.issues(for: project, environment: unpinned).contains { $0.message.contains("native packages") })
        try fixture.write("package-lock.json", "branch-changed-lock")
        #expect(try store.issues(for: project, environment: environment).contains { $0.message.contains("lockfile changed") })
        #expect(throws: ProjectReliabilityError.self) { try store.recordSuccess(project, environment: environment, fingerprint: "stale") }
    }

    @Test(arguments: [(PackageManager.npm, "package-lock.json", "npm ci"), (.pnpm, "pnpm-lock.yaml", "pnpm install --frozen-lockfile"),
                      (.bun, "bun.lock", "bun install --frozen-lockfile"), (.yarn, "yarn.lock", "yarn install --immutable")])
    func usesFrozenLockfileCommands(_ input: (PackageManager, String, String)) throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(input.1, "fixture")
        let environment = ProjectLaunchEnvironment(node: nil, package: ProjectPackageRuntime(manager: input.0, version: "4.0.0", shimDirectory: fixture.root))
        #expect(ProjectDependencyInstallation().installCommand(for: fixture.project(manager: input.0), environment: environment) == input.2)
    }

    @Test func pnpmAppsUseTheWorkspaceLockfileAndSharedDependencies() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write("package.json", #"{"packageManager":"pnpm@9.15.0"}"#)
        try fixture.write("pnpm-workspace.yaml", "packages:\n  - apps/*\n")
        try fixture.write("pnpm-lock.yaml", "initial-lock")
        try fixture.write("apps/web/package.json", "{}")
        try fixture.write("node_modules/.keep", "")
        var project = fixture.project(manager: .pnpm)
        project.path = fixture.root.appendingPathComponent("apps/web").path
        let store = ProjectDependencyInstallation(storageRoot: fixture.root.appendingPathComponent("records"))
        #expect(store.folder(for: project).standardizedFileURL.path == fixture.root.standardizedFileURL.path)
        #expect(ProjectWorkspace.dependencyDirectory(in: project.folderURL) == fixture.root.appendingPathComponent("node_modules"))
        let before = try store.fingerprint(project)
        try fixture.write("pnpm-lock.yaml", "changed-workspace-lock")
        #expect(try store.fingerprint(project) != before)
    }

    @Test(arguments: [false, true]) @MainActor func explicitInstallUsesThePreparedToolsAndRecordsSuccess(_ nested: Bool) async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let node = try fixture.node()
        try fixture.write(".node-version", "24.21.0\n")
        try fixture.write("package.json", #"{"packageManager":"npm@10.9.8","workspaces":["apps/*"]}"#)
        try fixture.write("package-lock.json", "fixture-lock")
        try fixture.write("tools/npm", """
        #!/bin/sh
        if [ "$1" = '--version' ]; then echo 10.9.8; else /bin/mkdir -p node_modules; /usr/bin/touch install-ran; fi

        """, executable: true)
        let package = ProjectPackageRuntimeResolver(shimRoot: fixture.root.appendingPathComponent("shims"),
                                                    candidateDirectories: [node.executable.deletingLastPathComponent()], allowCorepack: false)
        let store = ProjectDependencyInstallation(storageRoot: fixture.root.appendingPathComponent("records"))
        let checker = PreflightChecker(nodeRuntimeResolver: .init(candidateDirectories: [node.executable.deletingLastPathComponent()]),
                                       packageRuntimeResolver: package, dependencyInstallation: store)
        let suite = "InstallIntegration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var project = fixture.project()
        if nested {
            try fixture.write(".node-version", "22\n")
            try fixture.write("apps/web/.node-version", "24.21.0\n")
            try fixture.write("apps/web/package.json", "{}")
            project.path = fixture.root.appendingPathComponent("apps/web").path
        }
        let projectStore = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("projects"))
        projectStore.save(.init(projects: [project]))
        let model = LocalMonitorModel(store: projectStore, preflightChecker: checker, userDefaults: defaults)
        model.dependencyInstallation = store
        await model.installDependencies(for: project)
        #expect(model.installationStates.values.contains(.succeeded))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("install-ran").path))
        #expect(try store.issues(for: project, environment: .init(node: node, package: nil)).isEmpty)
    }

    @Test @MainActor func installationLocksProjectsSharingTheSameWorkspace() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write("package.json", #"{"workspaces":["apps/*"]}"#)
        try fixture.write("apps/one/package.json", "{}")
        try fixture.write("apps/two/package.json", "{}")
        try fixture.write("outside/package.json", "{}")
        var one = fixture.project(), two = fixture.project(), outside = fixture.project()
        let workspace = fixture.project()
        one.path = fixture.root.appendingPathComponent("apps/one").path
        two.path = fixture.root.appendingPathComponent("apps/two").path
        outside.path = fixture.root.appendingPathComponent("outside").path
        let store = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("projects"))
        store.save(.init(projects: [one, two, outside, workspace]))
        let suite = "InstallLock-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = LocalMonitorModel(store: store, userDefaults: defaults)
        model.installationTasks[one.id] = Task {}
        defer { model.installationTasks.removeAll() }
        #expect(model.isInstallingDependencies(for: one))
        #expect(model.isInstallingDependencies(for: two))
        #expect(model.isInstallingDependencies(for: workspace))
        #expect(model.isInstallingDependencies(for: outside) == false)
    }
}
