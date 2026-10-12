import AgentDropCore
import Foundation

/// User-facing reasons shared by the service and `drop watch` (spec §3, §4 Watching).
public enum ServiceMessages {
    public static let setupIncomplete =
        "Agent Drop hasn't been set up yet. Open the Agent Drop app once to finish setup."
    public static let confirmFolder = "Confirm the new drop folder in Agent Drop"
}

/// What the app hosts (spec §5.2): the content watcher and the HTTP server for the
/// configured folder, plus `server.json`. One instance per folder; a folder switch is
/// `stop()` then `start()`, which gives the new store's events a new `storeId`.
public actor AgentDropService {
    public struct Options: Sendable {
        /// nil: `serverPort` from config.json, else 47390.
        public var portBase: Int?
        /// The default port plus the next 9.
        public var portAttempts = 10
        public var debounce: Duration = .milliseconds(300)
        public var heartbeat: Duration = .seconds(15)
        public var pid: Int32 = ProcessInfo.processInfo.processIdentifier

        public init() {}
    }

    public enum State: Equatable, Sendable {
        case stopped
        case running(port: Int)
        /// The content watcher runs; no port in the range could be bound.
        case noPort
    }

    public private(set) var state: State = .stopped
    private let config: ConfigStore
    private let options: Options
    private var store: DropStore?
    private var hub: EventHub?
    private var content: ContentWatcher?
    private var watcher: FolderWatcher?
    private var server: HTTPServer?
    private var portBase = AgentDropConfig.defaultServerPort

    public init(config: ConfigStore, options: Options = Options()) {
        self.config = config
        self.options = options
    }

    private var infoFile: ServerInfoFile { ServerInfoFile(configDir: config.configDir) }

    /// Connected event-stream clients.
    public var clientCount: Int {
        get async { await hub?.subscriberCount ?? 0 }
    }

    /// Refuses (touching nothing) until setup is complete and any protected folder is
    /// confirmed. Otherwise starts the content watcher, then the server.
    @discardableResult
    public func start() async throws -> State {
        guard state == .stopped else { return state }
        let settings = try config.load()
        guard settings.setupComplete else { throw AgentDropError.invalid(ServiceMessages.setupIncomplete) }
        guard !config.folderNeedsConfirmation(settings) else {
            throw AgentDropError.invalid(ServiceMessages.confirmFolder)
        }
        portBase = options.portBase ?? settings.serverPort ?? AgentDropConfig.defaultServerPort

        let folder = config.folderURL(settings)
        let store = try DropStore.open(folder: folder, retention: settings.eventRetentionDays)
        let hub = try EventHub(store: store)
        await hub.startHeartbeat(every: options.heartbeat)
        let content = ContentWatcher(store: store, debounce: options.debounce, onChange: { await hub.poke() })
        await content.baselineNewDrops()
        let watcher = FolderWatcher(folder: folder) { changes in
            Task {
                for change in changes {
                    switch change {
                    case .store:
                        await hub.poke()
                        await content.baselineNewDrops()
                    case .entry(let name):
                        await content.entryChanged(name)
                    case .rescan:
                        await hub.poke()
                        await content.rescan()
                    }
                }
            }
        }
        do {
            try watcher.start()
        } catch {
            await hub.close()
            throw AgentDropError.invalid("Can't watch \(folder.path): \(error.localizedDescription)")
        }
        self.store = store
        self.hub = hub
        self.content = content
        self.watcher = watcher
        do {
            return try await bindServer()
        } catch {
            await stop()
            throw error
        }
    }

    /// The app's **Retry** button after `noPort`.
    @discardableResult
    public func retryPort() async -> State {
        guard state == .noPort else { return state }
        return (try? await bindServer()) ?? state
    }

    /// Stops everything and removes `server.json` if this instance wrote it.
    public func stop() async {
        await server?.stop()
        await hub?.close()
        watcher?.stop()
        await content?.cancelPending()
        if infoFile.read()?.pid == options.pid { infoFile.remove() }
        server = nil
        hub = nil
        content = nil
        watcher = nil
        store = nil
        state = .stopped
    }

    private func bindServer() async throws -> State {
        guard let store, let hub else { return state }
        let token = ServerInfo.newToken()
        do {
            let server = try await HTTPServer.start(store: store, hub: hub, token: token, portBase: portBase,
                                                    attempts: options.portAttempts)
            self.server = server
            try infoFile.write(.running(port: server.port, token: token, pid: options.pid))
            state = .running(port: server.port)
        } catch is HTTPServer.PortsExhausted {
            try infoFile.write(.noPort(pid: options.pid))
            state = .noPort
        }
        return state
    }
}
