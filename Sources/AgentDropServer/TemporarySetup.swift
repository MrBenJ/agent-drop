import AgentDropCore
import Foundation

/// For `agentdrop-devhost` only, until the app exists (Plan 3): marks setup complete and
/// confirms a protected folder for as long as the dev host runs, then puts both keys back
/// exactly as they were (absent keys are removed; a config.json that didn't exist is
/// deleted again), so the app's real first-run setup still happens later.
public struct TemporarySetup: Sendable {
    private enum Original: Sendable, Equatable {
        case absent
        case value(String) // JSON text of the original value
    }

    let config: ConfigStore
    private let fileExisted: Bool
    private let originals: [String: Original]

    public var changedAnything: Bool { !originals.isEmpty }

    public static func apply(to config: ConfigStore) throws -> TemporarySetup {
        let settings = try config.load()
        let fileExisted = FileManager.default.fileExists(atPath: config.configFile.path)
        let dict = try readDict(config)
        var originals: [String: Original] = [:]
        func remember(_ key: String) {
            originals[key] = dict[key].flatMap(encode).map(Original.value) ?? .absent
        }
        do {
            if !settings.setupComplete {
                remember("setupComplete")
                try config.setSetupComplete(true)
            }
            if config.folderNeedsConfirmation(settings) {
                remember("confirmedFolder")
                try config.setConfirmedFolder(config.folderURL(settings))
            }
        } catch {
            // Undo whatever part already landed before reporting the failure.
            TemporarySetup(config: config, fileExisted: fileExisted, originals: originals).restore()
            throw error
        }
        return TemporarySetup(config: config, fileExisted: fileExisted, originals: originals)
    }

    public func restore() {
        guard !originals.isEmpty, var dict = try? Self.readDict(config) else { return }
        for (key, original) in originals {
            switch original {
            case .absent: dict[key] = nil
            case .value(let json): dict[key] = Self.decode(json)
            }
        }
        if dict.isEmpty && !fileExisted {
            try? FileManager.default.removeItem(at: config.configFile)
            return
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: config.configFile, options: .atomic)
    }

    private static func readDict(_ config: ConfigStore) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: config.configFile) else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func encode(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private static func decode(_ json: String) -> Any? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [Any])?.first
    }
}
