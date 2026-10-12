import AgentDropCore
import Foundation

/// One notification to show (spec §6 "Notify on new drops"). Clicking it opens `dropID`,
/// or just the window for a summary.
public struct NewDropNotice: Equatable, Sendable {
    public var title: String
    public var body: String
    public var dropID: String?
}

/// Shows notices. The app's implementation uses UserNotifications; tests record them.
@MainActor
public protocol NoticePosting: AnyObject {
    func post(_ notices: [NewDropNotice])
}

/// Turns `created` events into notices. It reads the event log, not the list, so a drop
/// that arrives and is archived between two reloads is still seen once, and nothing that
/// existed before the app started is ever announced.
@MainActor
public final class NewDropNotifier {
    /// Above this many new drops at once, one summary instead of a notice each.
    static let summaryThreshold = 3
    private weak var store: DropStore?
    private var lastSeq: Int64 = 0
    private var checking = false
    private var checkAgain = false

    public init() {}

    /// Notices for drops created since the last check. The first check for a store (app
    /// start, folder switch) only records where its log ends.
    public func check(_ store: DropStore, library: LibraryModel, enabled: Bool) async -> [NewDropNotice] {
        guard !checking else {
            checkAgain = true
            return []
        }
        checking = true
        defer { checking = false }
        var notices: [NewDropNotice] = []
        repeat {
            checkAgain = false
            notices += await checkOnce(store, library: library, enabled: enabled)
        } while checkAgain
        return notices
    }

    private func checkOnce(_ store: DropStore, library: LibraryModel, enabled: Bool) async -> [NewDropNotice] {
        // Only events the library's snapshot already reflects: a drop created after the
        // snapshot was read isn't in `library` yet, and is announced after the next reload.
        let upTo = library.loadedSeq
        guard self.store === store else {
            self.store = store
            lastSeq = upTo
            return []
        }
        let after = lastSeq
        guard upTo > after,
              let events = try? await StoreQueue.run({ try store.events(afterSeq: after).filter { $0.seq <= upTo } })
        else { return [] }
        lastSeq = upTo
        guard enabled else { return [] }
        let drops = events.filter { $0.type == .created }
            .compactMap { library.drop($0.dropID) }
            .filter { !$0.archived && !$0.missing && !library.registeredInApp.contains($0.id) }
        return Self.notices(for: drops)
    }

    static func notices(for drops: [Drop]) -> [NewDropNotice] {
        guard drops.count <= summaryThreshold else {
            let titles = drops.prefix(summaryThreshold).map(\.title).joined(separator: ", ")
            return [NewDropNotice(title: "\(drops.count) new drops", body: titles + ", …", dropID: nil)]
        }
        return drops.map { drop in
            let source = [drop.kind == .handoff ? "Handoff from \(drop.from)" : "From \(drop.from)", drop.project]
                .compactMap { $0 }.joined(separator: " · ")
            let body = [source, drop.description].compactMap { $0 }.joined(separator: "\n")
            return NewDropNotice(title: drop.title, body: body, dropID: drop.id)
        }
    }
}
