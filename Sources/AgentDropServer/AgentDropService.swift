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
        /// Called (on no particular thread) whenever the folder or the store may have
        /// changed: a commit, a CLI write, an entry added or removed. The app reloads on it.
        public var onChange: @Sendable () -> Void = {}

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
    private var hub: EventHub?
    private var content: ContentWatcher?
    private var watcher: FolderWatcher?
    private var server: HTTPServer?
    private var portBase = AgentDropConfig.defaultServerPort
    /// The last queued operation. start/stop/retryPort run one at a time, in call order:
    /// each suspends on its way, and an overlapping call must not see a half-started state.
    private var lastOperation: Task<Void, Never>?

    /// The running store. In-process writers (the app) should write through it: its
    /// commits reach event-stream clients at once.
    public private(set) var store: DropStore?

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
        try await serially { try await $0.performStart() }
    }

    /// The app's **Retry** button after `noPort`.
    @discardableResult
    public func retryPort() async -> State {
        (try? await serially { service -> State in
            guard await service.state == .noPort else { return await service.state }
            return (try? await service.bindServer()) ?? .noPort
        }) ?? state
    }

    /// Stops everything and removes `server.json` if this instance wrote it.
    public func stop() async {
        _ = try? await serially { await $0.performStop() }
    }

    private func serially<T: Sendable>(_ operation: @escaping @Sendable (AgentDropService) async throws -> T)
        async throws -> T
    {
        let previous = lastOperation
        let task = Task<T, Error> {
            await previous?.value
            return try await operation(self)
        }
        lastOperation = Task { _ = try? await task.value }
        return try await task.value
    }

    private func performStart() async throws -> State {
        guard state == .stopped else { return state }
        let settings = try config.load()
        guard settings.setupComplete else { throw AgentDropError.invalid(ServiceMessages.setupIncomplete) }
        guard !config.folderNeedsConfirmation(settings) else {
            throw AgentDropError.invalid(ServiceMessages.confirmFolder)
        }
        portBase = options.portBase ?? settings.serverPort ?? AgentDropConfig.defaultServerPort

        let folder = config.folderURL(settings)
        let store = try DropStore.open(folder: folder, retention: settings.eventRetentionDays)
        // Spec §3.2: reconcile on launch. A busy store is skipped; the next change to an
        // entry re-checks that drop anyway.
        _ = try? store.reconcile()
        let hub = try EventHub(store: store)
        let onChange = options.onChange
        store.observeEventCommits {
            Task { await hub.poke() }
            onChange()
        }
        await hub.startHeartbeat(every: options.heartbeat)
        let content = ContentWatcher(store: store, debounce: options.debounce, onChange: { await hub.poke() })
        await content.baselineNewDrops()
        let watcher = FolderWatcher(folder: folder) { changes in
            onChange()
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
        self.store = store
        self.hub = hub
        self.content = content
        self.watcher = watcher
        do {
            try watcher.start()
            return try await bindServer()
        } catch {
            await performStop()
            if let error = error as? AgentDropError { throw error }
            throw AgentDropError.invalid("Can't start serving \(folder.path): \(error.localizedDescription)")
        }
    }

    private func performStop() async {
        await server?.stop()
        await hub?.close()
        watcher?.stop()
        await content?.stop()
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
