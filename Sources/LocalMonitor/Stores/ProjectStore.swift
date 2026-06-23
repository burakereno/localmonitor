import Foundation

enum ProjectStoreError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Application Support folder is unavailable."
        }
    }
}

final class ProjectStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> ProjectLibrary {
        do {
            let url = try storeURL()
            guard fileManager.fileExists(atPath: url.path) else { return ProjectLibrary() }
            let data = try Data(contentsOf: url)

            if let library = try? decoder.decode(ProjectLibrary.self, from: data) {
                return library
            }

            let projects = try decoder.decode([LocalProject].self, from: data)
            return ProjectLibrary(projects: projects, groups: [])
        } catch {
            NSLog("LocalMonitor: project load failed: \(error.localizedDescription)")
            return ProjectLibrary()
        }
    }

    func save(_ library: ProjectLibrary) {
        do {
            let url = try storeURL()
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(library)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("LocalMonitor: project save failed: \(error.localizedDescription)")
        }
    }

    private func storeURL() throws -> URL {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ProjectStoreError.applicationSupportUnavailable
        }

        return appSupport
            .appendingPathComponent("Local Monitor", isDirectory: true)
            .appendingPathComponent("projects.json")
    }
}

struct ProjectLibrary: Codable, Equatable {
    var projects: [LocalProject]
    var groups: [WorkspaceGroup]

    init(projects: [LocalProject] = [], groups: [WorkspaceGroup] = []) {
        self.projects = projects
        self.groups = groups
    }
}
