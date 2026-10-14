import AppKit
import Foundation
import Testing
@testable import LocalMonitor

@MainActor
struct ProjectFaviconLoaderTests {
    @Test(arguments: [
        (#"<link rel="icon" href="/media/7HZjWDAP5tQFjsBtSjwMW3j3Jss.png" type="image/png">"#,
         "http://localhost:3025/media/7HZjWDAP5tQFjsBtSjwMW3j3Jss.png"),
        (#"<LINK HREF='images/brand.png' REL='shortcut ICON'/>"#,
         "http://localhost:3025/news/images/brand.png"),
        (#"<link href=/brand.png rel=icon>"#,
         "http://localhost:3025/brand.png"),
        (#"<link rel="icon" href="//cdn.example.com/brand.png?v=2&amp;size=64">"#,
         "http://cdn.example.com/brand.png?v=2&size=64"),
        (#"<link rel="icon" href="brand.png"><base href="/assets/">"#,
         "http://localhost:3025/assets/brand.png"),
        ("<link\n type=\"image/png\"\n href=\"https://cdn.example.com/brand.png\"\n rel=\"icon\">",
         "https://cdn.example.com/brand.png")
    ])
    func resolvesDeclaredIconAddresses(html: String, expected: String) throws {
        let pageURL = try #require(URL(string: "http://localhost:3025/news/"))
        #expect(ProjectFaviconLoader.iconURLs(in: html, pageURL: pageURL).map(\.absoluteString) == [expected])
    }

    @Test
    func prefersSiteIconsAndIgnoresUnrelatedOrInactiveMarkup() throws {
        let html = """
        <!-- <link rel="icon" href="/old.png"> -->
        <script>const example = '<link rel="icon" href="/example.png">';</script>
        <link rel="stylesheet" href="/styles.css">
        <link data-rel="icon" href="/not-an-icon.png">
        <link rel="icon" href="file:///tmp/private.png">
        <link rel="icon" href="javascript:alert(1)">
        <link rel="apple-touch-icon" href="/touch.png">
        <link rel="icon" href="/brand.png">
        <link rel="shortcut icon" href="/brand.png">
        """
        let pageURL = try #require(URL(string: "http://localhost:3025/"))
        #expect(ProjectFaviconLoader.iconURLs(in: html, pageURL: pageURL).map(\.path) == ["/brand.png", "/touch.png"])
    }

    @Test(.tags(.networking))
    func loadsTheSitesNestedIconInsteadOfRequestingConventionalFilenames() async throws {
        let project = makeProject()
        let png = try faviconPNG(color: .systemGreen)
        var requests: [URLRequest] = []
        let loader = ProjectFaviconLoader { request in
            requests.append(request)
            let url = try #require(request.url)
            let data = url.path == ""
                ? Data(#"<link rel="icon" href="/media/brand-hash.png">"#.utf8) : png
            return (data, try httpResponse(url: url))
        }

        let image = await loader.load(for: project)

        #expect(image?.size == NSSize(width: 16, height: 16))
        #expect(requests.compactMap(\.url).map(\.absoluteString) == [
            "http://localhost:3025", "http://localhost:3025/media/brand-hash.png"
        ])
    }

    @Test(.tags(.networking))
    func triesAnotherDeclaredIconWhenTheFirstIsMissingOrUndecodable() async throws {
        let png = try faviconPNG(color: .systemBlue)
        var paths: [String] = []
        let loader = ProjectFaviconLoader { request in
            let url = try #require(request.url)
            paths.append(url.path)
            switch url.path {
            case "":
                return (Data("""
                    <link rel="icon" href="/missing.png">
                    <link rel="icon" href="/invalid.png">
                    <link rel="apple-touch-icon" href="/touch.png">
                    """.utf8), try httpResponse(url: url))
            case "/missing.png":
                return (png, try httpResponse(url: url, status: 404))
            case "/invalid.png":
                return (Data("not an image".utf8), try httpResponse(url: url))
            default:
                return (png, try httpResponse(url: url))
            }
        }

        #expect(await loader.load(for: makeProject()) != nil)
        #expect(paths == ["", "/missing.png", "/invalid.png", "/touch.png"])
    }

    @Test(.tags(.networking), arguments: [404, 500])
    func doesNotUseIconsFromAnErrorPage(status: Int) async throws {
        var requests = 0
        let loader = ProjectFaviconLoader { request in
            requests += 1
            return (Data(#"<link rel="icon" href="/error.png">"#.utf8),
                    try httpResponse(url: #require(request.url), status: status))
        }

        #expect(await loader.load(for: makeProject()) == nil)
        #expect(requests == 1)
    }

    @Test(.tags(.networking))
    func usesTheFinalDocumentAddressForRelativeIcons() async throws {
        let finalURL = try #require(URL(string: "http://localhost:3025/en/"))
        let png = try faviconPNG(color: .systemGreen)
        var paths: [String] = []
        let loader = ProjectFaviconLoader { request in
            let url = try #require(request.url)
            paths.append(url.path)
            if paths.count == 1 {
                return (Data(#"<link rel="icon" href="brand.png">"#.utf8), try httpResponse(url: finalURL))
            }
            return (png, try httpResponse(url: url))
        }

        #expect(await loader.load(for: makeProject()) != nil)
        #expect(paths == ["", "/en/brand.png"])
    }

    @Test(.tags(.networking))
    func preservesTenantHostnameWhenConnectingToLoopback() async throws {
        var project = makeProject()
        project.hostname = "tenant.localhost"
        let png = try faviconPNG(color: .systemGreen)
        var requests: [URLRequest] = []
        let loader = ProjectFaviconLoader { request in
            requests.append(request)
            let url = try #require(request.url)
            let data = url.path == "" ? Data(#"<link rel="icon" href="/brand.png">"#.utf8) : png
            return (data, try httpResponse(url: url))
        }

        #expect(await loader.load(for: project) != nil)
        #expect(requests.compactMap(\.url).map(\.host) == ["127.0.0.1", "127.0.0.1"])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Host") } == ["tenant.localhost:3025", "tenant.localhost:3025"])
    }

    @Test(.tags(.networking))
    func cachesDeclaredIconsRefreshesOnPortChangesAndRetainsThemOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localPNG = try faviconPNG(color: .systemRed)
        try localPNG.write(to: root.appendingPathComponent("public/favicon.png"))
        var project = makeProject(path: root.path)
        var png = try faviconPNG(color: .systemGreen)
        var requests: [URLRequest] = []
        var unavailable = false
        let cache = ProjectIconCache(faviconLoader: ProjectFaviconLoader { request in
            requests.append(request)
            if unavailable { throw URLError(.cannotConnectToHost) }
            let url = try #require(request.url)
            let data = url.path == "" ? Data(#"<link rel="icon" href="/brand.png">"#.utf8) : png
            return (data, try httpResponse(url: url))
        })
        let fallback = try #require(cache.favicon(for: project)?.tiffRepresentation)
        let now = Date()
        for task in cache.refreshSiteFavicons(for: [project], at: now) { await task.value }
        let declared = try #require(cache.favicon(for: project)?.tiffRepresentation)
        #expect(declared != fallback)
        #expect(cache.faviconRevision == 1)

        for task in cache.refreshSiteFavicons(for: [project], at: now.addingTimeInterval(10)) { await task.value }
        #expect(requests.count == 2, "The menu refresh must not repeatedly fetch the same site.")
        png = try faviconPNG(color: .systemBlue)
        project.port = 3026
        for task in cache.refreshSiteFavicons(for: [project], at: now.addingTimeInterval(20)) { await task.value }
        let updated = try #require(cache.favicon(for: project)?.tiffRepresentation)
        #expect(updated != declared)
        #expect(requests.last?.url?.port == 3026)

        unavailable = true
        for task in cache.refreshSiteFavicons(for: [project], at: now.addingTimeInterval(81)) { await task.value }
        #expect(cache.favicon(for: project)?.tiffRepresentation == updated)
        cache.refreshSiteFavicons(for: [])
        #expect(cache.favicon(for: project)?.tiffRepresentation == updated)
    }

    private func makeProject(path: String = "/tmp/favicon-fixture") -> LocalProject {
        LocalProject(name: "favicon-fixture", path: path, kind: .astro, packageManager: .npm,
                     port: 3025, commandTemplate: "npm run dev")
    }

    private func httpResponse(url: URL, status: Int = 200) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
    }

    private func faviconPNG(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
