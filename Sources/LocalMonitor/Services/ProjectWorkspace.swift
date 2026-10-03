import Foundation

/// Reads workspace metadata without executing project code or following external symlinks.
enum ProjectWorkspace {
    static func package(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func patterns(in folder: URL) -> [String] {
        let value = package(in: folder)?["workspaces"]
        let entries = value as? [String] ?? (value as? [String: Any])?["packages"] as? [String] ?? []
        return entries.filter { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }
    }

    static func directories(in root: URL) -> [URL] {
        let patterns = patterns(in: root)
        guard !patterns.isEmpty else { return [] }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var queue: [(URL, Int)] = [(root, 0)]
        var results: [URL] = []
        var visited = Set<String>()
        var index = 0
        let excluded: Set<String> = ["node_modules", ".git", ".next", ".build", "dist", "build"]
        while index < queue.count, index < 4_096 {
            let (folder, depth) = queue[index]
            index += 1
            guard depth < 8,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                  ) else { continue }
            for child in children.sorted(by: { $0.path < $1.path }) {
                guard !excluded.contains(child.lastPathComponent),
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let resolved = child.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root.path + "/"), visited.insert(resolved.path).inserted else { continue }
                let relative = String(resolved.path.dropFirst(root.path.count + 1))
                if matches(relative, patterns: patterns), package(in: resolved) != nil { results.append(resolved) }
                queue.append((resolved, depth + 1))
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    static func root(containing folder: URL) -> URL? {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = folder.deletingLastPathComponent()
        while candidate.path != "/" {
            let relative = String(folder.path.dropFirst(candidate.path.count + 1))
            if matches(relative, patterns: patterns(in: candidate)) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    static func dependencyDirectory(in folder: URL) -> URL? {
        let local = folder.appendingPathComponent("node_modules")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard let root = root(containing: folder) else { return nil }
        let hoisted = root.appendingPathComponent("node_modules")
        return FileManager.default.fileExists(atPath: hoisted.path) ? hoisted : nil
    }

    static func preferredProfile(in root: URL, profiles: [ProjectLaunchProfile], requireSelector: Bool = false) -> ProjectLaunchProfile? {
        let scripts = package(in: root)?["scripts"] as? [String: String] ?? [:]
        let command = scripts["dev"] ?? scripts["start"] ?? ""
        let pattern = #"(?:--workspace(?:=|\s+)|-w\s+)([\w@./-]+)"#
        if let match = command.range(of: pattern, options: .regularExpression) {
            let selector = String(command[match]).replacingOccurrences(
                of: #"^(?:--workspace(?:=|\s+)|-w\s+)"#, with: "", options: .regularExpression
            )
            if let selected = profiles.first(where: {
                $0.detection.name == selector || $0.relativePath == selector || "./" + $0.relativePath == selector
            }) { return selected }
        }
        return requireSelector ? nil : profiles.first
    }

    private static func matches(_ path: String, patterns: [String]) -> Bool {
        let includes = patterns.filter { !$0.hasPrefix("!") }
        let excludes = patterns.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        return includes.contains { matches(path, pattern: $0) } && !excludes.contains { matches(path, pattern: $0) }
    }

    private static func matches(_ path: String, pattern: String) -> Bool {
        var regex = "^"
        let characters = Array(pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                regex += ".*"
                index += 2
            } else {
                regex += character == "*" ? "[^/]*" : character == "?" ? "[^/]" : NSRegularExpression.escapedPattern(for: String(character))
                index += 1
            }
        }
        return path.range(of: regex + "$", options: .regularExpression) != nil
    }
}
