import Foundation

/// `server.json` (spec §5.2): written by the app, read by `drop watch`.
public struct ServerInfo: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running
        case noPort = "no-port"
    }

    public var status: Status
    public var port: Int?
    public var token: String?
    public var pid: Int32

    public static func running(port: Int, token: String, pid: Int32) -> ServerInfo {
        ServerInfo(status: .running, port: port, token: token, pid: pid)
    }

    public static func noPort(pid: Int32) -> ServerInfo {
        ServerInfo(status: .noPort, port: nil, token: nil, pid: pid)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// A live process, including one owned by another user (EPERM).
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// 32 random bytes as hex. A new one for every server start.
    public static func newToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }
}

/// Reads and writes `<configDir>/server.json` with permissions 0600.
public struct ServerInfoFile: Sendable {
    public let url: URL

    public init(configDir: URL) {
        url = configDir.appendingPathComponent("server.json")
    }

    /// `nil` when the file is absent or unreadable: the app is treated as not running.
    public func read() -> ServerInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ServerInfo.self, from: data)
    }

    /// Written to a private temp file, then renamed over the old one, so readers never
    /// see a partial file and the token is never readable by other users.
    public func write(_ info: ServerInfo) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".server.json.\(UUID().uuidString)")
        try Self.writePrivately(try info.encoded(), to: temp)
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Creates `target` with mode 0600 from the first instant (O_CREAT|O_EXCL), so the
    /// token is never readable by others, not even between create and chmod.
    static func writePrivately(_ data: Data, to target: URL) throws {
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        fchmod(fd, 0o600) // exact mode even under an unusual umask
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
