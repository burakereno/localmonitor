import Foundation
import Testing
@testable import LocalMonitor

struct ProjectEnvironmentTests {
    @Test func launchAssignmentsOverrideFilesWithoutExecutingComputedValues() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        var project = fixture.project()
        project.reliability.requiredEnvironmentKeys = ["API_KEY", "DATABASE_URL"]
        project.commandTemplate = "API_KEY='secret # value' DATABASE_URL=https://example.test npm run dev"
        #expect(try ProjectEnvironmentChecker().issues(for: project).isEmpty)
        project.commandTemplate = "API_KEY='' DATABASE_URL=ok npm run dev"
        #expect(try ProjectEnvironmentChecker().issues(for: project, shellPresence: ["API_KEY": true]).contains { $0.severity == .error })
        project.commandTemplate = "API_KEY=$(touch \(ProjectNodeRuntime.quote(fixture.root.appendingPathComponent("must-not-run").path))) DATABASE_URL=ok npm run dev"
        let issues = try ProjectEnvironmentChecker().issues(for: project)
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("computed") })
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("must-not-run").path))
        #expect(!issues.contains { $0.message.contains("secret # value") })
        #expect(ProjectEnvironmentChecker().commandAssignments("API_KEY=local; npm run dev").known.isEmpty)
        #expect(ProjectEnvironmentChecker().commandAssignments("export API_KEY=exported; npm run dev").known == ["API_KEY": true])
        #expect(ProjectEnvironmentChecker().commandAssignments("API_KEY=''\"\" npm run dev").known == ["API_KEY": false])
        #expect(ProjectEnvironmentChecker().commandAssignments("API_KEY='literal$VALUE' npm run dev").known == ["API_KEY": true])
        #expect(!issues.contains { $0.severity == .error })
    }

    @Test func wranglerEnvironmentFilesReplaceDevVarsAndExcludeDotEnv() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write("wrangler.toml", "name = 'fixture'")
        try fixture.write(".env", "API_KEY=dotenv\n")
        try fixture.write(".dev.vars", "API_KEY=base\n")
        try fixture.write(".dev.vars.staging", "OTHER_KEY=value\n")
        var project = fixture.project(); project.kind = .hono
        project.commandTemplate = "wrangler dev --env staging"
        project.reliability.requiredEnvironmentKeys = ["API_KEY"]
        #expect(ProjectEnvironmentChecker().files(for: project) == [".dev.vars.staging"])
        #expect(try ProjectEnvironmentChecker().issues(for: project).contains { $0.severity == .error })
        project.commandTemplate = "wrangler dev"
        #expect(ProjectEnvironmentChecker().files(for: project) == [".dev.vars"])
        #expect(try ProjectEnvironmentChecker().issues(for: project).isEmpty)
    }

    @Test func respectsNextAndViteFilePrecedenceAndEmptyOverrides() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(".env", "DATABASE_URL=base-secret\n")
        try fixture.write(".env.local", "DATABASE_URL=local-secret\n")
        try fixture.write(".env.production", "DATABASE_URL=\n")
        var project = fixture.project()
        project.reliability.environmentMode = "production"
        project.reliability.requiredEnvironmentKeys = ["DATABASE_URL"]
        project.kind = .nextjs
        #expect(try ProjectEnvironmentChecker().issues(for: project).isEmpty)
        project.kind = .vite
        let issues = try ProjectEnvironmentChecker().issues(for: project)
        #expect(issues.contains { $0.severity == .error && $0.message.contains("DATABASE_URL") })
        #expect(issues.allSatisfy { !$0.message.contains("secret") })
        project.kind = .nextjs
        #expect(try ProjectEnvironmentChecker().issues(for: project, shellPresence: ["DATABASE_URL": false]).isEmpty == false)
    }

    @Test func exampleKeysAreInformationalButExplicitKeysBlockWithoutLeakingValues() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(".env.example", "API_KEY=do-not-copy-value\nOPTIONAL=\n")
        var project = fixture.project()
        let inferred = try ProjectEnvironmentChecker().issues(for: project)
        #expect(!inferred.isEmpty)
        #expect(inferred.allSatisfy { $0.severity == .info })
        #expect(PreflightResult(issues: inferred).isClear)
        project.reliability.requiredEnvironmentKeys = ["API_KEY"]
        let explicit = try ProjectEnvironmentChecker().issues(for: project)
        #expect(explicit.contains { $0.severity == .error })
        #expect(!PreflightResult(issues: explicit).isClear)
        #expect(explicit.allSatisfy { !$0.message.contains("do-not-copy-value") })
    }

    @Test func readsOnlyPresenceFromTheActualLoginShell() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        var project = fixture.project()
        project.reliability.requiredEnvironmentKeys = ["PATH"]
        let values = try await ProjectEnvironmentChecker().shellPresence(for: project)
        #expect(values == ["PATH": true])
    }

    @Test func parsesQuotedExportedValuesAndDoesNotTreatCommentsAsKeys() {
        let values = ProjectEnvironmentChecker().presence(in: "# IGNORE=x\nexport A='secret # preserved'\nB=\"\"\nC= # empty\n")
        #expect(values == ["A": true, "B": false, "C": false])
    }

    @Test func automaticModeFollowsStandardStartAndExplicitNodeEnv() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        var project = fixture.project()
        #expect(ProjectEnvironmentChecker().mode(for: project) == "development")
        project.commandTemplate = "npm start"
        #expect(ProjectEnvironmentChecker().mode(for: project) == "production")
        project.commandTemplate = "NODE_ENV=test npm run dev"
        #expect(ProjectEnvironmentChecker().mode(for: project) == "test")
    }

    @Test func testModeSkipsNextLocalAndCommandModeIsRecognized() {
        let fixture = try? ReliabilityFixture()
        defer { fixture?.cleanup() }
        guard var project = fixture?.project() else { Issue.record("Fixture unavailable"); return }
        project.kind = .nextjs
        project.reliability.environmentMode = "test"
        #expect(ProjectEnvironmentChecker().files(for: project).contains(".env.local") == false)
        project.commandTemplate = "vite --mode staging"
        #expect(ProjectEnvironmentChecker().mode(for: project) == "staging")
    }
}
