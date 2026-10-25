import AppKit
import Foundation
import Testing
@testable import LocalMonitor

@MainActor
struct ProjectOfflineFaviconTests {
    @Test(arguments: [
        ("src/layouts/Base.astro", "/media/7HZjWDAP5tQFjsBtSjwMW3j3Jss.png"),
        ("src/layouts/Layout.astro", "/images/macvm-icon.png"),
        ("index.html", "/assets/brand.png")
    ])
    func findsDeclaredNestedIconsWithoutStartingTheSite(layout: String, icon: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(#"<link rel="icon" href="\#(icon)">"#, to: layout)
        try fixture.write(png(), to: "public" + icon)

        let cache = ProjectIconCache(storageDirectoryURL: fixture.cacheURL)

        #expect(cache.favicon(for: fixture.project)?.size == NSSize(width: 16, height: 16))
    }

    @Test
    func prefersTheDeclaredIconOverAConventionalPlaceholder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(#"<link rel="icon" href="brand.png"><base href="/images/">"#,
                          to: "src/layouts/Layout.astro")
        try fixture.write(png(), to: "public/images/brand.png")
        try fixture.write(png(size: 32), to: "public/favicon.png")

        let cache = ProjectIconCache(storageDirectoryURL: fixture.cacheURL)

        #expect(cache.favicon(for: fixture.project)?.size.width == 16)
    }

    @Test
    func ignoresInactiveMarkupAndPathsOutsidePublic() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in ["comment", "script", "frontmatter", "external"] {
            try fixture.write(png(), to: "public/images/\(name).png")
        }
        try fixture.write(png(), to: "private.png")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("public/images/escape.png"),
            withDestinationURL: fixture.root.appendingPathComponent("private.png")
        )
        try fixture.write("""
            ---
            const example = '<link rel="icon" href="/images/frontmatter.png">';
            ---
            <!-- <link rel="icon" href="/images/comment.png"> -->
            <script>const example = '<link rel="icon" href="/images/script.png">';</script>
            <link rel="icon" href="https://cdn.example.com/images/external.png">
            <link rel="icon" href="/%2e%2e/private.png">
            <link rel="icon" href="/images/escape.png">
            """, to: "src/layouts/Layout.astro")

        #expect(ProjectLocalFaviconResolver().iconURLs(for: fixture.project).isEmpty)
    }

    @Test
    func refreshesWhenTheDeclarationOrTheIconFileChangesOffline() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let layout = "src/layouts/Layout.astro"
        try fixture.write(#"<link rel="icon" href="/images/first.png">"#, to: layout)
        try fixture.write(png(), to: "public/images/first.png")
        try fixture.write(png(size: 24), to: "public/images/second.png")
        let cache = ProjectIconCache(storageDirectoryURL: fixture.cacheURL)
        #expect(cache.favicon(for: fixture.project)?.size.width == 16)

        try fixture.write(#"<link rel="icon" href="/images/second.png">"#, to: layout)
        cache.refreshFavicons(for: [fixture.project])
        #expect(cache.favicon(for: fixture.project)?.size.width == 24)

        try fixture.write(png(size: 32), to: "public/images/second.png")
        cache.refreshFavicons(for: [fixture.project])
        #expect(cache.favicon(for: fixture.project)?.size.width == 32)
    }

    @Test(.tags(.networking))
    func restoresDownloadedIconsInAFreshCacheWithTheSiteOffline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = ProjectIconCache(faviconLoader: onlineLoader(png: try png()),
                                     storageDirectoryURL: fixture.cacheURL)
        for task in cache.refreshSiteFavicons(for: [fixture.project]) { await task.value }
        cache.refreshSiteFavicons(for: [])

        var requests = 0
        let restarted = ProjectIconCache(faviconLoader: ProjectFaviconLoader { _ in
            requests += 1
            throw URLError(.cannotConnectToHost)
        }, storageDirectoryURL: fixture.cacheURL)
        #expect(restarted.favicon(for: fixture.project)?.size.width == 16)
        #expect(requests == 0, "Reading an offline icon must not require a server request.")

        for task in restarted.refreshSiteFavicons(for: [fixture.project]) { await task.value }
        #expect(restarted.favicon(for: fixture.project)?.size.width == 16)

        var other = fixture.project
        other.path += "/other"
        #expect(restarted.favicon(for: other) == nil)
    }

    @Test(.tags(.networking))
    func prefersCurrentLocalFilesOverAnOlderDiskFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = ProjectIconCache(faviconLoader: onlineLoader(png: try png()),
                                     storageDirectoryURL: fixture.cacheURL)
        for task in cache.refreshSiteFavicons(for: [fixture.project]) { await task.value }
        try fixture.write(png(size: 32), to: "public/favicon.png")

        let restarted = ProjectIconCache(storageDirectoryURL: fixture.cacheURL)

        #expect(restarted.favicon(for: fixture.project)?.size.width == 32)
    }

    @Test
    func ignoresCorruptDiskEntries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = ProjectFaviconStore(directoryURL: fixture.cacheURL)
        store.save(try #require(NSImage(data: png())), for: fixture.project.path)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.cacheURL, includingPropertiesForKeys: nil)
        try Data("invalid image".utf8).write(to: #require(files.first), options: .atomic)

        #expect(ProjectIconCache(storageDirectoryURL: fixture.cacheURL).favicon(for: fixture.project) == nil)
    }

    @Test(.tags(.networking))
    func prunesRemovedProjectsButKeepsIconsWhenTheyGoOffline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cache = ProjectIconCache(faviconLoader: onlineLoader(png: try png()),
                                     storageDirectoryURL: fixture.cacheURL)
        for task in cache.refreshSiteFavicons(for: [fixture.project]) { await task.value }
        cache.refreshSiteFavicons(for: [])
        cache.refreshFavicons(for: [fixture.project])
        #expect(ProjectIconCache(storageDirectoryURL: fixture.cacheURL).favicon(for: fixture.project) != nil)

        cache.refreshFavicons(for: [])

        #expect(ProjectIconCache(storageDirectoryURL: fixture.cacheURL).favicon(for: fixture.project) == nil)
    }

    @Test(.tags(.networking))
    func stillDisplaysFetchedIconsWhenTheDiskCacheCannotBeWritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("This is a file, not a directory.", to: "cache")
        let cache = ProjectIconCache(faviconLoader: onlineLoader(png: try png()),
                                     storageDirectoryURL: fixture.cacheURL)

        for task in cache.refreshSiteFavicons(for: [fixture.project]) { await task.value }

        #expect(cache.favicon(for: fixture.project)?.size.width == 16)
    }

    private func onlineLoader(png: Data) -> ProjectFaviconLoader {
        ProjectFaviconLoader { request in
            let url = try #require(request.url)
            let data = url.path.isEmpty ? Data(#"<link rel="icon" href="/media/site.png">"#.utf8) : png
            return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)))
        }
    }

    private func png(size: Int = 16) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<size {
            for y in 0..<size { bitmap.setColor(.systemGreen, atX: x, y: y) }
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private struct Fixture {
        let root: URL
        let project: LocalProject
        var cacheURL: URL { root.appendingPathComponent("cache", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            project = LocalProject(name: "offline-favicon", path: root.path, kind: .astro,
                                   packageManager: .npm, port: 3025, commandTemplate: "npm run dev")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ text: String, to path: String) throws {
            try write(Data(text.utf8), to: path)
        }

        func write(_ data: Data, to path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
