import Foundation

/// Input rules shared by the CLI and the app (spec §4, §4.1).
public enum Validation {
    public static let maxIdentityLength = 200

    /// §4.1: trimmed (spaces/tabs), non-empty, no newlines or control characters, ≤ 200 chars.
    /// Nothing else is interpreted.
    public static func identity(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            throw AgentDropError.invalid("\(field) must not be empty")
        }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard !value.unicodeScalars.contains(where: { forbidden.contains($0) }) else {
            throw AgentDropError.invalid("\(field) must not contain newlines or control characters")
        }
        guard value.count <= maxIdentityLength else {
            throw AgentDropError.invalid("\(field) must be at most \(maxIdentityLength) characters")
        }
        return value
    }

    /// Tags follow the identity rules and keep their case (spec §3 data model).
    public static func tag(_ raw: String) throws -> String {
        try identity(raw, field: "tag")
    }

    /// Free text (title, description, status note): trimmed, non-empty, newlines allowed.
    public static func text(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AgentDropError.invalid("\(field) must not be empty")
        }
        return value
    }

    /// Name rule (spec §4 `drop add`): the resulting top-level name must not be empty,
    /// start with ".", contain "/", or be "." / "..".
    public static func dropName(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/") else {
            throw AgentDropError.invalid(
                "'\(name)' can't be a drop name (it must not be empty, start with '.', or contain '/'); pass --name <visible-name>"
            )
        }
        return name
    }

    /// `--from-under` (spec §4.1): the prefix itself and whole levels beneath it.
    public static func isUnder(_ value: String, prefix: String) -> Bool {
        value == prefix || value.hasPrefix(prefix + "/")
    }

    /// Collision suffix: `plan.md` → `plan-2.md`; folders and extensionless names get `-n` appended.
    public static func suffixed(_ name: String, n: Int, isFolder: Bool) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        if isFolder || ext.isEmpty { return "\(name)-\(n)" }
        return "\(ns.deletingPathExtension)-\(n).\(ext)"
    }

    /// Removes duplicates, keeping the first occurrence's order.
    public static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
