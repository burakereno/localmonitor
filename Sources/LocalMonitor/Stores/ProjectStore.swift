import CryptoKit
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
    let storageDirectoryURL: URL?
    private(set) var loadIssue: String?
    private(set) var saveIssue: String?
    private var unreadableLibrary = false
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, storageDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.storageDirectoryURL = storageDirectoryURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> ProjectLibrary {
        loadIssue = nil
        unreadableLibrary = false
        do {
            let url = try storeURL()
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return ProjectLibrary()
            }
            if let library = try? decoder.decode(ProjectLibrary.self, from: data),
               Set(library.projects.map(\.id)).count == library.projects.count,
               Set(library.groups.map(\.id)).count == library.groups.count { return library }
            if let projects = try? decoder.decode([LocalProject].self, from: data),
               Set(projects.map(\.id)).count == projects.count { return ProjectLibrary(projects: projects) }

            // Keep the original bytes before permitting any change to the library.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let backup = url.deletingLastPathComponent().appendingPathComponent("projects-recovery-\(digest).json")
            if (try? Data(contentsOf: backup)) != data {
                try data.write(to: backup, options: .withoutOverwriting)
            }
            let json = try? JSONSerialization.jsonObject(with: data)
            let dictionary = json as? [String: Any]
            let projects: [LocalProject] = recoverRecords(from: dictionary?["projects"] ?? json)
            let groups: [WorkspaceGroup] = recoverRecords(from: dictionary?["groups"])
            loadIssue = "Some project data could not be read. The original file was saved at \(backup.path)."
            return ProjectLibrary(projects: projects, groups: groups)
        } catch {
            unreadableLibrary = true
            loadIssue = "Could not read or back up projects.json. Changes cannot be saved. \(error.localizedDescription)"
            return ProjectLibrary()
        }
    }

    private func recoverRecords<T: Decodable & Identifiable>(from value: Any?) -> [T] {
        guard let rows = value as? [Any] else { return [] }
        var ids = Set<T.ID>()
        return rows.compactMap { row in
            guard let object = row as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object),
                  let record = try? decoder.decode(T.self, from: data), ids.insert(record.id).inserted else { return nil }
            return record
        }
    }

    func save(_ library: ProjectLibrary) {
        guard !unreadableLibrary else { return }
        do {
            let url = try storeURL()
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(library)
            try data.write(to: url, options: .atomic)
            saveIssue = nil
        } catch {
            saveIssue = "Could not save projects.json. \(error.localizedDescription)"
        }
    }

    private func storeURL() throws -> URL {
        if let storageDirectoryURL {
            return storageDirectoryURL.appendingPathComponent("projects.json")
        }

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
