import Foundation

struct ProjectReliabilitySettings: Codable, Equatable {
    var requiredEnvironmentKeys: [String] = []
    var environmentMode = "auto"
    var dependencyProjectIDs: [UUID] = []
    var composeServices: [String] = []
    var memoryWarningMB = 2_048
    var cpuWarningPercent = 300
    var maximumRestarts = 3

    init() {}

    enum CodingKeys: String, CodingKey {
        case requiredEnvironmentKeys, environmentMode, dependencyProjectIDs, composeServices
        case memoryWarningMB, cpuWarningPercent, maximumRestarts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requiredEnvironmentKeys = try values.decodeIfPresent([String].self, forKey: .requiredEnvironmentKeys) ?? []
        environmentMode = try values.decodeIfPresent(String.self, forKey: .environmentMode) ?? "auto"
        dependencyProjectIDs = try values.decodeIfPresent([UUID].self, forKey: .dependencyProjectIDs) ?? []
        composeServices = try values.decodeIfPresent([String].self, forKey: .composeServices) ?? []
        memoryWarningMB = try values.decodeIfPresent(Int.self, forKey: .memoryWarningMB) ?? 2_048
        cpuWarningPercent = try values.decodeIfPresent(Int.self, forKey: .cpuWarningPercent) ?? 300
        maximumRestarts = try values.decodeIfPresent(Int.self, forKey: .maximumRestarts) ?? 3
    }

    var validated: Self {
        var copy = self
        copy.requiredEnvironmentKeys = Array(Set(requiredEnvironmentKeys.filter(Self.validEnvironmentKey))).sorted().prefix(256).map { $0 }
        copy.environmentMode = environmentMode.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil ? environmentMode : "auto"
        copy.dependencyProjectIDs = Array(Set(dependencyProjectIDs)).sorted { $0.uuidString < $1.uuidString }
        copy.composeServices = Array(Set(composeServices.filter { $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil })).sorted()
        copy.memoryWarningMB = min(65_536, max(128, memoryWarningMB))
        copy.cpuWarningPercent = min(3_200, max(50, cpuWarningPercent))
        copy.maximumRestarts = min(10, max(0, maximumRestarts))
        return copy
    }

    static func validEnvironmentKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil
    }
}

enum ProjectReliabilityError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

enum ProjectMetadata {
    static func data(at url: URL, limit: Int = 1_048_576) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ProjectReliabilityError.message("\(url.lastPathComponent) is too large to inspect safely.") }
        return data
    }

    static func package(at folder: URL) throws -> [String: Any]? {
        guard let data = try data(at: folder.appendingPathComponent("package.json")) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func ancestors(of folder: URL) -> [URL] {
        var current = folder.standardizedFileURL
        var visited = Set<String>()
        var folders: [URL] = []
        for _ in 0..<128 {
            guard visited.insert(current.path).inserted else { break }
            folders.append(current)
            if current.path == "/" { break }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
        return folders
    }
}
