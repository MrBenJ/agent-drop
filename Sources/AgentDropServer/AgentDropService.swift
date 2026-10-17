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
        public var tailnetLocator: TailnetLocator = .live
        /// How often to look for Tailscale coming, going or changing address while enabled.
        public var tailnetPoll: Duration = .seconds(10)
        /// nil: the identity's address. Tests bind 127.0.0.1.
        public var tailnetBindHost: (@Sendable (TailnetIdentity) -> String)? = nil
        public var tailnetPeerAllowed: @Sendable (String) -> Bool = TailnetAccess.isTailnetPeer
        /// Called on every change of `tailnetState`.
        public var onTailnetChange: @Sendable (TailnetState) -> Void = { _ in }

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

    public private(set) var tailnetState: TailnetState = .off
    /// The Settings toggle; it outlives `stop()` and `start()`.
    private var tailnetEnabled = false
    private var tailnetServer: TailnetServer?
    /// The identity `tailnetServer` was bound for.
    private var tailnetIdentity: TailnetIdentity?
    private var tailnetPollTask: Task<Void, Never>?
    /// Bumped whenever the poll task is replaced or cancelled, so a poll that was already
    /// queued behind a stop or a disable does nothing.
    private var tailnetPollGeneration = 0

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

    /// Turns the tailnet listener on or off. While the service is stopped, on means `.waiting`.
    @discardableResult
    public func setTailnet(enabled: Bool) async -> TailnetState {
        (try? await serially { await $0.performSetTailnet(enabled: enabled) }) ?? tailnetState
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
            let state = try await bindServer()
            if tailnetEnabled {
                await refreshTailnet()
                startTailnetPoll()
            }
            return state
        } catch {
            await performStop()
            if let error = error as? AgentDropError { throw error }
            throw AgentDropError.invalid("Can't start serving \(folder.path): \(error.localizedDescription)")
        }
    }

    private func performStop() async {
        stopTailnetPoll()
        await stopTailnetListener()
        setTailnetState(tailnetEnabled ? .waiting : .off)
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

    // MARK: Tailnet listener

    private func performSetTailnet(enabled: Bool) async -> TailnetState {
        tailnetEnabled = enabled
        if !enabled {
            stopTailnetPoll()
            await stopTailnetListener()
            setTailnetState(.off)
        } else if store == nil {
            setTailnetState(.waiting)
        } else {
            await refreshTailnet()
            startTailnetPoll()
        }
        return tailnetState
    }

    /// Brings the listener in line with the current identity: unchanged and listening
    /// leaves it alone; otherwise it's stopped and, if there is an identity, rebound.
    private func refreshTailnet() async {
        guard tailnetEnabled, let store else { return }
        let identity = await options.tailnetLocator.locate()
        if tailnetServer != nil, identity == tailnetIdentity { return }
        await stopTailnetListener()
        guard let identity else {
            setTailnetState(.notConnected)
            return
        }
        await bindTailnet(store: store, identity: identity, recheck: true)
    }

    /// Every bind failure is `PortInUse`, but when Tailscale just went away the real cause
    /// is the missing address. So on failure, look once more before reporting the port.
    private func bindTailnet(store: DropStore, identity: TailnetIdentity, recheck: Bool) async {
        let settings = try? config.load()
        let configured = settings?.tailnetPort ?? AgentDropConfig.defaultTailnetPort
        let port = (1...65535).contains(configured) ? configured : AgentDropConfig.defaultTailnetPort
        let maxBytes = settings?.tailnetMaxBytes ?? AgentDropConfig.defaultTailnetMaxBytes
        let keyFile = TailnetKeyFile(configDir: config.configDir)
        do {
            let server = try await TailnetServer.start(
                store: store, bindHost: options.tailnetBindHost?(identity) ?? identity.address, port: port,
                identity: identity, limits: .init(maxBytes: maxBytes), key: { keyFile.read() },
                peerAllowed: options.tailnetPeerAllowed)
            tailnetServer = server
            tailnetIdentity = identity
            setTailnetState(.receiving(host: identity.preferredHost, port: port))
        } catch {
            guard recheck else {
                setTailnetState(.portInUse(port))
                return
            }
            switch await options.tailnetLocator.locate() {
            case nil:
                setTailnetState(.notConnected)
            case let now? where now != identity:
                await bindTailnet(store: store, identity: now, recheck: false)
            default:
                setTailnetState(.portInUse(port))
            }
        }
    }

    private func stopTailnetListener() async {
        await tailnetServer?.stop()
        tailnetServer = nil
        tailnetIdentity = nil
    }

    /// Sleeps off the actor; each poll goes through `serially` so it never interleaves
    /// with start, stop or a toggle.
    private func startTailnetPoll() {
        stopTailnetPoll()
        let generation = tailnetPollGeneration
        let interval = options.tailnetPoll
        tailnetPollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let service = self else { return }
                _ = try? await service.serially { await $0.pollTailnet(generation: generation) }
            }
        }
    }

    private func stopTailnetPoll() {
        tailnetPollGeneration += 1
        tailnetPollTask?.cancel()
        tailnetPollTask = nil
    }

    private func pollTailnet(generation: Int) async {
        guard generation == tailnetPollGeneration else { return }
        await refreshTailnet()
    }

    private func setTailnetState(_ new: TailnetState) {
        guard new != tailnetState else { return }
        tailnetState = new
        options.onTailnetChange(new)
    }
}
