import AppKit
import Foundation

struct ProjectFaviconLoader {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)
    private let fetch: Fetch

    init(fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.fetch = fetch
    }

    @MainActor
    func load(for project: LocalProject) async -> NSImage? {
        guard let pageURL = project.localURL else { return nil }

        do {
            var pageRequest = Self.request(for: pageURL)
            pageRequest.setValue("text/html", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(pageRequest)
            guard !Task.isCancelled, Self.isSuccessful(response), data.count <= 512_000 else { return nil }

            var documentURL = response.url ?? pageURL
            // Restore the virtual host after connecting through native loopback DNS.
            if pageURL.host?.hasSuffix(".localhost") == true,
               documentURL.host == "127.0.0.1", documentURL.port == pageURL.port {
                var components = URLComponents(url: documentURL, resolvingAgainstBaseURL: false)
                components?.host = pageURL.host
                documentURL = components?.url ?? pageURL
            }

            let html = String(decoding: data, as: UTF8.self)
            for iconURL in Self.iconURLs(in: html, pageURL: documentURL).prefix(6) {
                guard !Task.isCancelled else { return nil }
                do {
                    let (iconData, iconResponse) = try await fetch(Self.request(for: iconURL))
                    guard !Task.isCancelled, Self.isSuccessful(iconResponse), iconData.count <= 2_000_000,
                          let image = NSImage(data: iconData), image.size.width > 0, image.size.height > 0 else {
                        continue
                    }
                    return image
                } catch {
                    // A missing or invalid declared icon can have another usable candidate.
                    continue
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    static func request(for url: URL) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.host?.hasSuffix(".localhost") == true { components?.host = "127.0.0.1" }
        var request = URLRequest(url: components?.url ?? url, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let host = url.host {
            let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            request.setValue(authority + (url.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host")
        }
        return request
    }

    static func iconURLs(in html: String, pageURL: URL) -> [URL] {
        let markup = html
            .replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script\s*>"#, with: "", options: .regularExpression)
        guard let tags = try? NSRegularExpression(pattern: #"(?i)<(link|base)\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>"#) else {
            return []
        }
        let matches = tags.matches(in: markup, range: NSRange(markup.startIndex..., in: markup))
        var baseURL = pageURL
        var foundBase = false
        var candidates: [(url: URL, priority: Int)] = []

        // A base element can appear after an icon declaration in the document.
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: markup),
                  markup[nameRange].lowercased() == "base", !foundBase,
                  let tagRange = Range(match.range, in: markup),
                  let href = attributes(in: String(markup[tagRange]))["href"],
                  let url = resolve(href, relativeTo: pageURL) else { continue }
            baseURL = url
            foundBase = true
        }

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: markup),
                  markup[nameRange].lowercased() == "link",
                  let tagRange = Range(match.range, in: markup) else { continue }
            let attributes = attributes(in: String(markup[tagRange]))
            let relations = Set((attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let priority: Int
            if relations.contains("icon") {
                priority = 0
            } else if !relations.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"]) {
                priority = 1
            } else {
                continue
            }
            guard let href = attributes["href"], let url = resolve(href, relativeTo: baseURL) else { continue }
            candidates.append((url, priority))
        }

        var seen = Set<URL>()
        return candidates.enumerated()
            .sorted { lhs, rhs in
                lhs.element.priority == rhs.element.priority
                    ? lhs.offset < rhs.offset : lhs.element.priority < rhs.element.priority
            }
            .compactMap { seen.insert($0.element.url).inserted ? $0.element.url : nil }
    }

    private static func attributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#) else {
            return [:]
        }
        var attributes: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let nameRange = Range(match.range(at: 1), in: tag),
                  let valueRange = (2...4).compactMap({ Range(match.range(at: $0), in: tag) }).first else { continue }
            let name = tag[nameRange].lowercased()
            if attributes[name] == nil { attributes[name] = String(tag[valueRange]) }
        }
        return attributes
    }

    private static func resolve(_ href: String, relativeTo baseURL: URL) -> URL? {
        let decoded = href.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty, let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func isSuccessful(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(response.statusCode)
    }
}
