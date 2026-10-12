import AgentDropCore
import Foundation
import Observation

/// Everything the main window and the menu bar show, read from the running store.
@MainActor @Observable
public final class LibraryModel {
    public enum Selection: Hashable, Sendable {
        case drop(String)
        /// An unregistered entry, by name.
        case entry(String)
    }

    public private(set) var store: DropStore?
    /// Every drop, archived ones included, newest first.
    public private(set) var drops: [Drop] = []
    public private(set) var unregistered: [UnregisteredEntry] = []
    /// The last reload failed (e.g. "store busy, retry"); the previous contents stay.
    public private(set) var loadError: String?
    public var sidebar: SidebarItem = .allDrops
    public var search = ""
    public var selection: Selection? {
        didSet { if selection != oldValue { selectionChanged() } }
    }
    /// An action failed; the window shows it as an alert.
    public var alert: String?
    /// Bumped by every reload that applied. Previews reload their file when it changes,
    /// since a content change doesn't change the drop's metadata.
    public private(set) var revision = 0
    /// The event log's end when the current snapshot was read: every event up to it is
    /// reflected in `drops`. Later events wait for the next reload.
    @ObservationIgnored public private(set) var loadedSeq: Int64 = 0

    /// Drops the human registered in this window: they never trigger a "new drop" notification.
    @ObservationIgnored public internal(set) var registeredInApp: Set<String> = []
    /// Runs after every reload that applied, with the store it read (new-drop notifications).
    @ObservationIgnored public var afterReload: (@MainActor (DropStore) async -> Void)?
    /// Bumped on attach/detach so a reload from the previous folder never lands.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextTicket = 0
    @ObservationIgnored private var appliedTicket = 0

    public init() {}

    // MARK: Loading

    public func attach(_ store: DropStore) async {
        reset()
        self.store = store
        await reload()
    }

    public func detach() {
        reset()
    }

    private func reset() {
        generation += 1
        store = nil
        drops = []
        unregistered = []
        loadError = nil
        selection = nil
        sidebar = .allDrops
        search = ""
    }

    public func reload() async {
        guard let store else { return }
        let generation = self.generation
        nextTicket += 1
        let ticket = nextTicket
        do {
            let snapshot = try await StoreQueue.run { try Snapshot.load(store) }
            // Reloads can overlap; never let an older snapshot overwrite a newer one.
            guard generation == self.generation, ticket > appliedTicket else { return }
            appliedTicket = ticket
            revision += 1
            drops = snapshot.drops
            unregistered = snapshot.unregistered
            loadedSeq = snapshot.seq
            loadError = nil
            dropStaleSelection()
            await afterReload?(store)
        } catch {
            guard generation == self.generation else { return }
            loadError = Self.message(error)
        }
    }

    private struct Snapshot: Sendable {
        var seq: Int64
        var drops: [Drop]
        var unregistered: [UnregisteredEntry]

        static func load(_ store: DropStore) throws -> Snapshot {
            var filter = ListFilter()
            filter.includeArchived = true
            filter.limit = nil
            // The log's end first: whatever it covers is already in the list read after it.
            let seq = try store.latestSeq()
            return Snapshot(seq: seq, drops: try store.list(filter), unregistered: try store.unregisteredEntries())
        }
    }

    private func dropStaleSelection() {
        switch selection {
        case .drop(let id) where drop(id) == nil: selection = nil
        case .entry(let name) where !unregistered.contains(where: { $0.name == name }): selection = nil
        default: break
        }
    }

    // MARK: What the views show

    public func drop(_ id: String) -> Drop? { drops.first { $0.id == id } }

    public var selectedDrop: Drop? {
        if case .drop(let id) = selection { return drop(id) }
        return nil
    }

    public var selectedEntry: UnregisteredEntry? {
        if case .entry(let name) = selection { return unregistered.first { $0.name == name } }
        return nil
    }

    /// The list column for the current sidebar item and search.
    public var visibleDrops: [Drop] { drops.filter { sidebar.includes($0) && matchesSearch($0) } }

    public var visibleEntries: [UnregisteredEntry] {
        guard case .unregistered = sidebar else { return [] }
        let query = trimmedSearch
        return query.isEmpty ? unregistered : unregistered.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Open, then claimed, then done; empty groups left out.
    public var handoffGroups: [HandoffGroup] {
        let handoffs = visibleDrops
        return HandoffStatus.allCases.compactMap { status in
            let group = handoffs.filter { $0.status == status }
            return group.isEmpty ? nil : HandoffGroup(status: status, drops: group)
        }
    }

    /// Spec §4 Terms "Unread": the menu bar badge.
    public var unreadCount: Int { drops.count { $0.isUnread } }
    public var inboxDrops: [Drop] { drops.filter { $0.isInInbox } }
    public var inboxCount: Int { inboxDrops.count }
    public var unregisteredCount: Int { unregistered.count }
    /// The menu bar's list: the 10 most recent drops that aren't archived.
    public var recentDrops: [Drop] { Array(drops.lazy.filter { !$0.archived }.prefix(10)) }

    public var projectTree: [IdentityNode] { IdentityTree.build(activeDrops.compactMap(\.project)) }
    public var fromTree: [IdentityNode] { IdentityTree.build(activeDrops.map(\.from)) }
    public var tags: [String] {
        Set(activeDrops.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var activeDrops: [Drop] { drops.filter { !$0.archived } }
    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Spec §6: search filters title, description and filename.
    public func matchesSearch(_ drop: Drop) -> Bool {
        let query = trimmedSearch
        guard !query.isEmpty else { return true }
        return drop.title.localizedCaseInsensitiveContains(query)
            || (drop.description?.localizedCaseInsensitiveContains(query) ?? false)
            || drop.filename.localizedCaseInsensitiveContains(query)
    }

    // MARK: Navigation

    /// Shows the drop: from a deep link, the menu, or a notification. Switches to a view
    /// that contains it when the current one doesn't. False (with an alert) if no drop in
    /// the current folder has that id.
    @discardableResult
    public func reveal(_ id: String) async -> Bool {
        if drop(id) == nil { await reload() }
        guard let drop = drop(id) else {
            alert = "No drop matches '\(id)' in the current drop folder."
            return false
        }
        if !sidebar.includes(drop) || !matchesSearch(drop) {
            sidebar = drop.archived ? .archived : .allDrops
            search = ""
        }
        selection = .drop(id)
        return true
    }

    /// Spec §6: viewing a drop in the detail pane sets `read_at` (first view only).
    private func selectionChanged() {
        guard let drop = selectedDrop, drop.readAt == nil, let store else { return }
        let id = drop.id
        Task {
            do {
                _ = try await StoreQueue.run { try store.markRead(id) }
                await reload()
            } catch {
                alert = Self.message(error)
            }
        }
    }

    static func message(_ error: Error) -> String {
        (error as? AgentDropError)?.message ?? error.localizedDescription
    }
}
