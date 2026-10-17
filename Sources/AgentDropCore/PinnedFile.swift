import Foundation

/// Reads a single file the way `DropPack` reads a folder: through a pinned parent descriptor and a
/// no-follow open, so a file (or parent) swapped for a symlink after it was checked is never followed.
public enum PinnedFile {
    /// Copies the regular file at `file` into a fresh 0700 directory under `directory` (file mode 0600)
    /// and returns the copy's URL. The caller removes the copy's parent directory when done with it.
    /// A symlinked parent directory is followed (the person chose that path); the file itself never is.
    /// Throws AgentDropError.invalid if the file isn't regular or changes while it is read.
    public static func snapshot(of file: URL, into directory: URL) throws -> URL {
        try snapshot(of: file, into: directory, afterCheck: nil)
    }

    /// `afterCheck` is a test hook run after the file's type is checked, before it is opened.
    static func snapshot(of file: URL, into directory: URL, afterCheck: ((URL) -> Void)?) throws -> URL {
        let name = file.lastPathComponent
        let unreadable = AgentDropError.invalid("Can't read \(file.path)")
        let notRegular = AgentDropError.invalid("\(name) is not a regular file")
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { throw notRegular }
        guard let parentPath = realpath(file.deletingLastPathComponent().path, nil) else { throw unreadable }
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        free(parentPath)
        guard parent >= 0 else { throw unreadable }
        defer { close(parent) }

        // Check the type without following links, so FIFOs and devices are never opened.
        var checked = stat()
        guard fstatat(parent, name, &checked, AT_SYMLINK_NOFOLLOW) == 0 else { throw unreadable }
        guard checked.st_mode & S_IFMT == S_IFREG else { throw notRegular }
        afterCheck?(file)
        // Pin the file: O_NOFOLLOW refuses a swapped-in symlink, and fstat must match what was checked.
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? notRegular : unreadable }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw unreadable }
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_dev == checked.st_dev, opened.st_ino == checked.st_ino
        else { throw AgentDropError.invalid("\(name) changed while it was being read") }

        let snapshotDirectory = directory.appendingPathComponent("agentdrop-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(snapshotDirectory.path, 0o700) == 0 else {
            throw AgentDropError.invalid("Can't create \(snapshotDirectory.path)")
        }
        do {
            let snapshot = snapshotDirectory.appendingPathComponent("snapshot")
            let out = open(snapshot.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw AgentDropError.invalid("Can't create \(snapshot.path)") }
            let handle = FileHandle(fileDescriptor: out, closeOnDealloc: true)
            defer { try? handle.close() }
            try DropPack.copy(fd, path: name, count: UInt64(max(opened.st_size, 0)), to: handle)
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw error
        }
    }
}
