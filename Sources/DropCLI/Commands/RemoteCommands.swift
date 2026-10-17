import AgentDropCore
import AgentDropServer
import ArgumentParser
import Foundation

/// `drop remote …`: the other Macs on the tailnet this one sends drops to (`drop add --to`).
struct RemoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote",
        abstract: "Manage the other Macs this one can send drops to (drop add --to).",
        subcommands: [AddRemote.self, ListRemotes.self, RemoveRemote.self, TestRemote.self]
    )

    struct AddRemote: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add", abstract: "Save (or replace) a remote: its URL and its sender key.")
        @Argument(help: "Name for the remote, e.g. laptop.") var name: String
        @Option(help: "The receiving Mac's tailnet URL, e.g. http://laptop.tail1234.ts.net:47400.") var url: String
        @Option(help: "The receiving Mac's sender key (64 hex characters).") var key: String
        @OptionGroup var output: JSONOption

        func run() throws {
            let context = CLIContext.current
            try RemoteCommand.validate(name: name)
            let remoteURL = try RemoteCommand.validate(url: url)
            guard key.wholeMatch(of: /[0-9A-Fa-f]{64}/) != nil else {
                throw AgentDropError.invalid("The key must be 64 hex characters (copy it from the receiving Mac's Agent Drop Settings)")
            }
            let file = RemotesFile(configDir: context.config.configDir)
            var remotes = try file.load()
            remotes[name] = TailnetClient.Remote(url: remoteURL, key: key)
            try file.save(remotes)
            if output.json {
                Output.emitJSON(RemoteSummary(name: name, url: remoteURL.absoluteString))
            } else {
                Output.emit("Saved remote '\(Output.terminalSafe(name))'")
            }
        }
    }

    struct ListRemotes: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List saved remotes (name and URL; keys are never shown).")
        @OptionGroup var output: JSONOption

        func run() throws {
            let remotes = try RemotesFile(configDir: CLIContext.current.config.configDir).load()
            let rows = remotes.keys.sorted().map { RemoteSummary(name: $0, url: remotes[$0]!.url.absoluteString) }
            if output.json {
                Output.emitJSON(rows)
            } else {
                rows.forEach { Output.emit(Output.terminalSafe($0.name) + "\t" + Output.terminalSafe($0.url)) }
            }
        }
    }

    struct RemoveRemote: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Forget a saved remote.")
        @Argument(help: "The remote's name.") var name: String
        @OptionGroup var output: JSONOption

        func run() throws {
            let file = RemotesFile(configDir: CLIContext.current.config.configDir)
            var remotes = try file.load()
            guard remotes.removeValue(forKey: name) != nil else {
                throw AgentDropError.notFound("No remote named '\(name)'")
            }
            try file.save(remotes)
            if output.json {
                Output.emitJSON(["removed": name])
            } else {
                Output.emit("Removed remote '\(Output.terminalSafe(name))'")
            }
        }
    }

    struct TestRemote: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "test", abstract: "Check that a remote is reachable and accepts its key.")
        @Argument(help: "The remote's name, or 'env'.") var name: String
        @OptionGroup var output: JSONOption

        func run() async throws {
            let context = CLIContext.current
            let remote = try context.remote(named: name)
            try await TailnetClient(remoteName: name, remote: remote).ping()
            if output.json {
                Output.emitJSON(RemoteSummary(name: name, url: remote.url.absoluteString))
            } else {
                Output.emit("'\(Output.terminalSafe(name))' is reachable and accepted the key.")
            }
        }
    }

    struct RemoteSummary: Encodable {
        let name: String
        let url: String
    }

    static func validate(name: String) throws {
        guard name.wholeMatch(of: /^[A-Za-z0-9._-]{1,64}$/) != nil else {
            throw AgentDropError.invalid("A remote name is 1–64 letters, digits, '.', '_' or '-'")
        }
        guard name != "env" else {
            throw AgentDropError.invalid("'env' is reserved: `--to env` reads AGENT_DROP_REMOTE_URL and AGENT_DROP_REMOTE_KEY")
        }
    }

    static func validate(url raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, url.port != nil else {
            throw AgentDropError.invalid("The URL must be http:// or https:// with a host and a port, e.g. http://laptop.tail1234.ts.net:47400")
        }
        return url
    }
}
