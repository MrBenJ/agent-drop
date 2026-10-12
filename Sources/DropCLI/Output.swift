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

    /// For human-readable output only (JSON escapes these itself). Titles come from file
    /// contents, so control characters must never reach the terminal: tab, CR and LF become
    /// spaces (LF is kept with `keepNewlines`), every other C0/C1 control and DEL becomes U+FFFD.
    static func terminalSafe(_ text: String, keepNewlines: Bool = false) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A where keepNewlines: scalars.append(scalar)
            case 0x09, 0x0A, 0x0D: scalars.append(" ")
            case 0x00..<0x20, 0x7F...0x9F: scalars.append("\u{FFFD}")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// One tab-separated line: id, state, title, project, from, created[, flags].
    static func line(for drop: Drop) -> String {
        let state = drop.status.map { "handoff:\($0.rawValue)" } ?? "note"
        var fields = [drop.id, state, drop.title, drop.project ?? "-", drop.from, drop.createdAt.iso]
        if drop.archived { fields.append("[archived]") }
        if drop.missing { fields.append("[missing]") }
        return fields.map { terminalSafe($0) }.joined(separator: "\t")
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
        return rows.map { label, value in
            "\(label):".padding(toLength: 13, withPad: " ", startingAt: 0)
                + terminalSafe(value, keepNewlines: label == "description")
        }
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
