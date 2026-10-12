import AgentDropCore
import ArgumentParser
import Foundation

public enum DropCLI {
    /// Parses and runs one invocation; returns the process exit code (spec §4 Global rules).
    public static func run(_ arguments: [String], context: CLIContext) -> Int32 {
        let wantsJSON = arguments.contains("--json")
        return CLIContext.$current.withValue(context) {
            do {
                var command = try DropCommand.parseAsRoot(arguments)
                try command.run()
                return 0
            } catch let error as AgentDropError {
                report(error.message, code: error.exitCode, json: wantsJSON, context: context)
                return error.exitCode
            } catch {
                if DropCommand.exitCode(for: error) == .success {
                    context.stdout.line(DropCommand.fullMessage(for: error))
                    return 0
                }
                report(DropCommand.fullMessage(for: error), code: 1, json: wantsJSON, context: context)
                return 1
            }
        }
    }

    private struct ErrorJSON: Encodable {
        let error: String
        let code: Int32
    }

    private static func report(_ message: String, code: Int32, json: Bool, context: CLIContext) {
        if json {
            context.stdout.line(Output.jsonString(ErrorJSON(error: message, code: code)))
        } else {
            context.stderr.line("drop: \(message)")
        }
    }
}

struct DropCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drop",
        abstract: "Agent Drop: a shared drop folder with context, for humans and coding agents.",
        version: "0.1.0",
        subcommands: [Add.self, Show.self, Cat.self, PathCommand.self, ListCommand.self, Latest.self,
                      Inbox.self, Where.self, Config.self]
    )
}

struct JSONOption: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable JSON output.")
    var json = false
}
