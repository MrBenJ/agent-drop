import AgentDropCore
import AgentDropServer
import ArgumentParser
import Foundation

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Stream changes to one drop, or handoffs arriving in the Inbox (uses the Agent Drop app).")
    @Argument(help: "Id or exact filename.") var id: String?
    @Flag(help: "Watch handoffs entering the Inbox instead of one drop.") var inbox = false
    @Option(help: "With --inbox: only this project.") var project: String?
    @Flag(help: "Exit after the first event.") var once = false
    @OptionGroup var output: JSONOption

    func run() async throws {
        let target: WatchSession.Target
        switch (id, inbox) {
        case (let id?, false):
            guard project == nil else { throw AgentDropError.invalid("--project only applies with --inbox") }
            target = .drop(id)
        case (nil, true):
            target = .inbox(project: project)
        default:
            throw AgentDropError.invalid("Pass a drop id, or --inbox (not both)")
        }
        try await WatchSession(context: CLIContext.current, target: target, once: once, json: output.json).run()
    }
}

/// Spec §4 Watching and §5.3: find or launch the app's server, then print events until
/// interrupted, `--once`, or (for one drop) a `missing` or `removed` event.
struct WatchSession {
    enum Target {
        case drop(String)
        case inbox(project: String?)
    }

    private enum Outcome {
        case finished
        case disconnected
    }

    let context: CLIContext
    let target: Target
    let once: Bool
    let json: Bool

    func run() async throws {
        let settings = try context.config.load()
        guard settings.setupComplete else { throw AgentDropError.invalid(ServiceMessages.setupIncomplete) }
        if context.config.folderNeedsConfirmation(settings) {
            throw AgentDropError.invalid(ServiceMessages.confirmFolder)
        }
        var client = try await connect(launchIfNeeded: true)
        var dropID: String?
        if case .drop(let ref) = target { dropID = try await lookUp(ref, client: client, afterFolderChange: false) }
        let cursor = CursorBox()
        while true {
            switch try await stream(client: client, dropID: dropID, cursor: cursor) {
            case .finished:
                return
            case .disconnected:
                // The app quit, restarted its server, or switched folders. Keep the cursor:
                // the same store replays what we missed; a new store sends `reset`.
                client = try await connect(launchIfNeeded: false)
                if let id = dropID { _ = try await lookUp(id, client: client, afterFolderChange: true) }
            }
        }
    }

    // MARK: - Connecting

    /// Reads `server.json`. A missing file or a dead `pid` means the app isn't running: the
    /// first connect launches it; a reconnect only waits for it to come back.
    private func connect(launchIfNeeded: Bool) async throws -> AgentDropClient {
        let file = ServerInfoFile(configDir: context.config.configDir)
        var launched = false
        if launchIfNeeded, liveInfo(file) == nil {
            try context.launchApp()
            launched = true
        }
        let deadline = ContinuousClock.now + context.serverWait
        while true {
            if let info = liveInfo(file) {
                if info.status == .noPort {
                    throw AgentDropError.invalid(
                        "Agent Drop is running without its local server: no port was free. Click Retry in Agent Drop.")
                }
                if let port = info.port, let token = info.token {
                    let client = AgentDropClient(port: port, token: token)
                    let probe = try? await client.get("/drops", query: [URLQueryItem(name: "limit", value: "1")])
                    if probe?.1 == 200 { return client }
                }
            }
            guard ContinuousClock.now < deadline else {
                let seconds = context.serverWait.components.seconds
                if launched { throw AgentDropError.invalid("Agent Drop didn't start its server within \(seconds) s") }
                if launchIfNeeded { throw AgentDropError.invalid("Agent Drop's server isn't answering") }
                throw AgentDropError.invalid("Lost the connection to Agent Drop (it quit or its server stopped)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func liveInfo(_ file: ServerInfoFile) -> ServerInfo? {
        guard let info = file.read(), context.isProcessAlive(info.pid) else { return nil }
        return info
    }

    /// The drop's id, from its id or exact filename. Exit 2 if the server doesn't have it.
    private func lookUp(_ ref: String, client: AgentDropClient, afterFolderChange: Bool) async throws -> String {
        let (body, status): (Data, Int)
        do {
            (body, status) = try await client.get(AgentDropClient.dropPath(ref))
        } catch {
            throw AgentDropError.invalid("Couldn't reach Agent Drop: \(error.localizedDescription)")
        }
        let json = try? JSONDecoder().decode([String: JSONValue].self, from: body)
        switch status {
        case 200:
            guard let id = json?["id"]?.stringValue else { throw AgentDropError.invalid("Unexpected answer from Agent Drop") }
            return id
        case 404:
            throw AgentDropError.notFound(afterFolderChange
                ? "drop folder changed; \(ref) is not in the current folder"
                : "No drop matches '\(ref)'")
        default:
            throw AgentDropError.invalid(json?["error"]?.stringValue ?? "Agent Drop answered HTTP \(status)")
        }
    }

    // MARK: - Streaming

    private func stream(client: AgentDropClient, dropID: String?, cursor: CursorBox) async throws -> Outcome {
        let query: [URLQueryItem]
        switch target {
        case .drop: query = [URLQueryItem(name: "drop", value: dropID)]
        case .inbox(let project):
            query = [URLQueryItem(name: "inbox", value: "")] + (project.map { [URLQueryItem(name: "project", value: $0)] } ?? [])
        }
        let events: AsyncThrowingStream<SSEEvent, Error>
        do {
            events = try await client.events(query: query, lastEventID: cursor.value, onCursor: { cursor.value = $0 })
        } catch let failure as AgentDropClient.HTTPFailure {
            if failure.status == 404, let dropID { throw AgentDropError.notFound("No drop matches '\(dropID)'") }
            throw AgentDropError.invalid(failure.message)
        } catch {
            return .disconnected
        }
        do {
            for try await event in events {
                if event.event == "reset" {
                    print(reset: event)
                    if let dropID { _ = try await lookUp(dropID, client: client, afterFolderChange: true) }
                    continue
                }
                print(event: event)
                if once { return .finished }
                if dropID != nil, event.event == "missing" || event.event == "removed" { return .finished }
            }
        } catch let error as AgentDropError {
            throw error
        } catch {
            // The connection dropped; reconnect.
        }
        return .disconnected
    }

    /// The stream's last event id, kept across reconnects.
    private final class CursorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    // MARK: - Output

    private func print(event: SSEEvent) {
        if json {
            context.stdout.line(event.data)
            return
        }
        guard let message = try? JSONDecoder().decode(EventMessage.self, from: Data(event.data.utf8)) else {
            context.stdout.line(Output.terminalSafe(event.data))
            return
        }
        context.stdout.line([message.at, message.type, message.dropId, Self.summary(message)]
            .map { Output.terminalSafe($0) }.joined(separator: "\t"))
    }

    private func print(reset event: SSEEvent) {
        if json {
            context.stdout.line(#"{"data":\#(event.data),"type":"reset"}"#)
        } else {
            context.stdout.line(["-", "reset", "-", SSE.resetReason].joined(separator: "\t"))
        }
    }

    /// One readable phrase per event type (spec §5.1 table).
    static func summary(_ message: EventMessage) -> String {
        let data = message.data
        switch message.type {
        case "created":
            return data["title"]?.stringValue ?? "created"
        case "content":
            return "contents changed"
        case "metadata":
            if case .object(let fields) = data { return "changed " + fields.keys.sorted().joined(separator: ", ") }
            return "metadata changed"
        case "status":
            var text = "\(data["from"]?.stringValue ?? "?") → \(data["to"]?.stringValue ?? "?")"
            if data["to"]?.stringValue == "claimed", let by = data["claimedBy"]?.stringValue { text += " by \(by)" }
            if data["to"]?.stringValue == "done", let note = data["statusNote"]?.stringValue { text += ": \(note)" }
            return text
        case "archived":
            return data["archived"] == .bool(true) ? "archived" : "unarchived"
        case "missing":
            return "file is missing"
        case "read":
            return "viewed in the app"
        case "removed":
            return "record removed"
        default:
            return message.type
        }
    }
}
