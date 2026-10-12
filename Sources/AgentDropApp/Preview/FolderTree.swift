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
    /// The folder drop's contents as a tree, sorted by name. Dot-entries (`.git`, …) are
    /// skipped without being walked. An entry that vanishes or can't be read mid-walk is
    /// left out (an unreadable directory shows empty) instead of failing the whole tree.
    /// Throws only when the folder itself can't be listed. Links are never followed.
    public static func load(_ folder: URL) throws -> [FileNode] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return walk(folder, names: names, prefix: "")
    }

    /// `load` on a private queue: a folder drop can be a large tree, and the window
    /// re-reads it on every change.
    public static func loadOffMain(_ folder: URL) async -> [FileNode] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: (try? load(folder)) ?? []) }
        }
    }

    private static let queue = DispatchQueue(label: "AgentDrop.app.folderTree")

    private static func walk(_ directory: URL, names: [String], prefix: String) -> [FileNode] {
        let fm = FileManager.default
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name)
            let path = prefix + name
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return nil } // doesn't follow links
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?:
                let children = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                return FileNode(path: path, name: name, type: "directory", size: nil, target: nil,
                                children: walk(url, names: children, prefix: path + "/"))
            case .typeRegular?:
                return FileNode(path: path, name: name, type: "file",
                                size: (attributes[.size] as? NSNumber)?.int64Value, target: nil, children: nil)
            case .typeSymbolicLink?:
                return FileNode(path: path, name: name, type: "symlink", size: nil,
                                target: try? fm.destinationOfSymbolicLink(atPath: url.path), children: nil)
            default:
                return FileNode(path: path, name: name, type: "other", size: nil, target: nil, children: nil)
            }
        }
    }

    /// What a folder drop shows under its tree: `README.md`, else its first `.md`
    /// alphabetically, at the top level (the same file its title comes from).
    public static func defaultDocument(_ nodes: [FileNode]) -> FileNode? {
        let files = nodes.filter { $0.type == "file" }
        return files.first { $0.name.lowercased() == "readme.md" }
            ?? files.filter { $0.name.lowercased().hasSuffix(".md") }.sorted { $0.name < $1.name }.first
    }
}
