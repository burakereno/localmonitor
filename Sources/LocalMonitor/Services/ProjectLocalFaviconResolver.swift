import Foundation

/// Resolves literal HTML icon links without starting or executing the project.
struct ProjectLocalFaviconResolver {
    private let fileManager = FileManager.default

    func iconURLs(for project: LocalProject) -> [URL] {
        guard let pageURL = project.localURL else { return [] }
        let root = URL(fileURLWithPath: project.path, isDirectory: true)
        let publicRoot = root.appendingPathComponent("public", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var seen = Set<URL>()
        var icons: [URL] = []
        var remainingBytes = 1_000_000

        for source in sourceURLs(in: root) {
            guard let values = try? source.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, size <= 512_000, size <= remainingBytes,
                  let data = try? Data(contentsOf: source), data.count <= 512_000,
                  data.count <= remainingBytes else { continue }
            remainingBytes -= data.count
            var html = String(decoding: data, as: UTF8.self)
            if source.pathExtension.lowercased() == "astro" {
                html = html.replacingOccurrences(
                    of: #"(?s)\A---\r?\n.*?\r?\n---(?:\r?\n|$)"#,
                    with: "", options: .regularExpression
                )
            }

            for icon in ProjectFaviconLoader.iconURLs(in: html, pageURL: pageURL) {
                // External declarations must never be mistaken for public files.
                guard icon.scheme == pageURL.scheme, icon.host == pageURL.host,
                      icon.port == pageURL.port else { continue }
                let file = publicRoot.appendingPathComponent(icon.path)
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(publicRoot.path + "/"),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, let size = values.fileSize, size <= 2_000_000,
                      seen.insert(file).inserted else { continue }
                icons.append(file)
            }
        }
        return icons
    }

    private func sourceURLs(in root: URL) -> [URL] {
        let entrypoints = ["index.html", "src/index.html", "public/index.html", "src/pages/index.astro"]
            .map { root.appendingPathComponent($0) }
        var layouts: [URL] = []

        for path in ["src/layouts", "layouts"] {
            let directory = root.appendingPathComponent(path, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            // Keep discovery bounded even in unusually large source folders.
            for case let url as URL in enumerator.prefix(256) {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true,
                      url.pathComponents.count - directory.pathComponents.count <= 3 else {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isRegularFile == true, ["astro", "html"].contains(url.pathExtension.lowercased()) {
                    layouts.append(url)
                }
            }
        }

        let projectRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var seen = Set<URL>()
        return (entrypoints + layouts.sorted { $0.path < $1.path })
            .filter { url in
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                return resolved.path.hasPrefix(projectRoot)
                    && fileManager.fileExists(atPath: resolved.path)
                    && seen.insert(resolved).inserted
            }
            .prefix(64).map { $0 }
    }
}
