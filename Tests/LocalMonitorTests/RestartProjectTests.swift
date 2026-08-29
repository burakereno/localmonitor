import Darwin
import Foundation
import XCTest
@testable import LocalMonitor

final class RestartProjectTests: XCTestCase {
    @MainActor
    func testRestartReplacesRunningProcess() async throws {
        let standardDefaults = UserDefaults.standard
        let preferenceKeys = [
            AppPreference.scanExternalPortsKey,
            AppPreference.notificationsKey,
            AppPreference.healthChecksKey
        ]
        let savedPreferences = preferenceKeys.reduce(into: [String: Any]()) { result, key in
            result[key] = standardDefaults.object(forKey: key)
        }

        standardDefaults.set(true, forKey: AppPreference.scanExternalPortsKey)
        standardDefaults.set(false, forKey: AppPreference.notificationsKey)
        standardDefaults.set(false, forKey: AppPreference.healthChecksKey)
        defer {
            for key in preferenceKeys {
                if let value = savedPreferences[key] {
                    standardDefaults.set(value, forKey: key)
                } else {
                    standardDefaults.removeObject(forKey: key)
                }
            }
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMonitorRestartTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let port = try await availablePort()
        let project = LocalProject(
            name: "restart-fixture",
            path: temporaryDirectory.path,
            kind: .supabase,
            packageManager: .npm,
            port: port,
            commandTemplate: "/usr/bin/python3 -m http.server {port}",
            openAfterStart: false
        )
        let store = ProjectStore(storageDirectoryURL: temporaryDirectory.appendingPathComponent("store"))
        store.save(ProjectLibrary(projects: [project], groups: []))

        let suiteName = "LocalMonitorRestartTests.\(UUID().uuidString)"
        let runtimeDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            runtimeDefaults.removePersistentDomain(forName: suiteName)
        }

        let processManager = ProjectProcessManager(
            userDefaults: runtimeDefaults,
            storageDirectoryURL: temporaryDirectory.appendingPathComponent("logs")
        )
        let model = LocalMonitorModel(
            store: store,
            processManager: processManager,
            userDefaults: runtimeDefaults
        )
        defer {
            model.stopAllProjects()
        }

        await model.startProject(project)
        let originalPID = try XCTUnwrap(model.runtimeState(for: project).pid)
        XCTAssertTrue(Self.isAlive(originalPID))

        await model.restartProject(project)

        let restarted = await waitUntil(timeout: 4) {
            await model.refresh()
            let state = model.runtimeState(for: project)
            guard let pid = state.pid else { return false }
            return state.status == .running && pid != originalPID && Self.isAlive(pid)
        }

        XCTAssertTrue(restarted, "Restart should replace the stopped process with a new running process.")
    }

    private func availablePort() async throws -> Int {
        let occupiedPorts = Set(try await PortScanner().scan().map(\.port))
        return try XCTUnwrap((42_000...52_000).first { !occupiedPorts.contains($0) })
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }
}
