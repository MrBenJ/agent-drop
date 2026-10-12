import Foundation
import GRDB

public enum AddSource: Sendable {
    case path(URL)
    case stdin(Data)
}

public struct AddRequest: Sendable {
    public var source: AddSource
    public var name: String?
    public var title: String?
    public var description: String?
    public var project: String?
    public var tags: [String]
    public var from: String
    public var handoff: Bool
    public var move: Bool

    public init(source: AddSource, name: String? = nil, title: String? = nil, description: String? = nil,
                project: String? = nil, tags: [String] = [], from: String, handoff: Bool = false,
                move: Bool = false) {
        self.source = source
        self.name = name
        self.title = title
        self.description = description
        self.project = project
        self.tags = tags
        self.from = from
        self.handoff = handoff
        self.move = move
    }
}

extension DropStore {
    private struct Placement {
        let filename: String
        let isFolder: Bool
        /// Our own copy, removed if registration fails afterwards.
        let cleanupOnFailure: URL?
    }

    /// Spec §4 `drop add`.
    public func add(_ request: AddRequest) throws -> Drop {
        let from = try Validation.identity(request.from, field: "--from")
        let project = try request.project.map { try Validation.identity($0, field: "--project") }
        let tags = Validation.unique(try request.tags.map(Validation.tag))
        let title = try request.title.map { try Validation.text($0, field: "--title") }
        let description = try request.description.map { try Validation.text($0, field: "--desc") }

        let placement = try place(request)
        do {
            let url = folder.appendingPathComponent(placement.filename)
            let finalTitle = title
                ?? TitleExtractor.title(for: url, isFolder: placement.isFolder)
                ?? TitleExtractor.fallback(filename: placement.filename, isFolder: placement.isFolder)
            return try insert(placement, title: finalTitle, description: description, project: project,
                              tags: tags, from: from, handoff: request.handoff)
        } catch {
            if let copy = placement.cleanupOnFailure { try? FileManager.default.removeItem(at: copy) }
            throw error
        }
    }

    func isRegistered(filename: String) throws -> Bool {
        try read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM drops WHERE filename = ?)",
                              arguments: [filename]) ?? false
        }
    }

    private func place(_ request: AddRequest) throws -> Placement {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        switch request.source {
        case .stdin(let data):
            guard let rawName = request.name else {
                throw AgentDropError.invalid("drop add - requires --name <filename>")
            }
            let name = try Validation.dropName(rawName)
            guard !data.isEmpty else { throw AgentDropError.invalid("stdin was empty; nothing to drop") }
            guard !request.move else { throw AgentDropError.invalid("--move can't be used with stdin") }
            let final = try claimName(name, isFolder: false) { try data.write(to: $0, options: .withoutOverwriting) }
            return Placement(filename: final, isFolder: false, cleanupOnFailure: folder.appendingPathComponent(final))

        case .path(let rawSource):
            let source = rawSource.standardizedFileURL
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fm.attributesOfItem(atPath: source.path) // does not follow symlinks
            } catch {
                throw AgentDropError.notFound("No such file or directory: \(source.path)")
            }
            let isFolder: Bool
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular?: isFolder = false
            case .typeDirectory?: isFolder = true
            case .typeSymbolicLink?:
                throw AgentDropError.invalid("\(source.path) is a symlink; symlinks can't be dropped")
            default:
                throw AgentDropError.invalid("\(source.path) is not a regular file or directory")
            }

            let root = folder.resolvingSymlinksInPath().path
            let resolvedSource = source.resolvingSymlinksInPath().path
            if resolvedSource == root || root.hasPrefix(resolvedSource + "/") {
                throw AgentDropError.invalid("Can't drop the drop folder itself or a folder that contains it")
            }
            let parent = source.deletingLastPathComponent().resolvingSymlinksInPath().path

            if parent == root {
                // Already a top-level entry: register in place (optionally renaming).
                let current = source.lastPathComponent
                if try isRegistered(filename: current) {
                    throw AgentDropError.conflict("\(current) is already registered")
                }
                guard let requested = request.name, requested != current else {
                    return Placement(filename: try Validation.dropName(current), isFolder: isFolder,
                                     cleanupOnFailure: nil)
                }
                let name = try Validation.dropName(requested)
                let destination = folder.appendingPathComponent(name)
                let taken = try isRegistered(filename: name)
                if taken || fm.fileExists(atPath: destination.path) {
                    throw AgentDropError.conflict("\(name) already exists in the drop folder")
                }
                try fm.moveItem(at: source, to: destination)
                return Placement(filename: name, isFolder: isFolder, cleanupOnFailure: nil)
            }

            if parent.hasPrefix(root + "/") {
                throw AgentDropError.invalid(
                    "\(source.path) is inside a subfolder of the drop folder; only top-level entries can be drops")
            }

            let name = try Validation.dropName(request.name ?? source.lastPathComponent)
            let final = try claimName(name, isFolder: isFolder) { destination in
                if request.move {
                    try fm.moveItem(at: source, to: destination)
                } else {
                    try fm.copyItem(at: source, to: destination)
                }
            }
            return Placement(filename: final, isFolder: isFolder,
                             cleanupOnFailure: request.move ? nil : folder.appendingPathComponent(final))
        }
    }

    /// Writes to the first free name (`plan.md`, `plan-2.md`, …). Losing a race to another
    /// writer surfaces as "file exists" and moves on to the next candidate.
    private func claimName(_ name: String, isFolder: Bool, write: (URL) throws -> Void) throws -> String {
        for n in 1...1_000 {
            let candidate = n == 1 ? name : Validation.suffixed(name, n: n, isFolder: isFolder)
            let destination = folder.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            if try isRegistered(filename: candidate) { continue }
            do {
                try write(destination)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw AgentDropError.conflict("Couldn't find a free name for \(name)")
    }

    private func insert(_ placement: Placement, title: String, description: String?, project: String?,
                        tags: [String], from: String, handoff: Bool) throws -> Drop {
        let now = self.now()
        do {
            return try mutate { db in
                var id = DropID.generate()
                while try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM drops WHERE id = ?)",
                                        arguments: [id]) == true {
                    id = DropID.generate()
                }
                let drop = Drop(id: id, filename: placement.filename, isFolder: placement.isFolder, title: title,
                                description: description, project: project, tags: tags, from: from,
                                createdAt: now, updatedAt: now, readAt: nil,
                                kind: handoff ? .handoff : .note, status: handoff ? .open : nil,
                                claimedBy: nil, statusNote: nil, archived: false, missing: false)
                try db.execute(
                    sql: """
                        INSERT INTO drops (id, filename, is_folder, title, description, project, from_identity,
                                           created_at, updated_at, kind, status)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [drop.id, drop.filename, drop.isFolder, drop.title, drop.description, drop.project,
                                drop.from, now.unixTime, now.unixTime, drop.kind.rawValue, drop.status?.rawValue])
                for tag in tags {
                    try db.execute(sql: "INSERT INTO drop_tag (drop_id, tag) VALUES (?, ?)", arguments: [id, tag])
                }
                try EventLog.append(db, type: .created, dropID: id, dataJSON: EventLog.encode(json(drop)),
                                    before: nil, after: drop, at: now, retention: retention)
                return drop
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw AgentDropError.conflict("\(placement.filename) is already registered")
        }
    }
}
