import Foundation

struct ProjectResourceAlertPreferences {
    var cpuEnabled = false
    var memoryEnabled = false

    static func load(from defaults: UserDefaults) -> Self {
        let notificationsEnabled = defaults.object(forKey: AppPreference.notificationsKey) as? Bool ?? true
        return Self(
            cpuEnabled: notificationsEnabled && defaults.bool(forKey: AppPreference.projectCPUAlertsKey),
            memoryEnabled: notificationsEnabled && defaults.bool(forKey: AppPreference.projectMemoryAlertsKey)
        )
    }
}

struct ProjectResourceSample: Equatable {
    var date = Date()
    let cpuPercent: Double
    let memoryBytes: Int64
    let processCount: Int

    var summary: String {
        "CPU \(Int(cpuPercent.rounded()))% · \(ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .memory)) · \(processCount) \(processCount == 1 ? "process" : "processes")"
    }
}

struct ProjectResourceState: Equatable {
    var samples: [ProjectResourceSample] = []
    var warning: String?
    var lastNotification: Date?

    mutating func record(
        _ sample: ProjectResourceSample,
        settings: ProjectReliabilitySettings,
        alerts: ProjectResourceAlertPreferences = .init()
    ) -> String? {
        samples.append(sample)
        samples = Array(samples.suffix(40))
        let limits = settings.validated
        let recent = samples.suffix(3)
        var memoryLimitWarning: String?
        var memoryGrowthWarning: String?
        var cpuWarning: String?
        if recent.count == 3, recent.allSatisfy({ $0.memoryBytes > Int64(limits.memoryWarningMB) * 1_048_576 }) {
            memoryLimitWarning = "Memory usage stayed above \(limits.memoryWarningMB) MB. Inspect or stop this project."
        } else {
            let growth = Array(samples.suffix(5))
            if growth.count == 5, zip(growth, growth.dropFirst()).allSatisfy({ $1.memoryBytes > $0.memoryBytes }),
               growth.last!.memoryBytes - growth.first!.memoryBytes > 512 * 1_048_576 {
                memoryGrowthWarning = "Memory is continuously growing (over 512 MB across five samples). Inspect this project's child processes."
            }
        }
        if recent.count == 3, recent.allSatisfy({ $0.cpuPercent > Double(limits.cpuWarningPercent) }) {
            cpuWarning = "CPU usage stayed above \(limits.cpuWarningPercent)%. Inspect or stop this project."
        }
        warning = memoryLimitWarning ?? cpuWarning ?? memoryGrowthWarning
        let memoryWarning = memoryLimitWarning ?? memoryGrowthWarning
        let message = (alerts.memoryEnabled ? memoryWarning : nil) ?? (alerts.cpuEnabled ? cpuWarning : nil)
        guard let message, lastNotification.map({ sample.date.timeIntervalSince($0) >= 120 }) ?? true else { return nil }
        lastNotification = sample.date
        return message
    }
}

struct ProjectResourceSampler {
    struct Entry {
        let pid: Int32
        let parent: Int32
        let cpu: Double
        let rss: Int64
    }

    func entries(from text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).prefix(16_384).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 4, let pid = Int32(fields[0]), pid > 1, let parent = Int32(fields[1]),
                  let cpu = Double(fields[2]), cpu.isFinite, cpu >= 0,
                  let kb = Int64(fields[3]), kb >= 0, kb < Int64.max / 1024 else { return nil }
            return Entry(pid: pid, parent: parent, cpu: cpu, rss: kb * 1024)
        }
    }

    func aggregate(roots: Set<Int32>, entries: [Entry], at date: Date = Date()) -> ProjectResourceSample {
        let byPID = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let byParent = Dictionary(grouping: entries, by: \.parent)
        var pending = Array(roots), visited = Set<Int32>()
        var cpu = 0.0, memory: Int64 = 0
        while let pid = pending.popLast(), visited.count < 16_384 {
            guard visited.insert(pid).inserted, let entry = byPID[pid] else { continue }
            cpu += entry.cpu
            memory += min(entry.rss, Int64.max - memory)
            pending += (byParent[pid] ?? []).map(\.pid)
        }
        return ProjectResourceSample(date: date, cpuPercent: cpu, memoryBytes: memory,
                                     processCount: visited.filter { byPID[$0] != nil }.count)
    }

    func snapshot() async throws -> [Entry] {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        let result = try await Shell.run("/bin/ps", arguments: ["-axo", "pid=,ppid=,%cpu=,rss="],
                                         timeout: 3, environment: environment, maximumOutputBytes: 1_048_576)
        guard result.status == 0 else { throw ProjectReliabilityError.message("Process resource measurements are temporarily unavailable.") }
        return entries(from: result.stdout)
    }
}
