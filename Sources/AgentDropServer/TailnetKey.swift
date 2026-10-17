import Foundation

/// The sender key (`<configDir>/tailnet.json`, `{"key": "<hex>"}`). Created only by the
/// Settings toggle; it never rotates on restart.
public struct TailnetKeyFile: Sendable {
    public let url: URL

    public init(configDir: URL) {
        url = configDir.appendingPathComponent("tailnet.json")
    }

    private struct Body: Codable { var key: String }

    /// `nil` when the file is absent, unreadable or holds anything but 64 lowercase hex characters.
    public func read() -> String? {
        guard let data = try? Data(contentsOf: url),
              let key = (try? JSONDecoder().decode(Body.self, from: data))?.key,
              key.utf8.count == 64,
              key.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
        else { return nil }
        return key
    }

    /// The existing key if there is one, else a new one.
    public func create() throws -> String {
        if let key = read() { return key }
        return try regenerate()
    }

    /// Always a new key.
    public func regenerate() throws -> String {
        let key = ServerInfo.newToken()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFile.write(try encoder.encode(Body(key: key)), to: url)
        return key
    }
}
