import AgentDropCore
import ArgumentParser
import Foundation

struct ListFilterOptions: ParsableArguments {
    @Option(help: "Exact project.") var project: String?
    @Option(name: .customLong("tag"), help: "Exact tag (repeatable; all must match).") var tags: [String] = []
    @Option(help: "Exact --from value.") var from: String?
    @Option(name: .customLong("from-under"), help: "A --from prefix and everything under it (split on '/').")
    var fromUnder: String?
    @Flag(help: "Handoffs only.") var handoffs = false
    @Option(help: "open, claimed, or done.") var status: String?
    @Flag(help: "Unread only (not archived, not missing).") var unread = false
    @Option(help: "Maximum results (default 50).") var limit: Int = 50
    @Flag(help: "Include archived drops.") var all = false

    func filter() throws -> ListFilter {
        var filter = ListFilter()
        filter.project = project
        filter.tags = tags
        filter.from = from
        filter.fromUnder = fromUnder
        filter.handoffsOnly = handoffs
        if let status {
            guard let parsed = HandoffStatus(rawValue: status) else {
                throw AgentDropError.invalid("--status must be open, claimed, or done")
            }
            filter.status = parsed
        }
        filter.unreadOnly = unread
        guard limit >= 1 else { throw AgentDropError.invalid("--limit must be at least 1") }
        filter.limit = limit
        filter.includeArchived = all
        return filter
    }
}

/// The drop's file, or exit 2 if it's gone.
func requireFile(_ drop: Drop, store: DropStore) throws -> URL {
    guard !drop.missing else { throw AgentDropError.notFound("The file for \(drop.id) is missing") }
    return store.path(of: drop)
}

/// Raw bytes to stdout (spec §4 `drop cat`; never sets read_at).
func writeContents(of drop: Drop, store: DropStore) throws {
    let url = try requireFile(drop, store: store)
    guard !drop.isFolder else {
        throw AgentDropError.invalid("\(drop.id) is a folder drop; use `drop path \(drop.id)`")
    }
    CLIContext.current.stdout.write(try Data(contentsOf: url))
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Metadata plus absolute path.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        let drop = try store.resolve(id)
        if output.json { Output.emitJSON(store.json(drop)) }
        else { Output.emit(Output.details(for: drop, path: store.path(of: drop).path)) }
    }
}

struct Cat: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cat", abstract: "Print the file's contents.")
    @Argument(help: "Id or exact filename.") var id: String
    @Flag(help: "Not supported: cat prints raw contents.") var json = false

    func run() throws {
        if json { throw AgentDropError.invalid("drop cat prints raw file contents; --json isn't supported") }
        let store = try CLIContext.current.openStore()
        try writeContents(of: try store.resolve(id), store: store)
    }
}

struct PathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Print the absolute path only.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        let url = try requireFile(try store.resolve(id), store: store)
        if output.json { Output.emitJSON(["path": url.path]) } else { Output.emit(url.path) }
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List drops, newest first (archived hidden unless --all).")
    @OptionGroup var filters: ListFilterOptions
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrops(try store.list(try filters.filter()), store: store, json: output.json)
    }
}

struct Latest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "latest", abstract: "The newest drop matching the same filters as list.")
    @OptionGroup var filters: ListFilterOptions
    @Flag(help: "Print the file's contents instead of its metadata.") var cat = false
    @OptionGroup var output: JSONOption

    func run() throws {
        if cat && output.json { throw AgentDropError.invalid("--cat and --json can't be combined; use one or the other") }
        let store = try CLIContext.current.openStore()
        var filter = try filters.filter()
        filter.limit = 1
        guard let drop = try store.list(filter).first else { throw AgentDropError.notFound("No drops match") }
        if cat { try writeContents(of: try store.resolve(drop.id), store: store); return }
        if output.json { Output.emitJSON(store.json(drop)) }
        else { Output.emit(Output.details(for: drop, path: store.path(of: drop).path)) }
    }
}

struct Inbox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox", abstract: "Open handoffs (not archived, not missing).")
    @Option(help: "Only this project.") var project: String?
    @OptionGroup var output: JSONOption

    func run() throws {
        let store = try CLIContext.current.openStore()
        Output.printDrops(try store.inbox(project: project), store: store, json: output.json)
    }
}
