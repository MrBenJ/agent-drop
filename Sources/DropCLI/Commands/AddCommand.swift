import AgentDropCore
import AgentDropServer
import ArgumentParser
import Foundation

/// A command that can also run without an async context, so `DropCLI.run` (sync) can run it.
protocol SyncRunnable {
    func runSync() throws
}

struct Add: AsyncParsableCommand, SyncRunnable {
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
    @Option(help: "Send to another Mac instead (a name from `drop remote list`, or 'env').")
    var to: String?
    @OptionGroup var output: JSONOption

    func run() async throws {
        if to == nil { try runSync() } else { try await sendRemote() }
    }

    func runSync() throws {
        guard to == nil else { throw AgentDropError.invalid("--to needs DropCLI.runAsync") }
        let context = CLIContext.current
        let store = try context.openStore()
        let source: AddSource = path == "-" ? .stdin(context.readStdin()) : .path(context.resolvePath(path))
        let drop = try store.add(AddRequest(
            source: source, name: name, title: title, description: desc, project: project,
            tags: tags, from: from, handoff: handoff, move: move))
        if output.json { Output.emitJSON(store.json(drop)) } else { Output.emit(drop.id) }
    }

    /// Uploads to another Mac's Agent Drop. Never opens the local store or reads the
    /// configured drop folder, so it works on a Mac with no Agent Drop setup.
    private func sendRemote() async throws {
        guard let to else { return }
        guard !move else { throw AgentDropError.invalid("--move can't be used with --to; nothing is deleted on this Mac") }
        let context = CLIContext.current
        let remote = try context.remote(named: to)
        let payload: TailnetClient.Payload
        let dropName: String
        if path == "-" {
            guard let name else { throw AgentDropError.invalid("drop add - requires --name <filename>") }
            let data = context.readStdin()
            guard !data.isEmpty else { throw AgentDropError.invalid("stdin was empty; nothing to drop") }
            payload = .data(data)
            dropName = name
        } else {
            let source = context.resolvePath(path)
            payload = try Self.payload(for: source)
            dropName = name ?? source.lastPathComponent
        }
        let body = try await TailnetClient(remoteName: to, remote: remote).send(payload, TailnetClient.Metadata(
            name: dropName, from: from, title: title, desc: desc, project: project, tags: tags, handoff: handoff))
        if output.json {
            Output.emit(String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            guard let id = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["id"] as? String else {
                throw AgentDropError.invalid("'\(to)' accepted the drop but its answer had no id")
            }
            Output.emit(id)
        }
    }

    /// A regular file or a folder; symlinks and anything else are refused (as for a local add).
    private static func payload(for source: URL) throws -> TailnetClient.Payload {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: source.path) // does not follow symlinks
        } catch {
            throw AgentDropError.notFound("No such file or directory: \(source.path)")
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular?: return .file(source)
        case .typeDirectory?: return .folder(source)
        case .typeSymbolicLink?: throw AgentDropError.invalid("\(source.path) is a symlink; symlinks can't be dropped")
        default: throw AgentDropError.invalid("\(source.path) is not a regular file or directory")
        }
    }
}
