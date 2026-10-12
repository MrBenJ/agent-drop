import CoreServices
import Foundation

/// FSEvents on the drop folder, reduced to what the server cares about: which top-level
/// entry changed, or that the store (`.agentdrop/`) changed.
public final class FolderWatcher: @unchecked Sendable {
    public enum Change: Equatable, Sendable {
        /// Something under `.agentdrop/` changed: new event rows may be waiting.
        case store
        /// A top-level entry (or anything inside it) changed.
        case entry(String)
        /// FSEvents dropped detail; check everything.
        case rescan
    }

    private let root: String
    private let latency: TimeInterval
    private let handler: @Sendable ([Change]) -> Void
    private let queue = DispatchQueue(label: "AgentDrop.FolderWatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(folder: URL, latency: TimeInterval = 0.05, handler: @escaping @Sendable ([Change]) -> Void) {
        root = Self.realPath(folder)
        self.latency = latency
        self.handler = handler
    }

    // No deinit cleanup: start() retains self until stop(), so a started watcher can't be
    // deallocated. Call stop() when done.

    public func start() throws {
        try lock.withLock {
            guard stream == nil else { return }
            // The stream holds a strong reference until stop(), so the watcher can never be
            // deallocated (and run stop() from its own queue) while callbacks may arrive.
            let retained = Unmanaged.passRetained(self)
            var context = FSEventStreamContext(version: 0, info: retained.toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, Self.callback, &context, [root] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else {
                retained.release()
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root])
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                retained.release()
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root])
            }
            stream = created
        }
    }

    /// After this returns, the handler is never called again.
    public func stop() {
        let stopping: FSEventStreamRef? = lock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let stopping else { return }
        FSEventStreamStop(stopping)
        FSEventStreamInvalidate(stopping)
        queue.sync {} // drain a callback that's already running
        FSEventStreamRelease(stopping)
        Unmanaged.passUnretained(self).release() // balances passRetained in start()
    }

    static func classify(path: String, root: String) -> Change? {
        guard path.hasPrefix(root + "/") else { return nil }
        guard let first = path.dropFirst(root.count + 1).split(separator: "/").first else { return nil }
        if first == ".agentdrop" { return .store }
        if first.hasPrefix(".") { return nil }
        return .entry(String(first))
    }

    /// FSEvents reports real paths (`/private/var/...`). `URL.resolvingSymlinksInPath()`
    /// would strip `/private` again, so use realpath(3).
    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard lock.withLock({ stream != nil }) else { return }
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        var changes: [Change] = []
        for (path, flag) in zip(paths, flags) {
            let change = flag & rescanFlags != 0 ? .rescan : Self.classify(path: path, root: root)
            if let change, !changes.contains(change) { changes.append(change) }
        }
        if !changes.isEmpty { handler(changes) }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        watcher.deliver(paths: array, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
    }
}
