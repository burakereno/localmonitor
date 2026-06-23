import Foundation

struct HealthChecker {
    func check(_ project: LocalProject) async -> HealthState {
        guard let url = project.healthURL else {
            return .unreachable("Invalid URL")
        }

        let start = Date()
        var request = URLRequest(url: url, timeoutInterval: 2.5)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

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
}
