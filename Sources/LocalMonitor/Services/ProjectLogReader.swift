import Darwin
import Foundation

actor ProjectLogReader {
    private struct Signature: Equatable {
        let size: Int
        let modified: Date
        let fileNumber: UInt64
    }

    private var lastRead: (url: URL, signature: Signature, lines: [String])?

    func lines(at url: URL) -> [String]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber else { return nil }
        let signature = Signature(size: size.intValue, modified: modified, fileNumber: number.uint64Value)
        if let lastRead, lastRead.url == url, lastRead.signature == signature { return lastRead.lines }
        let lines = ProjectProcessManager.logLines(at: url)
        lastRead = (url, signature, lines)
        return lines
    }

    func rotateLargeLogs(at urls: [URL]) async {
        for url in urls {
            guard !Task.isCancelled else { return }
            await rotateIfNeeded(at: url)
        }
    }

    private func rotateIfNeeded(at url: URL) async {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size > ProjectProcessManager.maximumLogBytes else { return }
        let source = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard source >= 0 else { return }
        defer { close(source) }
        var opened = stat()
        guard fstat(source, &opened) == 0, Self.sameFile(opened, info) else { return }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".rotate-\(UUID().uuidString)")
        let output = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard output >= 0 else { return }
        defer { close(output); unlink(temporary.path) }
        guard fcopyfile(source, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { return }
        let previous = url.deletingPathExtension().appendingPathExtension("previous.log")

        // Launch, Clear, and Remove can run during the copy. Commit on their actor
        // only if the live file still matches the snapshot that was copied.
        let snapshot = opened
        let rotated = await MainActor.run {
            var current = stat()
            guard !Task.isCancelled, lstat(url.path, &current) == 0, Self.sameFile(current, snapshot),
                  rename(temporary.path, previous.path) == 0 else { return false }
            return ftruncate(source, 0) == 0
        }
        if rotated, lastRead?.url == url { lastRead = nil }
    }

    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_nlink == 1 && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }
}
