import AgentDropCore
import ArgumentParser

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change a drop's metadata.")
    @Argument(help: "Id or exact filename.") var id: String
    @Option var title: String?
    @Option(name: [.customShort("m"), .customLong("desc")]) var desc: String?
    @Option var project: String?
    @Option(name: .customLong("tag"), help: "Add a tag (repeatable).") var tags: [String] = []
    @Option(name: .customLong("untag"), help: "Remove a tag (repeatable).") var untags: [String] = []
    @Option(help: "note or handoff.") var kind: String?
    @OptionGroup var output: JSONOption

    func run() throws {
        var parsedKind: DropKind?
        if let kind {
            guard let value = DropKind(rawValue: kind) else {
                throw AgentDropError.invalid("--kind must be note or handoff")
            }
            parsedKind = value
        }
        let store = try CLIContext.current.openStore()
        let drop = try store.edit(id, EditRequest(title: title, description: desc, project: project,
                                                  addTags: tags, removeTags: untags, kind: parsedKind))
        Output.printDrop(drop, store: store, json: output.json)
    }
}

struct Archive: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive", abstract: "Hide a drop from default lists (the file is untouched).")
    @Argument(help: "Id or exact filename.") var id: String
    @Flag(help: "Un-archive.") var undo = false
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrop(try store.setArchived(id, !undo), store: store, json: output.json)
    }
}
