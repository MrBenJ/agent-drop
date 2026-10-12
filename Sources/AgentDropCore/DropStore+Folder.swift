import Foundation
import GRDB

/// A top-level entry of the drop folder with no record (spec §3.2 "unregistered").
public struct UnregisteredEntry: Equatable, Sendable, Identifiable {
    public var name: String
    public var isFolder: Bool
    public var modifiedAt: Date?
    public var id: String { name }

    public init(name: String, isFolder: Bool, modifiedAt: Date?) {
        self.name = name
        self.isFolder = isFolder
        self.modifiedAt = modifiedAt
    }
}

/// Folder reconciliation for the app (spec §3.2).
extension DropStore {
    /// Regular files and directories at the top level that no record claims. Dot-entries,
    /// symlinks and anything else (sockets, devices) are never drops. Names are compared
    /// byte for byte, like `resolve`: `plan.md` is unregistered even if `Plan.md` has a record.
    public func unregisteredEntries() throws -> [UnregisteredEntry] {
        let registered = try read { db in
            Set(try String.fetchAll(db, sql: "SELECT filename FROM drops").map { Array($0.utf8) })
        }
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: folder.path)
        return names.compactMap { name -> UnregisteredEntry? in
            guard !name.hasPrefix("."), !registered.contains(Array(name.utf8)),
                  let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            else { return nil }
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else { return nil }
            return UnregisteredEntry(name: name, isFolder: type == .typeDirectory,
                                     modifiedAt: attributes[.modificationDate] as? Date)
        }
        .sorted { ($0.modifiedAt ?? .distantPast, $1.name) > ($1.modifiedAt ?? .distantPast, $0.name) }
    }

    /// Re-checks every record against the folder (archived ones too), recording `missing`
    /// or a return exactly as `checkPresence` does. The app runs it on launch and after a
    /// folder switch; it returns the drops whose state changed.
    @discardableResult
    public func reconcile() throws -> [Drop] {
        let ids = try read { db in try String.fetchAll(db, sql: "SELECT id FROM drops ORDER BY rowid") }
        var changed: [Drop] = []
        for id in ids {
            guard let before = try read({ db in try Self.fetchDrop(db, id: id) }) else { continue }
            let after = try refreshMissing(before)
            if after.missing != before.missing { changed.append(after) }
        }
        return changed
    }
}
