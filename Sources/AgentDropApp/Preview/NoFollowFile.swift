import Foundation

/// Reads files inside the drop folder without ever following a symlink, at any level
/// (spec §3). Each path component is opened relative to its parent's descriptor with
/// `O_NOFOLLOW`, so a link swapped in after an earlier check is refused at read time
/// rather than read through. The drop folder itself (`root`) is opened as configured.
public enum NoFollowFile {
    /// The file at `relativePath` (`/`-separated) under `root`, at most `maxBytes` of it.
    /// nil for a link anywhere along the path, a non-regular file, `.`/`..`, or a read error.
    public static func read(_ relativePath: String, under root: URL, maxBytes: Int? = nil) -> Data? {
        guard let fd = openRegularFile(relativePath, under: root) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if let maxBytes { return try? handle.read(upToCount: maxBytes) ?? Data() }
        return try? handle.readToEnd() ?? Data()
    }

    /// Quick Look opens paths itself, so it gets a private copy made from a no-follow
    /// descriptor: an APFS clone when possible (instant, no extra space), else a copy.
    /// The copy keeps the file's name so Quick Look picks the right previewer.
    public static func snapshot(_ relativePath: String, under root: URL) -> URL? {
        guard let fd = openRegularFile(relativePath, under: root) else { return nil }
        defer { close(fd) }
        let name = (relativePath as NSString).lastPathComponent
        let directory = snapshotRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        // fclonefileat clones exactly the open file: there is no path left to swap.
        if fclonefileat(fd, AT_FDCWD, target.path, 0) == 0 { return target }
        guard FileManager.default.createFile(atPath: target.path, contents: nil),
              let output = FileHandle(forWritingAtPath: target.path) else {
            discardSnapshot(target)
            return nil
        }
        defer { try? output.close() }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty {
            guard (try? output.write(contentsOf: chunk)) != nil else {
                discardSnapshot(target)
                return nil
            }
        }
        return target
    }

    public static func discardSnapshot(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Snapshots live here; the app clears it at launch.
    public static var snapshotRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AgentDropPreview", isDirectory: true)
    }

    /// A descriptor for a regular file, opened component by component without following
    /// links. `O_NONBLOCK` keeps a FIFO from blocking the open; it is refused by `fstat`.
    static func openRegularFile(_ relativePath: String, under root: URL) -> Int32? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(directory)
            guard next >= 0 else { return nil }
            directory = next
        }
        let fd = openat(directory, parts[parts.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        close(directory)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return nil
        }
        return fd
    }
}
