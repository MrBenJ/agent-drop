import Foundation

/// The private copy Quick Look shows for one file (see `NoFollowFile.snapshot`), retaken
/// only when the file itself changes. Resetting Quick Look's item on every library reload
/// made the preview blank and redraw (flash) while unrelated files changed.
public final class QuickLookSnapshot {
    struct Key: Equatable {
        var path: String
        var identity: NoFollowFile.Identity?
    }

    /// What Quick Look should show, or nil (refused or failed).
    public private(set) var url: URL?
    private var key: Key?
    private let take: (String, URL) -> URL?

    /// `take` is a test hook.
    public init(take: @escaping (String, URL) -> URL? = { NoFollowFile.snapshot($0, under: $1) }) {
        self.take = take
    }

    /// A retaken snapshot: show `url`, then discard `previous` (Quick Look must let go of it first).
    public struct Change: Equatable {
        public var url: URL?
        public var previous: URL?
    }

    /// Retakes the snapshot if the file at `relativePath` changed since the last one. nil
    /// when nothing changed and Quick Look must be left alone.
    public func update(_ relativePath: String, under root: URL) -> Change? {
        let key = Key(path: relativePath, identity: NoFollowFile.identity(relativePath, under: root))
        guard key != self.key else { return nil }
        let previous = url
        url = take(relativePath, root)
        // A readable file whose snapshot failed (e.g. the temporary folder was full) is
        // retried on the next update; a refused one (a link, gone) waits for a change.
        self.key = url == nil && key.identity != nil ? nil : key
        guard previous != nil || url != nil else { return nil }
        return Change(url: url, previous: previous)
    }

    public func discard() {
        if let url { NoFollowFile.discardSnapshot(url) }
        url = nil
        key = nil
    }
}
