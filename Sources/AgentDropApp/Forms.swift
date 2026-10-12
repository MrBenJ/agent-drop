import AgentDropCore
import Foundation

/// The detail pane's **Edit metadata** sheet (spec §6). Empty fields are not "clear":
/// like `drop edit`, the store can't clear a description or project yet.
public struct MetadataForm: Equatable, Sendable {
    public var title: String
    public var description: String
    public var project: String
    public var tags: [String]
    public var kind: DropKind

    public init(_ drop: Drop) {
        title = drop.title
        description = drop.description ?? ""
        project = drop.project ?? ""
        tags = drop.tags
        kind = drop.kind
    }

    /// Spec §4.2 "Changing kind": the picker is disabled while a handoff is claimed or done.
    public static func canChangeKind(_ drop: Drop) -> Bool {
        drop.status != .claimed && drop.status != .done
    }

    /// The edit to apply, or nil when nothing changed.
    public func request(for drop: Drop) throws -> EditRequest? {
        var request = EditRequest()
        let title = Self.trim(self.title)
        guard !title.isEmpty else { throw AgentDropError.invalid("The title can't be empty.") }
        if title != drop.title { request.title = title }
        request.description = try Self.changed(description, from: drop.description, field: "description")
        request.project = try Self.changed(project, from: drop.project, field: "project")
        let tags = TagList.normalized(self.tags)
        request.addTags = tags.filter { !drop.tags.contains($0) }
        request.removeTags = drop.tags.filter { !tags.contains($0) }
        if kind != drop.kind {
            guard Self.canChangeKind(drop) else {
                throw AgentDropError.conflict("Release or reopen this handoff before changing its kind.")
            }
            request.kind = kind
        }
        let unchanged = request.title == nil && request.description == nil && request.project == nil
            && request.addTags.isEmpty && request.removeTags.isEmpty && request.kind == nil
        return unchanged ? nil : request
    }

    private static func changed(_ raw: String, from current: String?, field: String) throws -> String? {
        let value = trim(raw)
        if value.isEmpty {
            guard current == nil else {
                throw AgentDropError.invalid("Agent Drop can't clear the \(field) yet; change the text instead.")
            }
            return nil
        }
        return value == current ? nil : value
    }

    static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The **Register** form for an unregistered entry (spec §3.2): registers it in place,
/// exactly like `drop add <path-in-folder>`. `from` is required and never filled in.
public struct RegisterForm: Equatable, Sendable {
    public var title = ""
    public var description = ""
    public var from = ""
    public var project = ""
    public var tags: [String] = []
    public var handoff = false

    public init() {}

    public func request(for entry: UnregisteredEntry, in folder: URL) throws -> AddRequest {
        let from = MetadataForm.trim(self.from)
        guard !from.isEmpty else {
            throw AgentDropError.invalid("“From” is required: who or what made this file.")
        }
        func optional(_ value: String) -> String? {
            let trimmed = MetadataForm.trim(value)
            return trimmed.isEmpty ? nil : trimmed
        }
        return AddRequest(source: .path(folder.appendingPathComponent(entry.name, isDirectory: entry.isFolder)),
                          title: optional(title), description: optional(description), project: optional(project),
                          tags: TagList.normalized(tags), from: from, handoff: handoff)
    }
}

/// Tags as typed into a form: trimmed, empty ones dropped, duplicates removed (exact
/// match, like the store: `PR` and `pr` are different tags).
public enum TagList {
    public static func normalized(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.map(MetadataForm.trim).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
