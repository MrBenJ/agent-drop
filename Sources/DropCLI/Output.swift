import AgentDropCore
import Foundation

enum Output {
    static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }

    static func emit(_ line: String) { CLIContext.current.stdout.line(line) }
    static func emitJSON<T: Encodable>(_ value: T) { emit(jsonString(value)) }

    /// One tab-separated line: id, state, title, project, from, created[, flags].
    static func line(for drop: Drop) -> String {
        let state = drop.status.map { "handoff:\($0.rawValue)" } ?? "note"
        var fields = [drop.id, state, drop.title, drop.project ?? "-", drop.from, drop.createdAt.iso]
        if drop.archived { fields.append("[archived]") }
        if drop.missing { fields.append("[missing]") }
        return fields.joined(separator: "\t")
    }

    static func details(for drop: Drop, path: String) -> String {
        var rows: [(String, String)] = [("id", drop.id), ("title", drop.title), ("path", path)]
        rows.append(("kind", drop.status.map { "handoff (\($0.rawValue))" } ?? "note"))
        if let by = drop.claimedBy { rows.append(("claimed by", by)) }
        if let note = drop.statusNote { rows.append(("status note", note)) }
        rows.append(("from", drop.from))
        rows.append(("project", drop.project ?? "-"))
        rows.append(("tags", drop.tags.isEmpty ? "-" : drop.tags.joined(separator: ", ")))
        if let description = drop.description { rows.append(("description", description)) }
        rows.append(("created", drop.createdAt.iso))
        rows.append(("updated", drop.updatedAt.iso))
        rows.append(("folder drop", drop.isFolder ? "yes" : "no"))
        rows.append(("archived", drop.archived ? "yes" : "no"))
        rows.append(("missing", drop.missing ? "yes" : "no"))
        return rows.map { "\($0.0):".padding(toLength: 13, withPad: " ", startingAt: 0) + $0.1 }
            .joined(separator: "\n")
    }

    /// Mutating commands: JSON object, or the one-line summary.
    static func printDrop(_ drop: Drop, store: DropStore, json: Bool) {
        if json { emitJSON(store.json(drop)) } else { emit(line(for: drop)) }
    }

    static func printDrops(_ drops: [Drop], store: DropStore, json: Bool) {
        if json {
            emitJSON(drops.map(store.json))
        } else {
            drops.forEach { emit(line(for: $0)) }
        }
    }
}
