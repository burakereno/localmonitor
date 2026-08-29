import Darwin
import Foundation
import XCTest
@testable import LocalMonitor

final class ProjectProcessOwnershipTests: XCTestCase {
    @MainActor
    func testManagedProcessSurvivesManagerRecreationAndCanBeStoppedAfterReconciliation() async throws {
        let fixture = try TestFixture(prefix: "ManagedOwnership")
        defer { fixture.cleanUp() }

        let project = fixture.project(
            command: "/usr/bin/python3 -u -c 'import time; print(\"managed-ready\", flush=True); time.sleep(60)'"
        )
        var firstManager: ProjectProcessManager? = ProjectProcessManager(
            userDefaults: fixture.defaults,
            storageDirectoryURL: fixture.logDirectory
        )
        try firstManager?.start(project: project)
        let pid = try XCTUnwrap(firstManager?.rootPID(for: project.id))
        defer {
            if ProcessTree.isAlive(pid) {
                ProcessTree.terminate(pid: pid)
            }
        }

        let wroteLog = await waitUntil {
            firstManager?.logLines(for: project.id).contains("managed-ready") == true
        }
        XCTAssertTrue(wroteLog)

        firstManager = nil
        XCTAssertTrue(ProcessTree.isAlive(pid), "Closing Local Monitor must not close the managed project.")

        let restoredManager = ProjectProcessManager(
            userDefaults: fixture.defaults,
            storageDirectoryURL: fixture.logDirectory
        )
        restoredManager.reconcile(projects: [project])

        XCTAssertTrue(restoredManager.isRunning(projectId: project.id))
        XCTAssertEqual(restoredManager.rootPID(for: project.id), pid)
        XCTAssertTrue(restoredManager.logLines(for: project.id).contains("managed-ready"))
        XCTAssertEqual(restoredManager.stopAll(), Set([project.id]))
        let managedProcessStopped = await waitUntil { !ProcessTree.isAlive(pid) }
        XCTAssertTrue(managedProcessStopped)
    }

    @MainActor
    func testExternalProjectRemainsVisibleAndManualStopStillWorks() async throws {
        let fixture = try TestFixture(prefix: "ExternalOwnership")
        defer { fixture.cleanUp() }
        let port = try await fixture.availablePort()
        let project = fixture.project(
            port: port,
            command: "/usr/bin/python3 -m http.server {port} --bind 127.0.0.1"
        )
        fixture.store.save(ProjectLibrary(projects: [project], groups: []))

        let externalProcess = Process()
        externalProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        externalProcess.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        externalProcess.currentDirectoryURL = fixture.rootDirectory
        let nullOutput = try XCTUnwrap(FileHandle(forWritingAtPath: "/dev/null"))
        externalProcess.standardOutput = nullOutput
        externalProcess.standardError = nullOutput
        try externalProcess.run()
        let externalPID = externalProcess.processIdentifier
        defer {
            try? nullOutput.close()
            if ProcessTree.isAlive(externalPID) {
                ProcessTree.terminate(pid: externalPID)
            }
        }

        let manager = ProjectProcessManager(
            userDefaults: fixture.defaults,
            storageDirectoryURL: fixture.logDirectory
        )
        let model = LocalMonitorModel(
            store: fixture.store,
            processManager: manager,
            userDefaults: fixture.defaults
        )

        let discovered = await waitUntil(timeout: 5) {
            await model.refresh()
            let state = model.runtimeState(for: project)
            return state.status == .running && state.ownership == .external
        }
        XCTAssertTrue(discovered)
        XCTAssertTrue(model.externalPorts.contains { port in
            port.projectId == project.id && !port.isManaged
        })

        model.stopAllProjects()
        XCTAssertTrue(ProcessTree.isAlive(externalPID), "Stop on Quit must not kill an external project.")
        XCTAssertEqual(model.runtimeState(for: project).ownership, .external)

        model.stopProject(project)
        let externalProcessStopped = await waitUntil { !ProcessTree.isAlive(externalPID) }
        XCTAssertTrue(externalProcessStopped)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }
}

private final class TestFixture {
    let rootDirectory: URL
    let logDirectory: URL
    let store: ProjectStore
    let defaults: UserDefaults
    private let suiteName: String

    init(prefix: String) throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMonitor\(prefix)Tests-\(UUID().uuidString)", isDirectory: true)
        logDirectory = rootDirectory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        store = ProjectStore(storageDirectoryURL: rootDirectory.appendingPathComponent("store"))
        suiteName = "LocalMonitor\(prefix)Tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError.defaultsUnavailable
        }
        self.defaults = defaults
    }

    func project(
        port: Int = 49_321,
        command: String
    ) -> LocalProject {
        LocalProject(
            name: "ownership-fixture",
            path: rootDirectory.path,
            kind: .supabase,
            packageManager: .npm,
            port: port,
            commandTemplate: command,
            openAfterStart: false
        )
    }

    func availablePort() async throws -> Int {
        let occupiedPorts = Set(try await PortScanner().scan().map(\.port))
        guard let port = (42_000...52_000).first(where: { !occupiedPorts.contains($0) }) else {
            throw FixtureError.noAvailablePort
        }
        return port
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    private enum FixtureError: Error {
        case defaultsUnavailable
        case noAvailablePort
    }
}
