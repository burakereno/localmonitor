import Darwin
import Foundation

enum ProjectCacheCleaner {
    static func remove(relativePaths: [String], in directory: URL) throws -> [String] {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let fd = open(root.path, flags)
        guard fd >= 0 else {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let rootHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        // Pin each parent directory before removing anything. A changed symlink cannot
        // redirect a later removal through an intermediate component of the original path.
        let targets = try relativePaths.compactMap { path -> (String, FileHandle, String)? in
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw CleanRestartError.unsafePath(path)
            }
            let candidate = root.appendingPathComponent(path)
            let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard contains(candidate, in: root), parent.path == root.path || contains(parent, in: root) else {
                throw CleanRestartError.unsafePath(path)
            }
            var handle = rootHandle
            for component in parent.pathComponents.dropFirst(root.pathComponents.count) {
                let next = openat(handle.fileDescriptor, component, flags)
                guard next >= 0 else {
                    if errno == ENOENT { return nil }
                    throw CleanRestartError.unsafePath(path)
                }
                handle = FileHandle(fileDescriptor: next, closeOnDealloc: true)
            }
            let name = candidate.lastPathComponent
            var info = stat()
            guard fstatat(handle.fileDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw CleanRestartError.removeFailed(path, String(cString: strerror(errno)))
            }
            return (path, handle, name)
        }
        guard !targets.isEmpty else { return [] }

        // Move the entry via its parent's descriptor before recursively removing it.
        let files = FileManager.default
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true)
        defer { _ = rmdir(staging.path) }
        let stagingFD = open(staging.path, flags)
        guard stagingFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(stagingFD) }

        var removed: [String] = []
        for (path, parent, name) in targets {
            let stagedName = UUID().uuidString
            guard renameat(parent.fileDescriptor, name, stagingFD, stagedName) == 0 else {
                if errno == ENOENT { continue }
                throw CleanRestartError.removeFailed(path, String(cString: strerror(errno)))
            }
            let staged = staging.appendingPathComponent(stagedName)
            do {
                try files.removeItem(at: staged)
                removed.append(path)
            } catch {
                let restored = renameatx_np(stagingFD, stagedName, parent.fileDescriptor, name, UInt32(RENAME_EXCL)) == 0
                let message = restored ? error.localizedDescription : "\(error.localizedDescription) Remaining files: \(staged.path)"
                throw CleanRestartError.removeFailed(path, message)
            }
        }
        return removed
    }

    static func contains(_ url: URL, in directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return target.count > root.count && target.starts(with: root)
    }
}
