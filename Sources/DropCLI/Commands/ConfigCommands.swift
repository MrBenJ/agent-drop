import AgentDropCore
import ArgumentParser
import Foundation

struct Where: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "where", abstract: "Print the drop folder path in use.")
    @OptionGroup var output: JSONOption

    func run() throws {
        let context = CLIContext.current
        let folder = context.config.folderURL(try context.config.load()).path
        if output.json { Output.emitJSON(["folder": folder]) } else { Output.emit(folder) }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change settings in config.json.",
        subcommands: [SetFolder.self, SetRetention.self, Show.self]
    )

    struct SetFolder: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-folder", abstract: "Set the drop folder (created if needed).")
        @Argument(help: "Folder path.") var path: String
        @OptionGroup var output: JSONOption

        func run() throws {
            let context = CLIContext.current
            let url = context.resolvePath(path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw AgentDropError.invalid("\(url.path) exists and is not a folder")
            }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw AgentDropError.invalid("Can't create \(url.path): \(error.localizedDescription)")
            }
            try context.config.setFolder(url)
            if output.json { Output.emitJSON(["folder": url.path]) } else { Output.emit(url.path) }
        }
    }

    struct SetRetention: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-retention",
            abstract: "How long the change log keeps entries: whole days ≥ 1, or 'forever'.")
        @Argument(help: "Days (≥ 1) or 'forever'.") var value: String
        @OptionGroup var output: JSONOption

        func run() throws {
            guard let retention = Retention(argument: value) else {
                throw AgentDropError.invalid("retention must be a whole number of days ≥ 1, or 'forever'")
            }
            try CLIContext.current.config.setRetention(retention)
            if output.json { Output.emitJSON(["eventRetentionDays": retention.displayValue]) }
            else { Output.emit("eventRetentionDays: \(retention.displayValue)") }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show", abstract: "Print every config.json setting.")
        @OptionGroup var output: JSONOption

        static let disclosure = "Old entries in the change log are deleted as new changes come in. Your drops and files are never deleted."
        static let invalidWarning = "eventRetentionDays in config.json is invalid; using 30 days"

        func run() throws {
            let context = CLIContext.current
            let settings = try context.config.load()
            let snapshot = ConfigJSON(
                folder: context.config.folderURL(settings).path,
                retention: settings.eventRetentionDays,
                serverPort: settings.serverPort ?? AgentDropConfig.defaultServerPort,
                setupComplete: settings.setupComplete,
                confirmedFolder: settings.confirmedFolder,
                warnings: settings.retentionWasInvalid ? [Self.invalidWarning] : [])
            if output.json {
                Output.emitJSON(snapshot)
                return
            }
            let retention: String = switch settings.eventRetentionDays {
            case .forever: "forever"
            case .days(let n): "\(n)"
            }
            Output.emit("folder:             \(snapshot.folder)")
            Output.emit("eventRetentionDays: \(retention)")
            Output.emit("                    \(Self.disclosure)")
            Output.emit("serverPort:         \(snapshot.serverPort)")
            Output.emit("setupComplete:      \(snapshot.setupComplete)")
            Output.emit("confirmedFolder:    \(snapshot.confirmedFolder ?? "-")")
            for warning in snapshot.warnings { context.stderr.line("warning: \(warning)") }
        }
    }
}

struct ConfigJSON: Encodable {
    let folder: String
    let retention: Retention
    let serverPort: Int
    let setupComplete: Bool
    let confirmedFolder: String?
    let warnings: [String]

    enum Key: String, CodingKey {
        case folder, eventRetentionDays, serverPort, setupComplete, confirmedFolder, warnings
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(folder, forKey: .folder)
        switch retention {
        case .forever: try c.encode("forever", forKey: .eventRetentionDays)
        case .days(let n): try c.encode(n, forKey: .eventRetentionDays)
        }
        try c.encode(serverPort, forKey: .serverPort)
        try c.encode(setupComplete, forKey: .setupComplete)
        try c.encode(confirmedFolder, forKey: .confirmedFolder)
        try c.encode(warnings, forKey: .warnings)
    }
}
