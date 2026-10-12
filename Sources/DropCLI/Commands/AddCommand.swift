import AgentDropCore
import ArgumentParser
import Foundation

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Drop a file or folder (or '-' for stdin) into the drop folder and register it.")

    @Argument(help: "File or folder to drop, or '-' to read content from stdin (requires --name).")
    var path: String
    @Option(help: "Who is dropping this. Required, free-form, never guessed.")
    var from: String
    @Option(help: "Top-level name for the drop (default: the source's name).")
    var name: String?
    @Option(help: "Title (default: first '# heading', else the filename).")
    var title: String?
    @Option(name: [.customShort("m"), .customLong("desc")], help: "Why this exists / context.")
    var desc: String?
    @Option(help: "Project (free-form).")
    var project: String?
    @Option(name: .customLong("tag"), help: "Tag (repeatable).")
    var tags: [String] = []
    @Flag(help: "Make this a handoff (status: open).")
    var handoff = false
    @Flag(help: "Move instead of copy.")
    var move = false
    @OptionGroup var output: JSONOption

    func run() throws {
        let context = CLIContext.current
        let store = try context.openStore()
        let source: AddSource = path == "-" ? .stdin(context.readStdin()) : .path(context.resolvePath(path))
        let drop = try store.add(AddRequest(
            source: source, name: name, title: title, description: desc, project: project,
            tags: tags, from: from, handoff: handoff, move: move))
        if output.json { Output.emitJSON(store.json(drop)) } else { Output.emit(drop.id) }
    }
}
