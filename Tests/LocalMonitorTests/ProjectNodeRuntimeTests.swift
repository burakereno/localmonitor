import Foundation
import Testing
@testable import LocalMonitor

struct ProjectNodeRuntimeTests {
    @Test(arguments: [
        ("26.8.2", "26.8.2", true), ("26.8.2", "26.8.3", false),
        ("v22.23", "22.23.4", true), ("24", "26.8.2", false),
        ("24.x", "24.21.0", true), ("24.*", "25.0.0", false),
        (">=22.23.4", "22.23.2", false), (">=22.23.4", "24.21.0", true),
        (">=22.18.0 <25", "26.8.2", false), (">=22.18.0 <25", "24.21.0", true),
        ("^22.23.2", "24.21.0", false), ("^22.23.2", "22.23.4", true),
        ("^0.2.3", "0.3.0", false), ("^0.0.3", "0.0.4", false),
        ("^0.0", "0.0.4", true), ("~22.23.2", "22.24.0", false),
        ("~24", "24.21.0", true), ("22.0 - 24.21", "24.21.1", true),
        ("22 - 24", "25.0.0", false), ("22.1.0 - 24.21.0", "24.21.1", false),
        ("^22 || >= 24.21.0 < 25", "24.21.0", true),
        (">22", "22.23.4", false), (">22.23", "22.24.0", true),
        ("<=22", "22.23.4", true), ("*", "26.8.2", true),
        (">*", "26.8.2", false), ("<=*", "26.8.2", true)
    ])
    func stableSemverRanges(_ value: (String, String, Bool)) throws {
        let range = try NodeVersionRange(value.0)
        #expect(range.contains(try NodeVersion(value.1)) == value.2)
    }

    @Test(arguments: ["", "24 ||", "24.1.2.3", "22.x.3", ">=>22", "26.0.0-rc.1", "$(touch bad)"])
    func rejectsUnsupportedDeclarations(_ value: String) {
        #expect(throws: NodeRuntimeError.self) { try NodeVersionRange(value) }
    }

    @Test func inheritsPinsButLocalPinsOverrideAncestorsAndEngines() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        try fixture.write(".node-version", "22.23.2\n")
        try fixture.write("apps/site/package.json", #"{"engines":{"node":">=24 <25"}}"#)
        let child = fixture.root.appendingPathComponent("apps/site")
        #expect(try ProjectNodeRequirement.read(in: child)?.selector == "22.23.2")
        try fixture.write("apps/site/.nvmrc", "# site runtime\n  24 # LTS\n")
        #expect(try ProjectNodeRequirement.read(in: child)?.selector == "24")
    }

    @Test func supportsVoltaAndNearestEngineFallback() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        try fixture.write("package.json", #"{"engines":{"node":">=22"}}"#)
        try fixture.write("apps/site/package.json", #"{"engines":{"node":">=24 <25"}}"#)
        let child = fixture.root.appendingPathComponent("apps/site")
        #expect(try ProjectNodeRequirement.read(in: child)?.selector == ">=24 <25")
        try fixture.write("apps/site/package.json", #"{"volta":{"node":"24.21.0"},"engines":{"node":">=22"}}"#)
        #expect(try ProjectNodeRequirement.read(in: child)?.selector == "24.21.0")
    }

    @Test func selectsInstalledPatchAndRespectsExactPinsAndUpperBounds() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let bins = try ["22.23.2", "24.21.0", "26.8.2"].map { try fixture.runtime($0) }
        let resolver = ProjectNodeRuntimeResolver(candidateDirectories: bins)
        try fixture.write("package.json", #"{"engines":{"node":">=22.23.4 <25"}}"#)
        #expect(try await resolver.resolve(in: fixture.root)?.version.description == "24.21.0")
        try fixture.write(".node-version", "26.8.2\n")
        #expect(try await resolver.resolve(in: fixture.root)?.version.description == "26.8.2")
    }

    @Test func failsClearlyInsteadOfLaunchingAnIncompatibleRuntime() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        try fixture.write(".node-version", "22.23.4\n")
        let resolver = ProjectNodeRuntimeResolver(candidateDirectories: [try fixture.runtime("22.23.2")])
        do {
            _ = try await resolver.resolve(in: fixture.root)
            Issue.record("An older installed patch must not satisfy an exact project pin.")
        } catch {
            #expect(error.localizedDescription.contains("22.23.4"))
            #expect(error.localizedDescription.contains("Install a matching version"))
        }
        let project = fixture.project()
        let preflight = await PreflightChecker(nodeRuntimeResolver: resolver).check(project)
        #expect(preflight.isClear == false)
        #expect(preflight.summary.contains("22.23.4"))
    }

    @Test func managerShimsResolveToTheActualInstallation() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        try fixture.write(".node-version", "24\n")
        let bin = try fixture.runtime("24.21.0")
        try fixture.write("shims/node", "#!/bin/sh\nexec \(ProjectNodeRuntime.quote(bin.appendingPathComponent("node").path)) \"$@\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.appendingPathComponent("shims/node").path)
        let resolver = ProjectNodeRuntimeResolver(candidateDirectories: [fixture.root.appendingPathComponent("shims")])
        let runtime = try #require(await resolver.resolve(in: fixture.root))
        #expect(runtime.executable == bin.appendingPathComponent("node"))
    }

    @Test func projectsWithoutDeclarationsKeepTheirExistingEnvironment() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let resolver = ProjectNodeRuntimeResolver(candidateDirectories: [])
        #expect(try await resolver.resolve(in: fixture.root) == nil)
        try fixture.write(".nvmrc", "# empty declaration\n")
        #expect(throws: NodeRuntimeError.self) { try ProjectNodeRequirement.read(in: fixture.root) }
    }

    @Test @MainActor func managedLaunchUsesSelectedNodeAndPreservesCompoundCommands() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        try fixture.write(".node-version", "24\n")
        let resolver = ProjectNodeRuntimeResolver(candidateDirectories: [try fixture.runtime("24.21.0")])
        let suite = "NodeRuntimeLaunch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProjectProcessManager(userDefaults: defaults,
                                            storageDirectoryURL: fixture.root.appendingPathComponent("logs"),
                                            nodeRuntimeResolver: resolver)
        var project = fixture.project()
        project.commandTemplate = "npm --version; LM_NODE_TEST={port} /bin/sh -c 'echo PORT:$LM_NODE_TEST'"
        try await manager.start(project: project)
        defer { manager.stopAll() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, manager.logLines(for: project.id).contains("PORT:54321") == false {
            try await Task.sleep(for: .milliseconds(50))
        }
        let logs = manager.logLines(for: project.id)
        #expect(logs.contains("v24.21.0"))
        #expect(logs.contains("PORT:54321"))
        #expect(logs.contains { $0.contains("[Local Monitor] Node.js 24.21.0") })
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("should-not-exist").path) == false)
    }

    @Test func concurrentProjectsChooseTheirOwnVersionsWithoutChangingDefaults() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        let resolver = ProjectNodeRuntimeResolver(candidateDirectories: try ["22.23.2", "24.21.0"].map { try fixture.runtime($0) })
        try fixture.write("one/.node-version", "22\n")
        try fixture.write("two/.node-version", "24\n")
        let path = ProcessInfo.processInfo.environment["PATH"]
        async let one = resolver.resolve(in: fixture.root.appendingPathComponent("one"))
        async let two = resolver.resolve(in: fixture.root.appendingPathComponent("two"))
        #expect(try await one?.version.description == "22.23.2")
        #expect(try await two?.version.description == "24.21.0")
        #expect(ProcessInfo.processInfo.environment["PATH"] == path)
    }

    @Test @MainActor func stopCancelsRuntimeDiscoveryBeforeAServerIsSpawned() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.cleanup() }
        try fixture.write(".node-version", "24\n")
        let bin = try fixture.runtime("24.21.0", probeDelay: 0.3)
        let suite = "NodeRuntimeStop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProjectProcessManager(userDefaults: defaults,
                                            storageDirectoryURL: fixture.root.appendingPathComponent("logs"),
                                            nodeRuntimeResolver: ProjectNodeRuntimeResolver(candidateDirectories: [bin]))
        let project = fixture.project()
        let launch = Task { try await manager.start(project: project) }
        let deadline = Date().addingTimeInterval(3)
        while manager.isStarting(projectId: project.id) == false, Date() < deadline {
            await Task.yield()
        }
        #expect(manager.isStarting(projectId: project.id))
        #expect(manager.stop(projectId: project.id))
        do {
            try await launch.value
            Issue.record("A stopped pending launch must be cancelled.")
        } catch is CancellationError {
            #expect(manager.rootPID(for: project.id) == nil)
        }
        #expect(manager.isRunning(projectId: project.id) == false)
    }
}

private struct RuntimeFixture {
    // Quotes and shell metacharacters in actual executable paths exercise launch escaping.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NodeRuntime-'$(touch should-not-exist)-\(UUID().uuidString)")
        .standardizedFileURL.resolvingSymlinksInPath()

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func runtime(_ version: String, probeDelay: Double = 0) throws -> URL {
        let bin = root.appendingPathComponent("runtimes/\(version)/bin")
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "executable": bin.appendingPathComponent("node").path])
        let info = try #require(String(data: data, encoding: .utf8))
        let pause = probeDelay > 0 ? "/bin/sleep \(probeDelay)\n" : ""
        try write("runtimes/\(version)/bin/node", """
        #!/bin/sh
        if [ "$1" = '-p' ]; then
          \(pause)printf '%s\\n' \(ProjectNodeRuntime.quote(info))
        else
          printf '%s\\n' 'v\(version)'
        fi

        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("node").path)
        try write("runtimes/\(version)/bin/npm", "#!/bin/sh\nexec node --version\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("npm").path)
        return bin
    }

    func project() -> LocalProject {
        LocalProject(name: "node-fixture", path: root.path, kind: .supabase, packageManager: .npm,
                     port: 54_321, commandTemplate: "node --version", openAfterStart: false)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
