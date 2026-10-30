import Foundation
import Testing
@testable import LocalMonitor

struct ProjectReliabilityMonitoringTests {
    @Test func informationalToolBannersDoNotOverrideTheActualFailure() {
        let banner = ["[Local Monitor] Node.js 24.21.0", "Using Corepack package manager pnpm 9"]
        #expect(ProjectFailureDiagnosis.classify(logs: banner + ["EADDRINUSE"], exitCode: 1).kind == .port)
        #expect(ProjectFailureDiagnosis.classify(logs: banner + ["Browser is not supported"], exitCode: 1).kind == .unknown)
        #expect(ProjectFailureDiagnosis.classify(logs: banner + ["Corepack error: version unavailable"], exitCode: 1).kind == .packageManager)
        #expect(ProjectFailureDiagnosis.classify(logs: banner + ["Loaded environment variables", "Worker exited"], exitCode: 1).kind == .unknown)
        #expect(ProjectFailureDiagnosis.classify(logs: ["npm WARN EBADENGINE Unsupported engine {", "required: { node: '>=24' }"], exitCode: 1).kind == .node)
    }

    @Test func aggregatesDescendantsWithoutDoubleCountingOrIncludingOtherProjects() {
        let sampler = ProjectResourceSampler()
        let entries = sampler.entries(from: "2 1 2.5 1024\n3 2 4.5 2048\n4 3 1.0 1024\n5 1 99 99999\n6 1 nan 1024\n7 1 1 -1")
        let total = sampler.aggregate(roots: [2, 3], entries: entries)
        #expect(total.cpuPercent == 8)
        #expect(total.memoryBytes == 4 * 1_048_576)
        #expect(total.processCount == 3)
    }

    @Test func resourceWarningsRequireSustainedUsageAndRespectCooldownAndHistoryBounds() {
        var state = ProjectResourceState()
        var settings = ProjectReliabilitySettings(); settings.memoryWarningMB = 128
        let start = Date()
        for index in 0..<100 {
            let sample = ProjectResourceSample(date: start.addingTimeInterval(Double(index * 15)), cpuPercent: 10,
                                                memoryBytes: 256 * 1_048_576, processCount: 2)
            let notification = state.record(sample, settings: settings, alerts: .init(memoryEnabled: true))
            if index < 2 { #expect(notification == nil) }
            if index == 2 { #expect(notification?.contains("Memory usage") == true) }
            if index == 3 { #expect(notification == nil) }
        }
        #expect(state.samples.count == 40)
        #expect(state.warning?.contains("Memory usage") == true)
    }

    @Test func detectsGrowingMemoryAndCpuThresholds() {
        var state = ProjectResourceState()
        for index in 0..<5 {
            _ = state.record(.init(cpuPercent: 0, memoryBytes: Int64(index + 1) * 150 * 1_048_576, processCount: 1), settings: .init())
        }
        #expect(state.warning?.contains("continuously growing") == true)
        state = ProjectResourceState()
        for _ in 0..<3 { _ = state.record(.init(cpuPercent: 400, memoryBytes: 100, processCount: 1), settings: .init()) }
        #expect(state.warning?.contains("CPU usage") == true)
    }

    @Test func restartBudgetBacksOffAndStopsUntilWindowExpires() {
        var budget = ProjectRestartBudget(); let now = Date()
        #expect(budget.nextDelay(maximum: 3, now: now) == 2)
        #expect(budget.nextDelay(maximum: 3, now: now) == 4)
        #expect(budget.nextDelay(maximum: 3, now: now) == 8)
        #expect(budget.nextDelay(maximum: 3, now: now) == nil)
        #expect(budget.nextDelay(maximum: 3, now: now.addingTimeInterval(301)) == 2)
    }

    @Test(arguments: [("Node.js version is not supported", ProjectFailureDiagnosis.Kind.node),
                      ("pnpm: command not found", .packageManager), ("EADDRINUSE", .port),
                      ("Cannot find module xyz", .dependencies), ("Missing environment variable", .environment),
                      ("ECONNREFUSED user:SECRET_MARK@localhost:5432", .database), ("ECONNREFUSED localhost:3001", .connection),
                      ("Docker daemon cannot connect", .docker), ("EACCES Permission denied", .permissions)])
    func diagnosesErrorsWithoutRetainingRawSecrets(_ input: (String, ProjectFailureDiagnosis.Kind)) throws {
        let diagnosis = ProjectFailureDiagnosis.classify(logs: [input.0], exitCode: 1)
        #expect(diagnosis.kind == input.1)
        let json = String(decoding: try JSONEncoder().encode(ProjectFailureRecord(exitCode: 1, diagnosis: diagnosis)), as: UTF8.self)
        #expect(json.contains("SECRET_MARK") == false)
    }

    @Test func legacyProjectsAndPartialSettingsDecodeWithDefaults() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let encoder = JSONEncoder()
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(fixture.project())) as? [String: Any])
        json.removeValue(forKey: "reliability")
        let legacy = try JSONDecoder().decode(LocalProject.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.reliability.maximumRestarts == 3)
        json["reliability"] = ["environmentMode": "test"]
        let partial = try JSONDecoder().decode(LocalProject.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(partial.reliability.environmentMode == "test")
        #expect(partial.reliability.memoryWarningMB == 2048)
    }

    @Test @MainActor func failureHistoryIsBoundedPersistentAndClearedExplicitly() throws {
        let fixture = try ReliabilityFixture(); defer { fixture.cleanup() }
        let suite = "FailureHistory-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let project = fixture.project()
        let store = ProjectStore(storageDirectoryURL: fixture.root.appendingPathComponent("store"))
        store.save(.init(projects: [project]))
        let model = LocalMonitorModel(store: store, userDefaults: defaults)
        let diagnosis = ProjectFailureDiagnosis.classify(logs: ["EADDRINUSE SECRET_MARK"], exitCode: 1)
        for _ in 0..<30 { model.recordFailure(for: project, code: 1, diagnosis: diagnosis) }
        #expect(model.failureHistory[project.id]?.count == 20)
        let restored = LocalMonitorModel(store: store, userDefaults: defaults)
        #expect(restored.failureHistory[project.id]?.count == 20)
        restored.clearFailureHistory(for: project)
        #expect(defaults.data(forKey: "projectFailures.\(project.id)") == nil)
    }
}
