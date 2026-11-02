import Foundation
import Testing
@testable import LocalMonitor

struct ProjectNodeInstallerTests {
    private let index = Data(#"[{"version":"v26.8.2","lts":false},{"version":"v24.18.0","lts":"Krypton"},{"version":"v24.21.0","lts":"Krypton"},{"version":"v22.23.2","lts":"Jod"},{"version":"v27.0.0-rc.1","lts":false}]"#.utf8)

    @Test(arguments: [
        ("24.18.0", "24.18.0"), (">=24 <25", "24.21.0"), ("^22.23.0", "22.23.2"),
        ("24.x", "24.21.0"), ("lts/*", "24.21.0"), ("lts/jod", "22.23.2"), ("node", "26.8.2")
    ])
    func selectsHighestMatchingStableRelease(_ value: (String, String)) throws {
        let requirement = ProjectNodeRequirement(selector: value.0, source: URL(fileURLWithPath: "/fixture/.nvmrc"), allowsAliases: true)
        #expect(try ProjectNodeInstaller().selectVersion(for: requirement, index: index).description == value.1)
    }

    @Test(arguments: [">=30", "$(touch injected)", "lts/unknown", "default"])
    func rejectsUnpublishedVersionsAndUnresolvableAliases(_ selector: String) {
        let requirement = ProjectNodeRequirement(selector: selector, source: URL(fileURLWithPath: "/fixture/.nvmrc"), allowsAliases: true)
        #expect(throws: (any Error).self) { try ProjectNodeInstaller().selectVersion(for: requirement, index: index) }
    }

    @Test func preflightOffersRecoveryOnlyForMissingRuntimes() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        var project = fixture.project(); project.kind = .supabase
        try fixture.write(".nvmrc", "24.18.0\n")
        let checker = PreflightChecker(nodeRuntimeResolver: .init(candidateDirectories: []))
        let missing = await checker.check(project)
        #expect(missing.isClear == false)
        #expect(missing.missingNodeRequirement?.selector == "24.18.0")
        #expect(missing.missingNodeRequirement?.source.lastPathComponent == ".nvmrc")
        try fixture.write(".nvmrc", "$(touch injected)\n")
        let invalid = await checker.check(project)
        #expect(invalid.isClear == false)
        #expect(invalid.missingNodeRequirement == nil)
    }

    @Test func exactPinSkipsReleaseIndexAndRequiresVerifiedRuntime() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(".nvmrc", "24.18.0\n")
        let requirement = try #require(try ProjectNodeRequirement.read(in: fixture.root))
        let installer = ProjectNodeInstaller(loadReleaseIndex: {
            Issue.record("An exact pin should not fetch the release index.")
            return Data()
        }, execute: { _, _ in ShellResult(status: 0, stdout: "Success", stderr: "") })
        do {
            _ = try await installer.install(requirement, in: fixture.root, resolver: .init(candidateDirectories: []))
            Issue.record("A zero installer exit status must not certify a missing runtime.")
        } catch NodeRuntimeError.unavailable {
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("tools/node").path) == false)
        }
    }

    @Test func doesNotInstallAfterThePinChanges() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(".nvmrc", "24.18.0\n")
        let requirement = try #require(try ProjectNodeRequirement.read(in: fixture.root))
        try fixture.write(".nvmrc", "22\n")
        let installer = ProjectNodeInstaller(execute: { _, _ in
            Issue.record("A stale requirement must never trigger installation.")
            return ShellResult(status: 0, stdout: "", stderr: "")
        })
        await #expect(throws: ProjectReliabilityError.self) {
            try await installer.install(requirement, in: fixture.root, resolver: .init(candidateDirectories: []))
        }
    }

    @Test func existingCompatibleRuntimeSkipsDownload() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(".nvmrc", "24\n")
        let node = try fixture.node()
        let requirement = try #require(try ProjectNodeRequirement.read(in: fixture.root))
        let installer = ProjectNodeInstaller(loadReleaseIndex: {
            Issue.record("Already-installed runtimes should not fetch releases."); return Data()
        }, execute: { _, _ in
            Issue.record("Already-installed runtimes should not be reinstalled.")
            return ShellResult(status: 0, stdout: "", stderr: "")
        })
        let runtime = try await installer.install(requirement, in: fixture.root,
            resolver: .init(candidateDirectories: [node.executable.deletingLastPathComponent()]))
        #expect(runtime.version == node.version)
    }

    @Test func fnmInstallationPassesExactVersionAndPropagatesFailures() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let command = """
        fnm() { printf '%s\\n' "$@"; return 42; }
        \(ProjectNodeInstaller.command(for: try NodeVersion("24.18.0")))
        """
        let result = try await Shell.run("/bin/zsh", arguments: ["-fc", command], directory: fixture.root)
        #expect(result.status == 42)
        #expect(result.stdout.split(separator: "\n").map(String.init) == ["install", "24.18.0", "--progress", "never"])
    }

    @Test func nvmInstallationRunsInTheChildShellAndPropagatesFailures() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let command = """
        nvm() { printf '%s\\n' "$@"; return 42; }
        \(ProjectNodeInstaller.command(for: try NodeVersion("24.18.0")))
        """
        let result = try await Shell.run("/bin/zsh", arguments: ["-fc", command], directory: fixture.root,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": fixture.root.path])
        #expect(result.status == 42)
        #expect(result.stdout.split(separator: "\n").map(String.init) == ["install", "24.18.0"])
    }
}
