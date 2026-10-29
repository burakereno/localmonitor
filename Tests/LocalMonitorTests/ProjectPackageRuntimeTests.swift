import Foundation
import Testing
@testable import LocalMonitor

struct ProjectPackageRuntimeTests {
    @Test func corepackShimCandidatesAreOfflineDuringProbeAndLaunch() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let node = try fixture.node()
        try fixture.write("package.json", #"{"packageManager":"pnpm@9.15.0"}"#)
        try fixture.write("tools/pnpm", """
        #!/bin/sh
        [ "$COREPACK_ENABLE_NETWORK" = '0' ] || exit 23
        [ "$COREPACK_ENABLE_AUTO_PIN" = '0' ] || exit 24
        echo 9.15.0

        """, executable: true)
        let resolver = ProjectPackageRuntimeResolver(shimRoot: fixture.root.appendingPathComponent("shims"),
            candidateDirectories: [fixture.root.appendingPathComponent("tools")], allowCorepack: false)
        let runtime = try #require(await resolver.resolve(fixture.project(manager: .pnpm), node: node))
        let result = try await Shell.run("/bin/sh", arguments: ["-c", ProjectNodeRuntime.quote(runtime.shimDirectory.appendingPathComponent("pnpm").path) + " run dev"])
        #expect(result.status == 0)
    }

    @Test func observesUnpinnedModernYarnWithoutNetworkOrGlobalPins() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let node = try fixture.node()
        try fixture.write(".node-version", "24\n")
        try fixture.write("package.json", "{}")
        try fixture.write("yarn.lock", "fixture-lock")
        try fixture.write("tools/yarn", """
        #!/bin/sh
        [ "$COREPACK_ENABLE_NETWORK" = '0' ] || exit 23
        echo 4.6.0

        """, executable: true)
        let project = fixture.project(manager: .yarn)
        let environment = try await ProjectLaunchEnvironment.prepare(project,
            nodeResolver: .init(candidateDirectories: [node.executable.deletingLastPathComponent()]))
        #expect(environment.observedPackageVersion == "4.6.0")
        #expect(ProjectDependencyInstallation().installCommand(for: project, environment: environment) == "yarn install --immutable")
    }

    @Test func readsExactPinsAndDevEnginesWithAncestorFallback() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write("package.json", #"{"packageManager":"pnpm@9.15.0+sha224.abcdef"}"#)
        try fixture.write("apps/web/package.json", "{}")
        let child = fixture.root.appendingPathComponent("apps/web")
        #expect(try ProjectPackageRequirement.read(in: child)?.manager == .pnpm)
        #expect(try ProjectPackageRequirement.read(in: child)?.range.contains(NodeVersion("9.15.0")) == true)
        try fixture.write("apps/web/package.json", #"{"devEngines":{"packageManager":{"name":"yarn","version":"^4.0.0"}}}"#)
        #expect(try ProjectPackageRequirement.read(in: child)?.manager == .yarn)
    }

    @Test func selectsPinnedManagerAndShimsNestedCommandsWithSelectedNode() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let node = try fixture.node()
        try fixture.write("package.json", #"{"packageManager":"pnpm@9.15.0"}"#)
        try fixture.write("tools/pnpm", "#!/bin/sh\nif [ \"$1\" = '--version' ]; then echo 9.15.0; else node --version; fi\n", executable: true)
        let resolver = ProjectPackageRuntimeResolver(shimRoot: fixture.root.appendingPathComponent("shims"),
                                                     candidateDirectories: [fixture.root.appendingPathComponent("tools")], allowCorepack: false)
        let project = fixture.project(manager: .pnpm)
        let manager = try #require(await resolver.resolve(project, node: node))
        let result = try await Shell.run("/bin/zsh", arguments: ["-lc", ProjectLaunchEnvironment(node: node, package: manager).command("/bin/sh -c 'pnpm run dev'")])
        #expect(result.status == 0)
        #expect(result.stdout.contains("v24.21.0"))
        #expect(manager.version == "9.15.0")
    }

    @Test func rejectsWrongManagerVersionAndSavedManagerMismatch() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write("package.json", #"{"packageManager":"pnpm@9.15.0"}"#)
        try fixture.write("tools/pnpm", "#!/bin/sh\necho 10.0.0\n", executable: true)
        let resolver = ProjectPackageRuntimeResolver(shimRoot: fixture.root.appendingPathComponent("shims"),
                                                     candidateDirectories: [fixture.root.appendingPathComponent("tools")], allowCorepack: false)
        await #expect(throws: ProjectReliabilityError.self) { try await resolver.resolve(fixture.project(manager: .pnpm), node: nil) }
        await #expect(throws: ProjectReliabilityError.self) { try await resolver.resolve(fixture.project(manager: .npm), node: nil) }
    }

    @Test func corepackStartupRemainsOfflineAndDoesNotPinGlobally() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let node = try fixture.node()
        try fixture.write("package.json", #"{"packageManager":"pnpm@9.15.0"}"#)
        try fixture.write("tools/corepack", """
        #!/bin/sh
        [ "$COREPACK_ENABLE_NETWORK" = '0' ] || exit 2
        [ "$COREPACK_ENABLE_AUTO_PIN" = '0' ] || exit 3
        [ "$1" = 'pnpm@9.15.0' ] || exit 4
        echo 9.15.0

        """, executable: true)
        let resolver = ProjectPackageRuntimeResolver(shimRoot: fixture.root.appendingPathComponent("shims"), candidateDirectories: [])
        let runtime = try #require(await resolver.resolve(fixture.project(manager: .pnpm), node: node))
        #expect(runtime.version == "9.15.0")
        #expect(try ProjectMetadata.package(at: fixture.root)?["packageManager"] as? String == "pnpm@9.15.0")
    }
}
