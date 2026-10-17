import Foundation

/// Wire format for a folder sent between machines: a framed stream that only this
/// codebase writes and reads (no link types to forget about).
///
///     "ADPK1\n"
///     records: type byte, then (for d/f) BE UInt32 path length + UTF-8 relative path
///       d  directory
///       f  file, then BE UInt64 size + that many bytes
///       e  end of stream (no path)
public enum DropPack {
    public enum Failure: Error, Equatable {
        case malformed(String)
        case tooLarge(limit: Int64)
    }

    static let magic = Data("ADPK1\n".utf8)
    static let maxPathBytes = 4096
    /// Cap on d + f records per pack, so an untrusted sender can't amplify inodes/memory with empty entries.
    public static let maxEntries = 10_000
    private static let chunk = 64 * 1024

    // MARK: - Write

    /// Rejects (AgentDropError.invalid) a source folder containing anything but regular files and directories.
    public static func write(folder: URL, to output: URL) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: output.path, contents: nil) else {
            throw AgentDropError.invalid("Can't create \(output.path)")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.write(contentsOf: magic)
        try writeDirectory(folder, relative: "", to: handle)
        try handle.write(contentsOf: Data([UInt8(ascii: "e")]))
    }

    private static func writeDirectory(_ dir: URL, relative: String, to out: FileHandle) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        for name in names {
            let url = dir.appendingPathComponent(name)
            let path = relative.isEmpty ? name : relative + "/" + name
            guard Data(path.utf8).count <= maxPathBytes else {
                throw AgentDropError.invalid("Path too long to send: \(path)")
            }
            let attributes = try fm.attributesOfItem(atPath: url.path) // does not follow links
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                try out.write(contentsOf: header("d", path))
                try writeDirectory(url, relative: path, to: out)
            case .typeRegular:
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                try out.write(contentsOf: header("f", path) + be64(size))
                try copy(url, count: size, to: out)
            default:
                throw AgentDropError.invalid("Can't send \(path): only regular files and folders are supported")
            }
        }
    }

    private static func copy(_ file: URL, count: UInt64, to out: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var remaining = count
        while remaining > 0 {
            let want = Int(min(UInt64(chunk), remaining))
            guard let data = try input.read(upToCount: want), !data.isEmpty else {
                throw AgentDropError.invalid("\(file.lastPathComponent) changed while it was being read")
            }
            try out.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    private static func header(_ type: Character, _ path: String) -> Data {
        let bytes = Data(path.utf8)
        return Data([type.asciiValue!]) + be32(UInt32(bytes.count)) + bytes
    }

    private static func be32(_ v: UInt32) -> Data {
        Data((0..<4).map { UInt8((v >> UInt32(24 - 8 * $0)) & 0xFF) })
    }

    private static func be64(_ v: UInt64) -> Data {
        Data((0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) })
    }

    // MARK: - Unpack

    /// Unpacks into `destination` (must not exist; created). Total file bytes > maxBytes → .tooLarge.
    /// On any failure the partially written `destination` is removed.
    public static func unpack(_ pack: URL, into destination: URL, maxBytes: Int64) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw Failure.malformed("Destination already exists")
        }
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: pack) } catch {
            throw Failure.malformed("Can't read the pack: \(error.localizedDescription)")
        }
        defer { try? input.close() }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try unpackRecords(input, into: destination, maxBytes: maxBytes)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    private static func unpackRecords(_ input: FileHandle, into root: URL, maxBytes: Int64) throws {
        guard try readExactly(input, magic.count) == magic else { throw Failure.malformed("Bad header") }
        var seen = Set<String>()
        var directories = Set<String>()
        var total: Int64 = 0
        var entries = 0

        while true {
            let type = try readExactly(input, 1)[0]
            if type == UInt8(ascii: "e") {
                guard try input.read(upToCount: 1)?.isEmpty ?? true else {
                    throw Failure.malformed("Data after end of stream")
                }
                return
            }
            guard type == UInt8(ascii: "d") || type == UInt8(ascii: "f") else {
                throw Failure.malformed("Unknown record type \(type)")
            }
            entries += 1
            guard entries <= maxEntries else {
                throw Failure.malformed("too many entries (limit \(maxEntries))")
            }
            let length = try be32(readExactly(input, 4))
            guard length <= maxPathBytes else { throw Failure.malformed("Path too long") }
            guard let path = String(data: try readExactly(input, Int(length)), encoding: .utf8) else {
                throw Failure.malformed("Path is not UTF-8")
            }
            try validate(path)
            guard seen.insert(path).inserted else { throw Failure.malformed("Duplicate path: \(path)") }
            if let slash = path.lastIndex(of: "/") {
                guard directories.contains(String(path[..<slash])) else {
                    throw Failure.malformed("Undeclared parent directory for \(path)")
                }
            }
            let target = root.appendingPathComponent(path)

            if type == UInt8(ascii: "d") {
                directories.insert(path)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                continue
            }

            let size = try be64(readExactly(input, 8))
            guard size <= UInt64(Int64.max), Int64(size) <= maxBytes - total else {
                throw Failure.tooLarge(limit: maxBytes)
            }
            total += Int64(size)
            try writeFile(target, size: size, from: input)
        }
    }

    private static func validate(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw Failure.malformed("Invalid path")
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." {
                throw Failure.malformed("Invalid path component in \(path)")
            }
        }
    }

    private static func writeFile(_ url: URL, size: UInt64, from input: FileHandle) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw Failure.malformed("Can't create \(url.lastPathComponent)") }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? out.close() }
        var remaining = size
        while remaining > 0 {
            let data = try readExactly(input, Int(min(UInt64(chunk), remaining)))
            try out.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    private static func readExactly(_ input: FileHandle, _ count: Int) throws -> Data {
        if count == 0 { return Data() }
        var data = Data()
        while data.count < count {
            guard let part = try input.read(upToCount: count - data.count), !part.isEmpty else {
                throw Failure.malformed("Truncated pack")
            }
            data.append(part)
        }
        return data
    }

    private static func be32(_ data: Data) -> UInt32 {
        data.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func be64(_ data: Data) -> UInt64 {
        data.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
