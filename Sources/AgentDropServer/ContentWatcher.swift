import AgentDropCore
import Foundation

/// Turns folder changes into `content` events (spec §5.1), debounced per entry.
///
/// A drop's contents count as changed only when its fingerprint (size, modification time
/// and file identity of everything inside, ignoring dot-files and folders' own timestamps)
/// differs from the last one seen. A drop seen for the first time just gets a baseline,
/// so `drop add` never produces a `content` event. The same pass notices deleted and
/// returning entries and records them through `checkPresence` (spec §3.2).
public actor ContentWatcher {
    private let store: DropStore
    private let debounce: Duration
    private let onChange: @Sendable () async -> Void
    private var fingerprints: [String: Int] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private var stopped = false
    private let beforeFingerprint: @Sendable () async -> Void

    /// `onChange` runs after this watcher wrote one or more events. `beforeFingerprint` is
    /// a test hook.
    public init(store: DropStore, debounce: Duration = .milliseconds(300),
                onChange: @escaping @Sendable () async -> Void,
                beforeFingerprint: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.debounce = debounce
        self.onChange = onChange
        self.beforeFingerprint = beforeFingerprint
    }

    /// Records a baseline for every present drop that has none yet. Run at start and on
    /// every store change, so drops registered without a file change (in place) get one.
    public func baselineNewDrops() {
        guard let drops = try? allDrops() else { return }
        for drop in drops where fingerprints[drop.id] == nil && !drop.missing {
            fingerprints[drop.id] = Self.fingerprint(of: store.path(of: drop), isFolder: drop.isFolder)
        }
    }

    /// Something changed in the top-level entry `name`. Settles after `debounce` of quiet.
    public func entryChanged(_ name: String) {
        guard !stopped else { return }
        pending[name]?.cancel()
        pending[name] = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.settle(name)
        }
    }

    /// FSEvents lost detail: treat every drop as possibly changed.
    public func rescan() {
        guard let drops = try? allDrops() else { return }
        for drop in drops { entryChanged(drop.filename) }
    }

    /// The recorded fingerprint, if any. For tests.
    func baseline(for id: String) -> Int? { fingerprints[id] }

    /// The service is stopping: drop unsettled work and ignore changes that still arrive
    /// from FSEvents callbacks already in flight.
    public func stop() {
        stopped = true
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    private func settle(_ name: String) async {
        pending[name] = nil
        guard !stopped, let drop = try? store.drop(filename: name) else { return }
        var wrote = false
        do {
            let checked = try store.checkPresence(drop.id)
            wrote = checked.missing != drop.missing
            if checked.missing {
                fingerprints[drop.id] = nil
            } else {
                await beforeFingerprint()
                guard let current = await Self.fingerprintOffPool(of: store.path(of: checked),
                                                                   isFolder: checked.isFolder) else {
                    // The entry vanished (or changed kind) after the presence check: record
                    // that instead, never a content change.
                    guard !stopped else { return }
                    let rechecked = try store.checkPresence(drop.id)
                    if rechecked.missing { fingerprints[drop.id] = nil }
                    wrote = wrote || rechecked.missing != checked.missing
                    if wrote { await onChange() }
                    return
                }
                guard !stopped else { return }
                let previous = fingerprints.updateValue(current, forKey: drop.id)
                // A return is reported by its `metadata {missing: false}` event; a first
                // sighting only sets the baseline.
                if !drop.missing, let previous, previous != current {
                    try store.recordContentChange(drop.id)
                    wrote = true
                }
            }
        } catch {
            // e.g. "store busy": skip this round; the next change to the entry retries.
        }
        if wrote { await onChange() }
    }

    private func allDrops() throws -> [Drop] {
        var filter = ListFilter()
        filter.includeArchived = true
        filter.limit = nil
        return try store.list(filter)
    }

    /// A private serial queue: unlike `DispatchQueue.global()`, whose threads are capped at
    /// about one per core and can all be blocked by other work, it always gets a thread.
    private static let fingerprintQueue = DispatchQueue(label: "AgentDrop.ContentWatcher.fingerprint")

    /// A folder drop can be a large tree; walk it off the shared concurrency pool.
    static func fingerprintOffPool(of url: URL, isFolder: Bool) async -> Int? {
        await withCheckedContinuation { continuation in
            fingerprintQueue.async {
                continuation.resume(returning: fingerprint(of: url, isFolder: isFolder))
            }
        }
    }

    /// nil when the entry itself is absent or not the expected kind (links never count).
    static func fingerprint(of url: URL, isFolder: Bool) -> Int? {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        guard type == (isFolder ? .typeDirectory : .typeRegular) else { return nil }
        var hasher = Hasher()
        if isFolder {
            walk(url, prefix: "", into: &hasher)
        } else {
            combine(url, relative: "", into: &hasher)
        }
        return hasher.finalize()
    }

    private static func walk(_ directory: URL, prefix: String, into hasher: inout Hasher) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for name in names {
            let url = directory.appendingPathComponent(name)
            let isDirectory = combine(url, relative: prefix + name, into: &hasher)
            if isDirectory { walk(url, prefix: prefix + name + "/", into: &hasher) }
        }
    }

    /// Returns true for a real directory (links are never followed).
    @discardableResult
    private static func combine(_ url: URL, relative: String, into hasher: inout Hasher) -> Bool {
        hasher.combine(relative)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            hasher.combine("absent")
            return false
        }
        let type = attributes[.type] as? FileAttributeType
        hasher.combine(type?.rawValue)
        if type == .typeDirectory { return true } // its own mtime changes with Finder's .DS_Store
        hasher.combine((attributes[.size] as? NSNumber)?.int64Value)
        hasher.combine((attributes[.modificationDate] as? Date)?.timeIntervalSince1970)
        hasher.combine((attributes[.systemFileNumber] as? NSNumber)?.int64Value)
        if type == .typeSymbolicLink {
            hasher.combine(try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        }
        return false
    }
}
