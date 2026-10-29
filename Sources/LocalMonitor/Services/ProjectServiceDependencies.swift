import Foundation

enum ProjectDependencyGraph {
    static func order(for project: LocalProject, projects: [LocalProject]) throws -> [LocalProject] {
        guard projects.count <= 128 else { throw ProjectReliabilityError.message("Too many projects in the dependency graph (maximum 128).") }
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visiting = Set<UUID>(), visited = Set<UUID>()
        var ordered: [LocalProject] = []
        func visit(_ item: LocalProject) throws {
            if visited.contains(item.id) { return }
            guard visiting.insert(item.id).inserted else {
                throw ProjectReliabilityError.message("Dependency cycle involving \(item.displayName). Remove the cycle in Project Settings.")
            }
            for id in item.reliability.dependencyProjectIDs {
                guard let child = byID[id] else { throw ProjectReliabilityError.message("A dependency of \(item.displayName) was removed. Update Project Settings.") }
                try visit(child)
            }
            visiting.remove(item.id); visited.insert(item.id); ordered.append(item)
        }
        try visit(project)
        return ordered
    }

    static func waitUntilReady(timeout: TimeInterval = 60, interval: Duration = .seconds(1),
                                probe: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try Task.checkCancellation()
            if try await probe() { return }
            try await Task.sleep(for: interval)
        } while Date() < deadline
        throw ProjectReliabilityError.message("A required service did not become healthy within \(Int(timeout)) seconds. Check its logs and health endpoint.")
    }
}

struct ProjectComposeServices {
    func folder(for project: LocalProject) -> URL? {
        ProjectMetadata.ancestors(of: project.folderURL).first { directory in
            ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"].contains {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        }
    }

    func validate(configuration: Data, services: [String]) throws {
        guard let json = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let definitions = json["services"] as? [String: [String: Any]] else {
            throw ProjectReliabilityError.message("Could not inspect Compose services. Check the Compose configuration.")
        }
        for name in services {
            guard let service = definitions[name] else { throw ProjectReliabilityError.message("Compose service \(name) does not exist. Update Project Settings.") }
            guard let check = service["healthcheck"] as? [String: Any], check["disable"] as? Bool != true,
                  let test = check["test"] as? [String], !test.isEmpty, test.first != "NONE" else {
                throw ProjectReliabilityError.message("Add a healthcheck to Compose service \(name) before enabling automatic startup. A running container is not proof that the service is ready.")
            }
        }
    }

    func start(for project: LocalProject) async throws {
        let services = project.reliability.validated.composeServices
        guard !services.isEmpty else { return }
        guard let directory = folder(for: project) else { throw ProjectReliabilityError.message("No Compose file found. Choose existing services in Project Settings.") }
        let config = try await Shell.run("/bin/zsh", arguments: ["-lc", "docker compose config --format json"],
                                          timeout: 15, directory: directory, maximumOutputBytes: 1_048_576)
        guard config.status == 0 else { throw ProjectReliabilityError.message("Cannot read Compose configuration. Check that Docker and Compose are installed and the project environment is configured.") }
        try validate(configuration: Data(config.stdout.utf8), services: services)
        let names = services.map(ProjectNodeRuntime.quote).joined(separator: " ")
        let result = try await Shell.run("/bin/zsh", arguments: ["-lc", "docker compose up --detach --wait --wait-timeout 60 \(names)"],
                                         timeout: 120, directory: directory, maximumOutputBytes: 65_536)
        guard result.status == 0 else {
            throw ProjectReliabilityError.message("Compose services did not become healthy. Check Docker, service healthchecks and container logs; automatic startup requires Compose with --wait support.")
        }
    }
}
