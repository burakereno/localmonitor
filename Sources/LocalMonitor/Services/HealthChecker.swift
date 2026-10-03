import Foundation

protocol HealthChecking {
    func check(_ project: LocalProject) async -> HealthState
}

struct HealthChecker: HealthChecking {
    func check(_ project: LocalProject) async -> HealthState {
        guard let request = Self.request(for: project) else {
            return .unreachable("Invalid URL")
        }

        let start = Date()

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let milliseconds = max(1, Int(Date().timeIntervalSince(start) * 1_000))
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("No HTTP response")
            }

            if (200..<400).contains(http.statusCode) {
                return .healthy(code: http.statusCode, milliseconds: milliseconds)
            }

            return .warning(code: http.statusCode, milliseconds: milliseconds)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    static func request(for project: LocalProject) -> URLRequest? {
        guard let url = project.healthURL else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // macOS native DNS does not resolve every *.localhost name. Preserve the
        // site's Host while connecting to loopback, just as local browsers do.
        if project.hostname.hasSuffix(".localhost") { components?.host = "127.0.0.1" }
        guard let endpoint = components?.url else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(project.localAuthority, forHTTPHeaderField: "Host")
        return request
    }
}
