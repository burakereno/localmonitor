import Foundation
import Testing
@testable import LocalMonitor

struct ProjectResourceAlertTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [false, true])
    func resourceNotificationsRequireOptInEvenWithExistingNotificationsEnabled(_ existingNotifications: Bool) throws {
        let suite = "ProjectResourceAlerts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if existingNotifications { defaults.set(true, forKey: AppPreference.notificationsKey) }

        let alerts = ProjectResourceAlertPreferences.load(from: defaults)
        #expect(alerts.cpuEnabled == false)
        #expect(alerts.memoryEnabled == false)

        var state = ProjectResourceState()
        for index in 0..<5 {
            #expect(state.record(sample(index, cpu: 400, memoryMB: 3_072), settings: .init(), alerts: alerts) == nil)
        }
        #expect(state.warning?.contains("Memory usage") == true)
        #expect(state.samples.count == 5)
        #expect(state.lastNotification == nil)
    }

    @Test func resourcePreferencesPersistIndependentlyAndHonorTheMainSwitch() throws {
        let suite = "ProjectResourceAlerts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: AppPreference.projectCPUAlertsKey)
        defaults.set(false, forKey: AppPreference.projectMemoryAlertsKey)
        let restored = try #require(UserDefaults(suiteName: suite))
        var alerts = ProjectResourceAlertPreferences.load(from: restored)
        #expect(alerts.cpuEnabled)
        #expect(alerts.memoryEnabled == false)

        defaults.set(false, forKey: AppPreference.projectCPUAlertsKey)
        defaults.set(true, forKey: AppPreference.projectMemoryAlertsKey)
        alerts = .load(from: restored)
        #expect(alerts.cpuEnabled == false)
        #expect(alerts.memoryEnabled)

        defaults.set(true, forKey: AppPreference.projectCPUAlertsKey)
        defaults.set(false, forKey: AppPreference.notificationsKey)
        alerts = .load(from: restored)
        #expect(alerts.cpuEnabled == false)
        #expect(alerts.memoryEnabled == false)

        var state = ProjectResourceState()
        for index in 0..<3 {
            #expect(state.record(sample(index, cpu: 400, memoryMB: 3_072), settings: .init(), alerts: alerts) == nil)
        }
        #expect(state.lastNotification == nil)

        defaults.set(true, forKey: AppPreference.notificationsKey)
        let message = state.record(sample(3, cpu: 400, memoryMB: 3_072), settings: .init(), alerts: .load(from: restored))
        #expect(message?.contains("Memory usage") == true)
    }

    @Test(arguments: [[3_072, 3_072, 3_072], [256, 512, 768, 1_024, 1_280]])
    func disabledMemoryAlertsSuppressBothHighUsageAndGrowth(_ memoryMB: [Int]) throws {
        let lastMemory = try #require(memoryMB.last)
        var state = ProjectResourceState()
        for (index, memory) in memoryMB.enumerated() {
            let message = state.record(sample(index, memoryMB: memory), settings: .init(), alerts: .init(cpuEnabled: true))
            #expect(message == nil)
        }
        #expect(state.warning?.hasPrefix("Memory") == true)
        #expect(state.lastNotification == nil)

        // Suppressed samples must not consume the notification cooldown.
        let message = state.record(sample(memoryMB.count, memoryMB: lastMemory + 256),
                                   settings: .init(), alerts: .init(memoryEnabled: true))
        #expect(message?.hasPrefix("Memory") == true)
    }

    @Test func disabledMemoryWarningsCannotMaskEnabledCpuAlerts() {
        var state = ProjectResourceState()
        var message: String?
        for index in 0..<3 {
            message = state.record(sample(index, cpu: 400, memoryMB: 3_072), settings: .init(), alerts: .init(cpuEnabled: true))
        }
        #expect(message?.hasPrefix("CPU usage") == true)
        #expect(message?.contains("Memory") == false)
        #expect(state.warning?.hasPrefix("Memory") == true)
    }

    @Test func disablingAlertsAppliesToTheNextSampleAndCooldownStillAppliesAfterReenabling() {
        var state = ProjectResourceState()
        for index in 0..<3 {
            _ = state.record(sample(index, memoryMB: 3_072), settings: .init(), alerts: .init(memoryEnabled: true))
        }
        #expect(state.lastNotification == start.addingTimeInterval(30))
        #expect(state.record(sample(3, memoryMB: 3_072), settings: .init()) == nil)
        #expect(state.record(sample(9, memoryMB: 3_072), settings: .init()) == nil)
        #expect(state.lastNotification == start.addingTimeInterval(30))
        #expect(state.record(sample(9, memoryMB: 3_072), settings: .init(), alerts: .init(memoryEnabled: true)) == nil)
        #expect(state.record(sample(10, memoryMB: 3_072), settings: .init(), alerts: .init(memoryEnabled: true)) != nil)
    }

    @Test func enablingOnlyMemoryAlertsDoesNotEnableCpuNotifications() {
        var state = ProjectResourceState()
        for index in 0..<3 {
            let message = state.record(sample(index, cpu: 400, memoryMB: 128), settings: .init(), alerts: .init(memoryEnabled: true))
            #expect(message == nil)
        }
        #expect(state.warning?.hasPrefix("CPU usage") == true)
        #expect(state.lastNotification == nil)
    }

    @Test func enabledMemoryGrowthAlertsAreNotMaskedByDisabledCpuAlerts() {
        var state = ProjectResourceState()
        var message: String?
        for index in 0..<5 {
            message = state.record(sample(index, cpu: 400, memoryMB: (index + 1) * 256),
                                   settings: .init(), alerts: .init(memoryEnabled: true))
        }
        #expect(message?.contains("continuously growing") == true)
        #expect(state.warning?.hasPrefix("CPU usage") == true)
    }

    private func sample(_ index: Int, cpu: Double = 0, memoryMB: Int) -> ProjectResourceSample {
        ProjectResourceSample(date: start.addingTimeInterval(Double(index * 15)), cpuPercent: cpu,
                              memoryBytes: Int64(memoryMB) * 1_048_576, processCount: 1)
    }
}
