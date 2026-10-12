import AgentDropServer
import Foundation

/// One entry in a folder drop's file tree (spec §6 Rendering).
public struct FileNode: Identifiable, Hashable, Sendable {
    /// Relative to the folder drop, e.g. `docs/plan.md`.
    public var path: String
    public var name: String
    /// `file`, `directory`, `symlink` or `other`, as in the server's folder listing.
    public var type: String
    public var size: Int64?
    /// A link's target text; links are never followed.
    public var target: String?
    /// nil for anything but a directory.
    public var children: [FileNode]?
    public var id: String { path }
}

public enum FolderTree {
    /// The folder drop's contents as a tree, sorted by name. Dot-entries are hidden.
    public static func load(_ folder: URL) throws -> [FileNode] {
        nodes(try FolderListing(id: "", folder: folder))
    }

    static func nodes(_ listing: FolderListing) -> [FileNode] {
        let visible = listing.entries.filter { entry in
            !entry.path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        var byParent: [String: [FolderListing.Entry]] = [:]
        for entry in visible {
            let parent = entry.path.split(separator: "/").dropLast().joined(separator: "/")
            byParent[parent, default: []].append(entry)
        }
        func build(_ parent: String) -> [FileNode] {
            (byParent[parent] ?? []).map { entry in
                FileNode(path: entry.path, name: String(entry.path.split(separator: "/").last ?? ""),
                         type: entry.type, size: entry.size, target: entry.target,
                         children: entry.type == "directory" ? build(entry.path) : nil)
            }
        }
        return build("")
    }

    /// What a folder drop shows under its tree: `README.md`, else its first `.md`
    /// alphabetically, at the top level (the same file its title comes from).
    public static func defaultDocument(_ nodes: [FileNode]) -> FileNode? {
        let files = nodes.filter { $0.type == "file" }
        return files.first { $0.name.lowercased() == "readme.md" }
            ?? files.filter { $0.name.lowercased().hasSuffix(".md") }.sorted { $0.name < $1.name }.first
    }
}
