import AgentDropCore
import ArgumentParser
import Foundation

public enum DropCLI {
    /// Parses and runs one invocation; returns the process exit code (spec §4 Global rules).
    /// Synchronous commands only (`drop watch` needs `runAsync`).
    public static func run(_ arguments: [String], context: CLIContext) -> Int32 {
        let wantsJSON = arguments.contains("--json")
        return CLIContext.$current.withValue(context) {
            do {
                var command = try DropCommand.parseAsRoot(arguments)
                guard !(command is AsyncParsableCommand) else {
                    throw AgentDropError.invalid("\(arguments.first ?? "this command") needs DropCLI.runAsync")
                }
                try command.run()
                return 0
            } catch {
                return handle(error, json: wantsJSON, context: context)
            }
        }
    }

    /// What `main.swift` calls: runs every command, including `drop watch`.
    public static func runAsync(_ arguments: [String], context: CLIContext) async -> Int32 {
        let wantsJSON = arguments.contains("--json")
        return await CLIContext.$current.withValue(context) {
            do {
                var command = try DropCommand.parseAsRoot(arguments)
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                return 0
            } catch {
                return handle(error, json: wantsJSON, context: context)
            }
        }
    }

    private static func handle(_ error: Error, json: Bool, context: CLIContext) -> Int32 {
        if let error = error as? AgentDropError {
            report(error.message, code: error.exitCode, json: json, context: context)
            return error.exitCode
        }
        if DropCommand.exitCode(for: error) == .success {
            context.stdout.line(DropCommand.fullMessage(for: error))
            return 0
        }
        report(DropCommand.fullMessage(for: error), code: 1, json: json, context: context)
        return 1
    }

    private struct ErrorJSON: Encodable {
        let error: String
        let code: Int32
    }

    private static func report(_ message: String, code: Int32, json: Bool, context: CLIContext) {
        if json {
            context.stdout.line(Output.jsonString(ErrorJSON(error: message, code: code)))
        } else {
            context.stderr.line("drop: \(Output.terminalSafe(message))")
        }
    }
}

struct DropCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drop",
        abstract: "Agent Drop: a shared drop folder with context, for humans and coding agents.",
        version: "0.1.0",
        subcommands: [Add.self, Edit.self, Archive.self, ListCommand.self, Show.self, Cat.self, PathCommand.self,
                      Latest.self, Inbox.self, Claim.self, Release.self, Done.self, Reopen.self, Code.self,
                      Watch.self, Where.self, Config.self, AgentInstructions.self]
    )
}

struct JSONOption: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable JSON output.")
    var json = false
}
