import Foundation
import Testing
@testable import LocalMonitor

struct CommandExecutionTests {
    @Test func drainsLargeOutputWithoutUnboundedCaptureOrPipeDeadlock() async throws {
        let result = try await Shell.run("/bin/sh", arguments: ["-c", "yes output | head -c 200000; printf stderr >&2"],
                                          timeout: 3, maximumOutputBytes: 4_096)
        #expect(result.status == 0)
        #expect(result.stdout.utf8.count < 4_200)
        #expect(result.stdout.contains("[Output truncated]"))
        #expect(result.stderr == "stderr")
    }

    @Test func appliesDirectoryAndEnvironmentWithoutLoggingValues() async throws {
        let fixture = try ReliabilityFixture()
        defer { fixture.cleanup() }
        let result = try await Shell.run("/bin/sh", arguments: ["-c", "printf '%s' \"$LM_TEST\"; pwd"],
                                          directory: fixture.root, environment: ["LM_TEST": "fixture-value"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("fixture-value"))
        #expect(result.stdout.contains(fixture.root.path))
    }

    @Test func timeoutStopsChildrenAndReturnsQuickly() async throws {
        let started = Date()
        let result = try await Shell.run("/bin/sh", arguments: ["-c", "/bin/sleep 30 & wait"], timeout: 0.15)
        #expect(result.status == 124)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(result.stderr.contains("timed out"))
    }

    @Test func cancellationStopsAnOwnedCommand() async throws {
        let task = Task { try await Shell.run("/bin/sh", arguments: ["-c", "/bin/sleep 30 & wait"], timeout: 30) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { #expect(task.isCancelled) }
    }
}

struct ReliabilityFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Reliability-'quote-\(UUID().uuidString)")
        .standardizedFileURL.resolvingSymlinksInPath()

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }
    func project(manager: PackageManager = .npm) -> LocalProject {
        LocalProject(name: "reliability-fixture", path: root.path, kind: .unknown, packageManager: manager,
                     port: 54321, commandTemplate: manager.devCommand, openAfterStart: false)
    }
    func node(_ version: String = "24.21.0") throws -> ProjectNodeRuntime {
        let file = root.appendingPathComponent("tools/node")
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "executable": file.path])
        let json = String(decoding: data, as: UTF8.self)
        try write("tools/node", """
        #!/bin/sh
        if [ "$1" = '-p' ]; then printf '%s\\n' \(ProjectNodeRuntime.quote(json)); else printf 'v\(version)\\n'; fi

        """, executable: true)
        return ProjectNodeRuntime(executable: file, version: try NodeVersion(version),
                                  requirement: .init(selector: version, source: root.appendingPathComponent(".node-version"), allowsAliases: true))
    }
}
