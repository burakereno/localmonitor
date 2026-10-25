import AppKit
import CryptoKit
import Foundation

@MainActor
struct ProjectFaviconStore {
    private let directoryURL: URL?
    private let fileManager = FileManager.default

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Local Monitor/Favicons", isDirectory: true)
    }

    func image(for projectPath: String) -> NSImage? {
        guard let url = fileURL(for: projectPath),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= 2_000_000,
              let data = try? Data(contentsOf: url), data.count <= 2_000_000,
              let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    func save(_ image: NSImage, for projectPath: String) {
        guard let url = fileURL(for: projectPath),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]), data.count <= 2_000_000 else { return }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // A disk cache failure must not prevent displaying the in-memory icon.
        }
    }

    func retainImages(for projectPaths: Set<String>) {
        guard let directoryURL,
              let files = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        let names = Set(projectPaths.compactMap { fileURL(for: $0)?.lastPathComponent })
        for file in files where file.pathExtension == "png" && !names.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func fileURL(for projectPath: String) -> URL? {
        let path = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directoryURL?.appendingPathComponent(key).appendingPathExtension("png")
    }
}
