import AgentDropCore
import ArgumentParser

struct Claim: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claim", abstract: "Pick up an open handoff (exit 3 if someone else has it).")
    @Argument(help: "Id or exact filename.") var id: String
    @Option(help: "Who is claiming. Required, free-form, never guessed.") var by: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.claim(id, by: by), store: store, json: output.json)
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release", abstract: "Un-claim: back to open.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.release(id), store: store, json: output.json)
    }
}

struct Done: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark a handoff finished.")
    @Argument(help: "Id or exact filename.") var id: String
    @Option(help: "What happened, e.g. \"shipped in PR #42\".") var note: String?
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.done(id, note: note), store: store, json: output.json)
    }
}

struct Reopen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reopen", abstract: "Move a done handoff back to open.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.reopen(id), store: store, json: output.json)
    }
}
