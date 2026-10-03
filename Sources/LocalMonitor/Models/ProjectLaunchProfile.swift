import Foundation

struct ProjectLaunchProfile: Identifiable, Equatable {
    var id: String { folderURL.path }
    let folderURL: URL
    let relativePath: String
    let detection: ProjectDetectionResult
}

struct WorkspaceImport: Identifiable {
    var id: String { rootURL.path }
    let rootURL: URL
    let profiles: [ProjectLaunchProfile]
}

enum LocalHostname {
    static func normalize(_ input: String) -> String? {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) {
            return host == "[::1]" ? "::1" : host
        }
        guard host.hasSuffix(".localhost"), host.count <= 253 else { return nil }
        let valid = host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        return valid ? host : nil
    }

    static func detect(in folder: URL) -> String {
        for file in ["next.config.ts", "next.config.mjs", "next.config.js"] {
            guard let config = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8),
                  let origins = config.range(of: #"allowedDevOrigins\s*:\s*\[[^\]]*\]"#, options: .regularExpression),
                  let regex = try? NSRegularExpression(pattern: #"[\"']([^\"']+)[\"']"#) else { continue }
            let value = String(config[origins])
            let hosts = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: value) else { return nil }
                return normalize(String(value[range]))
            }
            // Multiple allowed origins do not identify a single default site.
            if Set(hosts).count == 1, let host = hosts.first { return host }
        }
        return "localhost"
    }
}
