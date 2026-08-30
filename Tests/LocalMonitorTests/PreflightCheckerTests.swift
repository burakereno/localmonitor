import Foundation
import XCTest
@testable import LocalMonitor

final class PreflightCheckerTests: XCTestCase {
    func testProjectWithoutEnvFileHasNoPreflightIssue() async throws {
        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMonitorPreflightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: projectDirectory)
        }

        let project = LocalProject(
            name: "no-env-project",
            path: projectDirectory.path,
            kind: .supabase,
            packageManager: .npm,
            port: 54_321,
            commandTemplate: "supabase start"
        )

        let result = await PreflightChecker().check(project)

        XCTAssertTrue(result.issues.isEmpty)
    }
}
