import Foundation
import Testing
@testable import LocalMonitor

@MainActor
struct NodeInstallationIntegrationTests {
    @Test func installsRechecksAndClearsTheBlockedStateWithoutStartingAServer() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(".nvmrc", "24.18.0\n")
        var project = fixture.project(); project.kind = .supabase
        let suite = "NodeInstall-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(fixture, projects: [project], defaults: defaults)
        defer { model.stop() }
        await model.checkRequirements(for: project)
        #expect(model.preflightResults[project.id]?.missingNodeRequirement != nil)
        model.setState(for: project.id, status: .crashed, message: "Missing Node")
        model.nodeInstaller = ProjectNodeInstaller(loadReleaseIndex: {
            Issue.record("Exact pin must not load releases."); return Data()
        }, execute: { _, folder in
            #expect(folder.path == fixture.root.path)
            _ = try fixture.node("24.18.0")
            return ShellResult(status: 0, stdout: "Installed", stderr: "")
        })
        await model.installNode(for: project)
        #expect(model.nodeInstallationStates[project.id] == .succeeded("24.18.0"))
        #expect(model.preflightResults[project.id]?.missingNodeRequirement == nil)
        #expect(model.preflightResults[project.id]?.launchEnvironment?.node?.version.description == "24.18.0")
        #expect(model.runtimeState(for: project).status == .stopped)
        #expect(model.processManager.isRunning(projectId: project.id) == false)
        #expect(model.nodeInstallationTasks.isEmpty)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent(".nvmrc"), encoding: .utf8) == "24.18.0\n")
    }

    @Test(arguments: ["failure", "changedPin"])
    func failedInstallationKeepsRecoveryAvailable(_ action: String) async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(".nvmrc", "24.18.0\n")
        var project = fixture.project(); project.kind = .supabase
        let suite = "FailedNodeInstall-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(fixture, projects: [project], defaults: defaults)
        defer { model.stop() }
        await model.checkRequirements(for: project)
        model.nodeInstaller = ProjectNodeInstaller(execute: { _, _ in
            if action == "changedPin" {
                try fixture.write(".nvmrc", "22\n")
                return ShellResult(status: 0, stdout: "", stderr: "")
            }
            return ShellResult(status: 1, stdout: "", stderr: "Network unavailable")
        })
        await model.installNode(for: project)
        guard case .failed(let message) = model.nodeInstallationStates[project.id] else {
            Issue.record("Installation failure must stay visible on the project card."); return
        }
        #expect(message.contains(action == "changedPin" ? "requirement changed" : "Network unavailable"))
        #expect(model.preflightResults[project.id]?.missingNodeRequirement != nil)
        #expect(model.nodeInstallationTasks.isEmpty)
        #expect(model.processManager.isRunning(projectId: project.id) == false)
    }

    @Test func recheckingAfterAManualInstallClearsThePreviousFailure() async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(".nvmrc", "24.18.0\n")
        var project = fixture.project(); project.kind = .supabase
        let suite = "ManualNodeInstall-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(fixture, projects: [project], defaults: defaults)
        defer { model.stop() }
        await model.checkRequirements(for: project)
        model.nodeInstallationStates[project.id] = .failed("Previous installation failed")
        _ = try fixture.node("24.18.0")
        await model.checkRequirements(for: project)
        #expect(model.nodeInstallationStates[project.id] == nil)
        #expect(model.preflightResults[project.id]?.missingNodeRequirement == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "caller", "remove", "shutdown"])
    func cancellationStopsTheInstallerWithoutRestoringRemovedState(_ action: String) async throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        try fixture.write(".nvmrc", "24.18.0\n")
        var project = fixture.project(); project.kind = .supabase
        let suite = "CancelNodeInstall-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(fixture, projects: [project], defaults: defaults)
        defer { model.stop() }
        await model.checkRequirements(for: project)
        model.nodeInstaller = ProjectNodeInstaller(execute: { _, folder in
            try await Shell.run("/bin/sh", arguments: ["-c", "/usr/bin/touch installing; /bin/sleep 30"],
                                timeout: 40, directory: folder)
        })
        let install = Task { await model.installNode(for: project) }
        let marker = fixture.root.appendingPathComponent("installing")
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: marker.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        // Neither a duplicate click nor Start may race the active installation.
        await model.installNode(for: project)
        await model.startProject(project)
        #expect(model.nodeInstallationTasks.count == 1)
        #expect(model.processManager.isRunning(projectId: project.id) == false)
        if action == "remove" { model.removeProject(project) }
        else if action == "caller" { install.cancel() }
        else if action == "shutdown" { model.stop() }
        else { model.cancelNodeInstallation(for: project) }
        await install.value
        #expect(model.nodeInstallationTasks.isEmpty)
        if action == "remove" {
            #expect(model.nodeInstallationStates[project.id] == nil)
            #expect(model.preflightResults[project.id] == nil)
        } else { #expect(model.nodeInstallationStates[project.id] == .cancelled) }
    }

    private func makeModel(_ fixture: ReliabilityFixture, projects: [LocalProject], defaults: UserDefaults) -> LocalMonitorModel {
        let store = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("projects"))
        store.save(.init(projects: projects))
        let resolver = ProjectNodeRuntimeResolver(candidateDirectories: [fixture.root.appendingPathComponent("tools")])
        return LocalMonitorModel(store: store, preflightChecker: .init(nodeRuntimeResolver: resolver),
            processManager: ProjectProcessManager(userDefaults: defaults, storageDirectoryURL: fixture.root.appendingPathComponent("logs")),
            userDefaults: defaults)
    }
}
