import Foundation

/// Event-log retention (spec §5.1): a whole number of days ≥ 1, or forever.
public enum Retention: Equatable, Sendable {
    case days(Int)
    case forever

    public static let `default` = Retention.days(30)

    /// Parses CLI input: "forever" or a whole number ≥ 1.
    public init?(argument: String) {
        if argument == "forever" {
            self = .forever
        } else if let days = Int(argument), days >= 1 {
            self = .days(days)
        } else {
            return nil
        }
    }

    public var displayValue: String {
        switch self {
        case .forever: "forever"
        case .days(let n): "\(n) days"
        }
    }
}

public struct AgentDropConfig: Equatable, Sendable {
    public static let defaultServerPort = 47390

    public var folder: String? = nil
    public var eventRetentionDays: Retention = .default
    /// True when config.json held an invalid retention value (treated as 30; spec §5.1).
    public var retentionWasInvalid = false
    public var serverPort: Int? = nil
    public var setupComplete = false
    public var confirmedFolder: String? = nil

    public init() {}
}

/// Reads and writes `config.json`, the single source of truth for the folder (spec §3).
/// Paths are injected; the shipped binaries use `live()`. Unknown keys are preserved.
public struct ConfigStore: Sendable {
    public let configDir: URL
    public let homeDir: URL

    public init(configDir: URL, homeDir: URL) {
        self.configDir = configDir
        self.homeDir = homeDir
    }

    public static func live() -> ConfigStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ConfigStore(
            configDir: home.appendingPathComponent("Library/Application Support/AgentDrop", isDirectory: true),
            homeDir: home
        )
    }

    public var configFile: URL { configDir.appendingPathComponent("config.json") }
    public var defaultFolder: URL { homeDir.appendingPathComponent("AgentDrop", isDirectory: true) }

    public func load() throws -> AgentDropConfig {
        let dict = try readDict()
        var config = AgentDropConfig()
        config.folder = dict["folder"] as? String
        switch dict["eventRetentionDays"] {
        case nil:
            config.eventRetentionDays = .default
        case let value as String where value == "forever":
            config.eventRetentionDays = .forever
        case let value as NSNumber where Self.isWholeNumber(value) && value.intValue >= 1:
            config.eventRetentionDays = .days(value.intValue)
        default:
            config.eventRetentionDays = .default
            config.retentionWasInvalid = true
        }
        config.serverPort = dict["serverPort"] as? Int
        config.setupComplete = dict["setupComplete"] as? Bool ?? false
        config.confirmedFolder = dict["confirmedFolder"] as? String
        return config
    }

    public func folderURL(_ config: AgentDropConfig) -> URL {
        config.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
    }

    public func setFolder(_ url: URL) throws {
        var dict = try readDict()
        dict["folder"] = url.standardizedFileURL.path
        try writeDict(dict)
    }

    public func setRetention(_ retention: Retention) throws {
        var dict = try readDict()
        switch retention {
        case .forever: dict["eventRetentionDays"] = "forever"
        case .days(let n): dict["eventRetentionDays"] = n
        }
        try writeDict(dict)
    }

    private static func isWholeNumber(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue == n.doubleValue.rounded()
    }

    func readDict() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configFile.path) else { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: configFile))
        } catch {
            throw AgentDropError.invalid("Can't read \(configFile.path): \(error.localizedDescription)")
        }
        guard let dict = object as? [String: Any] else {
            throw AgentDropError.invalid("\(configFile.path) must contain a JSON object")
        }
        return dict
    }

    func writeDict(_ dict: [String: Any]) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configFile, options: .atomic)
    }
}
