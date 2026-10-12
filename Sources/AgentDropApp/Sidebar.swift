import AgentDropCore
import Foundation

/// The main window's sidebar (spec §6 Main window).
public enum SidebarItem: Hashable, Sendable {
    case allDrops
    case inbox
    case handoffs
    case unregistered
    case archived
    /// A project, or a project level when values contain `/` (matches the level and beneath).
    case project(String)
    case tag(String)
    /// A `from` identity or level, like `drop list --from-under`.
    case from(String)

    /// Whether the drop belongs in this view. `.unregistered` lists entries, not drops.
    public func includes(_ drop: Drop) -> Bool {
        switch self {
        case .allDrops: !drop.archived
        case .inbox: drop.isInInbox
        case .handoffs: drop.kind == .handoff && !drop.archived
        case .unregistered: false
        case .archived: drop.archived
        case .project(let prefix): !drop.archived && drop.project.map { Validation.isUnder($0, prefix: prefix) } == true
        case .tag(let tag): !drop.archived && drop.tags.contains(tag)
        case .from(let prefix): !drop.archived && Validation.isUnder(drop.from, prefix: prefix)
        }
    }
}

/// One level of a `/`-separated identity (spec §4.1), for the Projects and From lists.
public struct IdentityNode: Identifiable, Hashable, Sendable {
    /// The full value up to this level, e.g. `djleague/autodev`. Used as the filter prefix.
    public var path: String
    /// This level's own name, e.g. `autodev`. May be empty for values like `a//b`.
    public var name: String
    /// Values at this level or beneath it.
    public var count: Int
    /// nil for a leaf, so SwiftUI's `OutlineGroup` shows no disclosure triangle.
    public var children: [IdentityNode]?
    public var id: String { path }
}

public enum IdentityTree {
    /// Values without `/` come out as a flat list; values with `/` as a tree. Each value
    /// counts once at every level above it. Levels are split exactly at `/`, so a node's
    /// path is always a real prefix of the values beneath it.
    public static func build(_ values: [String]) -> [IdentityNode] {
        nodes(values.map { ($0, $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init)) }, depth: 0)
    }

    private static func nodes(_ items: [(value: String, parts: [String])], depth: Int) -> [IdentityNode] {
        var groups: [String: [(value: String, parts: [String])]] = [:]
        for item in items { groups[item.parts[depth], default: []].append(item) }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let group = groups[name]!
            let deeper = group.filter { $0.parts.count > depth + 1 }
            return IdentityNode(path: group[0].parts[0...depth].joined(separator: "/"), name: name, count: group.count,
                                children: deeper.isEmpty ? nil : nodes(deeper, depth: depth + 1))
        }
    }
}

/// The Handoffs view groups by status (spec §6).
public struct HandoffGroup: Identifiable, Equatable, Sendable {
    public var status: HandoffStatus
    public var drops: [Drop]
    public var id: HandoffStatus { status }
}
