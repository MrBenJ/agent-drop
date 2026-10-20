import AgentDropCore
import AgentDropServer
import Foundation
import Observation

/// The app's lifecycle (spec §2, §3, §5.2, §6): first-run setup, protected-folder
/// confirmation, hosting the service for the configured folder, and following
/// config.json when the CLI changes it.
@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable {
        case starting
        /// First-run setup (spec §2). Nothing in the drop folder is touched yet.
        case setup
        /// The configured folder is protected and wasn't confirmed in the app (spec §3).
        /// The server and content watcher are off.
        case confirmFolder
        case running
        /// The store couldn't be opened (spec §7). The message says why.
        case storeError(String)
        /// config.json couldn't be read at launch, so whether setup happened is unknown.
        case configUnreadable(String)
    }

    public enum Banner: Hashable, Identifiable, Sendable {
        /// No port in the range was free (spec §5.2): **Retry**.
        case noPort
        /// config.json holds an invalid retention value, treated as 30 (spec §5.1).
        case invalidRetention
        /// config.json can't be read; the last good settings stay in effect.
        case configError(String)
        public var id: Self { self }
    }

    public private(set) var phase: Phase = .starting
    public private(set) var config = AgentDropConfig()
    public private(set) var serverState: AgentDropService.State = .stopped
    /// Settings → Tailnet's status line.
    public private(set) var tailnetState: TailnetState = .off
    /// The tailnet toggle or **Regenerate key** failed; nil after the next success.
    public private(set) var tailnetError: String?
    /// Why config.json can't be read right now; nil once it can.
    public private(set) var configError: String?
    public let library: LibraryModel
    public let settings: AppSettings
    public let configStore: ConfigStore
    /// Setup's question "Start Agent Drop at login?"; Yes is pre-selected (spec §6).
    public var launchAtLogin = true
    /// Finishing setup or confirming a folder failed (e.g. macOS denied access).
    public var folderError: String?
    /// Launch at login couldn't be changed. Setup still completes.
    public var loginItemError: String?
    /// A `drop open` link that arrived before the drops could be shown (spec §2).
    public private(set) var pendingDropID: String?
    /// Set by the app delegate: brings up the main window.
    @ObservationIgnored public var showWindow: @MainActor () -> Void = {}
    /// Shows the window without activating the app (`drop open` without `--foreground`).
    @ObservationIgnored public var showWindowInBackground: @MainActor () -> Void = {}

    @ObservationIgnored let loginItem: LoginItemControlling
    @ObservationIgnored private let notifier = NewDropNotifier()
    @ObservationIgnored private let service: AgentDropService
    @ObservationIgnored private let changes: AsyncStream<Void>.Continuation
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var tailnetTask: Task<Void, Never>?
    @ObservationIgnored private var configWatcher: FolderWatcher?
    /// The folder settings the service last started (or refused to start) with.
    @ObservationIgnored private var applied: Applied?
    @ObservationIgnored private var lastOperation: Task<Void, Never>?

    private struct Applied: Equatable {
        var folder: String
        var needsConfirmation: Bool
        var port: Int?
        var tailnetPort: Int?
        var tailnetMaxBytes: Int64?
    }

    public init(configStore: ConfigStore, loginItem: LoginItemControlling, settings: AppSettings,
                poster: NoticePosting? = nil, serviceOptions: AgentDropService.Options = .init()) {
        self.configStore = configStore
        self.loginItem = loginItem
        self.settings = settings
        library = LibraryModel()
        // Bursts of changes collapse into one pending reload.
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = continuation
        var options = serviceOptions
        options.onChange = { continuation.yield() }
        // Tailnet states reach the main actor in order; only the newest pending one matters.
        let (tailnetStream, tailnetContinuation) = AsyncStream<TailnetState>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let callerOnTailnetChange = serviceOptions.onTailnetChange
        options.onTailnetChange = { state in
            callerOnTailnetChange(state)
            tailnetContinuation.yield(state)
        }
        service = AgentDropService(config: configStore, options: options)
        let library = self.library
        library.afterReload = { [notifier, weak library, weak poster] store in
            guard let library else { return }
            let notices = await notifier.check(store, library: library, enabled: settings.notifyOnNewDrops)
            if !notices.isEmpty { poster?.post(notices) }
        }
        changeTask = Task { @MainActor in
            for await _ in stream { await library.reload() }
        }
        tailnetTask = Task { @MainActor [weak self] in
            for await state in tailnetStream { self?.tailnetState = state }
        }
        // The toggle as last left, before any start: a launch with it on resumes receiving.
        // It heads the lifecycle queue, so `launch()` starts the service only after it.
        let service = service
        let receive = settings.receiveFromTailnet
        lastOperation = Task { @MainActor in _ = await service.setTailnet(enabled: receive) }
    }

    public var folder: URL { configStore.folderURL(config) }
    public var folderIsProtected: Bool { FolderProtection.isProtected(folder, homeDir: configStore.homeDir) }

    public var banners: [Banner] {
        var banners: [Banner] = []
        if serverState == .noPort { banners.append(.noPort) }
        if config.retentionWasInvalid { banners.append(.invalidRetention) }
        if let configError, phase == .running { banners.append(.configError(configError)) }
        return banners
    }

    /// The menu bar's status line, when the app needs the human.
    public var menuStatus: String? {
        switch phase {
        case .setup: "Finish setting up Agent Drop…"
        case .confirmFolder: "Drop folder changed — confirm"
        case .storeError: "Can't open the drop store"
        case .configUnreadable: "Can't read config.json"
        case .running: configError.map { _ in "Can't read config.json" }
        case .starting: nil
        }
    }

    // MARK: Lifecycle

    /// Reads config.json and starts serving if setup is done and the folder is confirmed.
    /// Before setup it touches nothing but config.json (spec §2).
    public func launch() async {
        await serially { model in
            model.watchConfig()
            // Unreadable at launch: whether setup ever happened is unknown, so this is an
            // error to fix, not a first run (which would turn Launch at login back on).
            guard model.loadConfig() else {
                model.phase = .configUnreadable(model.configError ?? "Can't read config.json")
                return
            }
            await model.startFromConfig()
        }
    }

    /// Stops the service (removing server.json) before the app quits.
    public func shutdown() async {
        await serially { model in
            model.configWatcher?.stop()
            model.configWatcher = nil
            await model.service.stop()
            model.serverState = .stopped
            model.changeTask?.cancel()
            model.changes.finish()
            model.tailnetTask?.cancel()
        }
    }

    /// Setup's **Finish** button: the folder is touched for the first time here, so a
    /// protected folder's macOS prompt appears now, after setup explained it.
    public func completeSetup() async {
        await serially { model in
            guard model.phase == .setup else { return }
            model.folderError = nil
            model.loadConfig()
            let folder = model.folder
            do {
                try Self.touch(folder)
                if model.folderIsProtected { try model.configStore.setConfirmedFolder(folder) }
                try model.configStore.setSetupComplete(true)
            } catch {
                model.folderError = Self.folderMessage(folder, error)
                return
            }
            do {
                try model.loginItem.setEnabled(model.launchAtLogin)
            } catch {
                model.loginItemError = "Couldn't change Launch at login: \(LibraryModel.message(error))"
            }
            model.loadConfig()
            await model.applyFolder()
        }
    }

    /// The confirmation screen's **Use this folder** (spec §3).
    public func confirmFolder() async {
        await serially { model in
            guard model.phase == .confirmFolder else { return }
            model.folderError = nil
            model.loadConfig()
            let folder = model.folder
            do {
                try Self.touch(folder)
                try model.configStore.setConfirmedFolder(folder)
            } catch {
                model.folderError = Self.folderMessage(folder, error)
                return
            }
            model.loadConfig()
            await model.applyFolder()
        }
    }

    /// A folder picked in the app (setup, confirmation, Settings) counts as confirmed
    /// (spec §3). During setup it is only recorded; otherwise the app switches to it.
    public func chooseFolder(_ url: URL) async {
        do {
            try configStore.setFolder(url)
            try configStore.setConfirmedFolder(url)
        } catch {
            folderError = LibraryModel.message(error)
            return
        }
        await configDidChange()
    }

    /// Settings → Event history.
    public func setRetention(_ retention: Retention) async {
        do {
            try configStore.setRetention(retention)
        } catch {
            library.alert = LibraryModel.message(error)
            return
        }
        await configDidChange()
    }

    /// The store-error screen's **Try Again**.
    public func retryStore() async {
        await serially { model in
            guard case .storeError = model.phase else { return }
            model.loadConfig()
            await model.service.stop()
            await model.applyFolder()
        }
    }

    /// Settings → Launch at login.
    public var launchesAtLogin: Bool { loginItem.isEnabled }

    public func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change Launch at login: \(LibraryModel.message(error))"
        }
    }

    // MARK: Tailnet

    /// Settings → Tailnet "Receive drops from my tailnet". Turning it on creates the sender
    /// key first; if that fails the toggle stays off and `tailnetError` says why.
    public func setReceiveFromTailnet(_ on: Bool) async {
        await serially { model in
            if on {
                do {
                    _ = try model.tailnetKeyFile.create()
                } catch {
                    model.tailnetError = "Couldn't turn on receiving: \(LibraryModel.message(error))"
                    model.settings.receiveFromTailnet = false
                    return
                }
            }
            model.tailnetError = nil
            model.settings.receiveFromTailnet = on
            model.tailnetState = await model.service.setTailnet(enabled: on)
        }
    }

    /// Settings → Tailnet **Regenerate key**. Senders need the new setup command.
    public func regenerateTailnetKey() {
        do {
            _ = try tailnetKeyFile.regenerate()
            tailnetError = nil
        } catch {
            tailnetError = "Couldn't regenerate the key: \(LibraryModel.message(error))"
        }
    }

    /// What to run on the sending Mac; nil unless receiving with a key. The key is read
    /// from disk each time, so a regenerated key shows at once.
    public var tailnetSetupCommand: String? {
        guard case .receiving(let host, let port) = tailnetState, let key = tailnetKeyFile.read() else { return nil }
        return "drop remote add laptop --url http://\(host):\(port) --key \(key)"
    }

    /// Settings → Tailnet **Copy setup command**: `tailnetSetupCommand`, or nil with
    /// `tailnetError` set when receiving but the key file is missing or malformed.
    public func tailnetSetupCommandToCopy() -> String? {
        reportingMissingKey(tailnetSetupCommand)
    }

    /// Settings → Tailnet **Copy key**: the sender key, read fresh from disk; nil unless
    /// receiving, with `tailnetError` set when receiving but the key file is unusable.
    public func tailnetKeyToCopy() -> String? {
        guard case .receiving = tailnetState else { return nil }
        return reportingMissingKey(tailnetKeyFile.read())
    }

    private func reportingMissingKey(_ value: String?) -> String? {
        if value == nil, case .receiving = tailnetState {
            tailnetError = "No sender key — click Regenerate key."
        }
        return value
    }

    private var tailnetKeyFile: TailnetKeyFile { TailnetKeyFile(configDir: configStore.configDir) }

    /// The **Retry** banner after `noPort`.
    public func retryPort() async {
        serverState = await service.retryPort()
    }

    /// config.json changed (the CLI, Settings, or an editor). A new folder, a change in
    /// whether it needs confirming, or a new port restarts the service; a new retention
    /// applies to the open store directly. So does a new `tailnetPort` or `tailnetMaxBytes`;
    /// nothing in config.json turns tailnet receiving on.
    public func configDidChange() async {
        await serially { model in
            let readable = model.loadConfig()
            if case .configUnreadable = model.phase {
                if readable { await model.startFromConfig() } else {
                    model.phase = .configUnreadable(model.configError ?? "Can't read config.json")
                }
                return
            }
            guard readable, model.phase != .setup, model.phase != .starting else { return }
            model.library.store?.setRetention(model.config.eventRetentionDays)
            guard model.appliedKey() != model.applied else { return }
            await model.service.stop()
            model.serverState = .stopped
            model.library.detach()
            await model.applyFolder()
        }
    }

    // MARK: Links

    /// `drop open`, a notification, or the menu: show the drop. Before the drops can be
    /// shown (setup, confirmation) it is remembered and shown once they can (spec §2).
    public func open(dropID: String, background: Bool = false) async {
        background ? showWindowInBackground() : showWindow()
        guard phase == .running else {
            pendingDropID = dropID
            return
        }
        await library.reveal(dropID)
    }

    public func open(_ url: URL) async {
        guard let id = AppLink.dropID(from: url) else {
            showWindow()
            library.alert = "Agent Drop can't open \(url.absoluteString)."
            return
        }
        await open(dropID: id, background: AppLink.isBackground(url))
    }

    // MARK: Internals

    /// Start the service for the configured folder, or wait for confirmation.
    private func applyFolder() async {
        applied = appliedKey()
        if configStore.folderNeedsConfirmation(config) {
            phase = .confirmFolder
            return
        }
        do {
            serverState = try await service.start()
            guard let store = await service.store else {
                throw AgentDropError.invalid("The drop store didn't open.")
            }
            phase = .running
            await library.attach(store)
            if let id = pendingDropID {
                pendingDropID = nil
                await library.reveal(id)
            }
        } catch {
            serverState = .stopped
            phase = .storeError(LibraryModel.message(error))
        }
    }

    private func appliedKey() -> Applied {
        Applied(folder: folder.standardizedFileURL.path, needsConfirmation: configStore.folderNeedsConfirmation(config),
                port: config.serverPort, tailnetPort: config.tailnetPort, tailnetMaxBytes: config.tailnetMaxBytes)
    }

    /// False (with `configError` set) when config.json can't be read; the last good
    /// settings stay in effect. A successful read clears the error.
    @discardableResult
    private func loadConfig() -> Bool {
        do {
            config = try configStore.load()
            configError = nil
            return true
        } catch {
            configError = LibraryModel.message(error)
            return false
        }
    }

    /// What launch decides once config.json is readable.
    private func startFromConfig() async {
        if config.setupComplete {
            await applyFolder()
        } else {
            phase = .setup
        }
    }

    private func watchConfig() {
        guard configWatcher == nil else { return }
        try? FileManager.default.createDirectory(at: configStore.configDir, withIntermediateDirectories: true)
        let watcher = FolderWatcher(folder: configStore.configDir) { [weak self] changes in
            guard changes.contains(.entry("config.json")) || changes.contains(.rescan) else { return }
            Task { @MainActor in await self?.configDidChange() }
        }
        do {
            try watcher.start()
            configWatcher = watcher
        } catch {
            library.alert = "Agent Drop can't watch \(configStore.configFile.path) for changes."
        }
    }

    /// Lifecycle operations run one at a time, in call order: each suspends, and one must
    /// never see another's half-applied state.
    private func serially(_ operation: @escaping @MainActor (AppModel) async -> Void) async {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            await operation(self)
        }
        lastOperation = task
        await task.value
    }

    /// Creating and listing the folder is its first access: macOS asks now for a
    /// protected location, and a refusal surfaces as an error here.
    static func touch(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    private static func folderMessage(_ folder: URL, _ error: Error) -> String {
        "Agent Drop can't use \(folder.path): \(LibraryModel.message(error))"
    }
}
