import Foundation
import GRDB

public enum AddSource: Sendable {
    case path(URL)
    case stdin(Data)
    /// Content already inside this store's `.agentdrop/staging/<uuid>/`, owned by the caller
    /// (who deletes its staging directory afterwards).
    case staged(URL, isFolder: Bool)
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
    /// What `stage` prepared outside the write lock.
    private enum Staged {
        /// Our private copy (or stdin content) inside `.agentdrop/staging`, ready to move into place.
        case copy(URL, isFolder: Bool, name: String)
        /// `--move` from outside the drop folder.
        case move(URL, isFolder: Bool, name: String)
        /// Already a top-level entry; optionally renamed first.
        case inPlace(URL, isFolder: Bool, rename: String?)
    }

    private struct Placement {
        let filename: String
        let isFolder: Bool
        /// Puts the filesystem back if registration fails afterwards.
        let undo: () -> Void
    }

    /// Spec §4 `drop add`.
    public func add(_ request: AddRequest) throws -> Drop {
        let from = try Validation.identity(request.from, field: "--from")
        let project = try request.project.map { try Validation.identity($0, field: "--project") }
        let tags = Validation.unique(try request.tags.map(Validation.tag))
        let title = try request.title.map { try Validation.text($0, field: "--title") }
        let description = try request.description.map { try Validation.text($0, field: "--desc") }

        // Copying can take a while, so it happens before the write lock: a large folder
        // must not make other agents' writes time out.
        var stagingDirectory: URL?
        defer { if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) } }
        let staged = try stage(request, stagingDirectory: &stagingDirectory)
        try hooks.afterStaging()

        // Hold the cross-process write lock from placement through registration and
        // cleanup. Another agent must not register a copy that we may still remove.
        return try mutate { db in
            let placement = try place(staged, db: db)
            do {
                try hooks.beforeInsert()
                let url = folder.appendingPathComponent(placement.filename)
                let finalTitle = title
                    ?? TitleExtractor.title(for: url, isFolder: placement.isFolder)
                    ?? TitleExtractor.fallback(filename: placement.filename, isFolder: placement.isFolder)
                return try insert(placement, db: db, title: finalTitle, description: description, project: project,
                                  tags: tags, from: from, handoff: request.handoff)
            } catch {
                placement.undo()
                throw error
            }
        }
    }

    private func isRegistered(filename: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM drops WHERE filename = ?)",
                          arguments: [filename]) ?? false
    }

    /// Validates the source and makes any copy. Needs no lock.
    private func stage(_ request: AddRequest, stagingDirectory: inout URL?) throws -> Staged {
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
            let staging = try self.makeStagingDirectory()
            stagingDirectory = staging
            let staged = staging.appendingPathComponent("content")
            try data.write(to: staged, options: .withoutOverwriting)
            return .copy(staged, isFolder: false, name: name)

        case .staged(let url, let isFolder):
            guard let rawName = request.name else { throw AgentDropError.invalid("a staged drop needs a name") }
            let name = try Validation.dropName(rawName)
            guard !request.move else { throw AgentDropError.invalid("--move can't be used with a staged drop") }
            let stagingRoot = folder.appendingPathComponent(".agentdrop/staging", isDirectory: true)
                .resolvingSymlinksInPath().path
            guard url.resolvingSymlinksInPath().path.hasPrefix(stagingRoot + "/") else {
                throw AgentDropError.invalid("a staged drop must live inside the store's staging directory")
            }
            return .copy(url, isFolder: isFolder, name: name)

        case .path(let rawSource):
            let source = rawSource.standardizedFileURL
            let isFolder = try entryKind(source)

            let root = folder.resolvingSymlinksInPath().path
            let resolvedSource = source.resolvingSymlinksInPath().path
            if resolvedSource == root || root.hasPrefix(resolvedSource + "/") {
                throw AgentDropError.invalid("Can't drop the drop folder itself or a folder that contains it")
            }
            let parent = source.deletingLastPathComponent().resolvingSymlinksInPath().path

            if parent == root {
                return .inPlace(source, isFolder: isFolder, rename: request.name)
            }
            if parent.hasPrefix(root + "/") {
                throw AgentDropError.invalid(
                    "\(source.path) is inside a subfolder of the drop folder; only top-level entries can be drops")
            }

            let name = try Validation.dropName(request.name ?? source.lastPathComponent)
            if request.move { return .move(source, isFolder: isFolder, name: name) }
            let staging = try self.makeStagingDirectory()
            stagingDirectory = staging
            let staged = staging.appendingPathComponent("content", isDirectory: isFolder)
            try fm.copyItem(at: source, to: staged)
            return .copy(staged, isFolder: isFolder, name: name)
        }
    }

    /// `false` for a regular file, `true` for a directory; anything else can't be dropped.
    private func entryKind(_ source: URL) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: source.path) // does not follow symlinks
        } catch {
            throw AgentDropError.notFound("No such file or directory: \(source.path)")
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular?: return false
        case .typeDirectory?: return true
        case .typeSymbolicLink?:
            throw AgentDropError.invalid("\(source.path) is a symlink; symlinks can't be dropped")
        default:
            throw AgentDropError.invalid("\(source.path) is not a regular file or directory")
        }
    }

    /// Puts the staged entry at its final top-level name. Runs inside the write lock.
    private func place(_ staged: Staged, db: Database) throws -> Placement {
        let fm = FileManager.default
        switch staged {
        case .copy(let content, let isFolder, let name):
            let final = try claimName(name, isFolder: isFolder, db: db) { try fm.moveItem(at: content, to: $0) }
            let placed = folder.appendingPathComponent(final)
            return Placement(filename: final, isFolder: isFolder, undo: { try? fm.removeItem(at: placed) })

        case .move(let source, let isFolder, let name):
            let final = try claimName(name, isFolder: isFolder, db: db) { try fm.moveItem(at: source, to: $0) }
            let placed = folder.appendingPathComponent(final)
            return Placement(filename: final, isFolder: isFolder, undo: { try? fm.moveItem(at: placed, to: source) })

        case .inPlace(let source, let isFolder, let rename):
            // Re-checked under the lock: the entry may have changed since staging.
            guard try entryKind(source) == isFolder else {
                throw AgentDropError.invalid("\(source.path) changed while it was being added; retry")
            }
            let current = try canonicalEntryName(for: source)
            if try isRegistered(filename: current, db: db) {
                throw AgentDropError.conflict("\(current) is already registered")
            }
            guard let requested = rename, requested != current else {
                return Placement(filename: try Validation.dropName(current), isFolder: isFolder, undo: {})
            }
            let name = try Validation.dropName(requested)
            let destination = folder.appendingPathComponent(name)
            let taken = try isRegistered(filename: name, db: db)
            if taken || fm.fileExists(atPath: destination.path) {
                throw AgentDropError.conflict("\(name) already exists in the drop folder")
            }
            try fm.moveItem(at: source, to: destination)
            let final = try canonicalEntryName(for: destination)
            return Placement(filename: final, isFolder: isFolder, undo: { try? fm.moveItem(at: destination, to: source) })
        }
    }

    /// A fresh `.agentdrop/staging/<uuid>/` directory inside the store folder.
    public func makeStagingDirectory() throws -> URL {
        let url = folder.appendingPathComponent(".agentdrop/staging/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes `.agentdrop/staging/<uuid>/` directories left by a crash mid-upload: those
    /// whose own date and every direct child's are older than `age`. A fresh one may
    /// belong to a `drop add` or upload in progress and is left alone.
    public func removeStaleStagingDirectories(olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        let root = folder.appendingPathComponent(".agentdrop/staging", isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
        }
        let cutoff = now.addingTimeInterval(-age)
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let children = (try? fm.contentsOfDirectory(at: entry,
                                                        includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = ([entry] + children).map(modified).max() ?? now
            if newest < cutoff { try? fm.removeItem(at: entry) }
        }
    }

    /// The entry's spelling as stored on disk, which can differ from the requested name
    /// when the filesystem accepts an alias (case or Unicode normalization). Records store
    /// this spelling, so `entryIsPresent` can match it exactly. Distinct hard-linked entries
    /// stay distinct.
    private func canonicalEntryName(for source: URL) throws -> String {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: folder.path)
        let requested = source.lastPathComponent
        if let exact = names.first(where: { $0.utf8.elementsEqual(requested.utf8) }) { return exact }
        let sourceAttributes = try fm.attributesOfItem(atPath: source.path)
        for name in names where name.compare(requested, options: [.caseInsensitive]) == .orderedSame {
            let attributes = try fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            if attributes[.systemNumber] as? NSNumber == sourceAttributes[.systemNumber] as? NSNumber,
               attributes[.systemFileNumber] as? NSNumber == sourceAttributes[.systemFileNumber] as? NSNumber {
                return name
            }
        }
        throw AgentDropError.notFound("No directory entry matches '\(requested)'")
    }

    /// Writes to the first free name (`plan.md`, `plan-2.md`, …). Losing a race to another
    /// writer surfaces as "file exists" and moves on to the next candidate.
    private func claimName(_ name: String, isFolder: Bool, db: Database, write: (URL) throws -> Void) throws -> String {
        for n in 1...1_000 {
            let candidate = n == 1 ? name : Validation.suffixed(name, n: n, isFolder: isFolder)
            let destination = folder.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            if try isRegistered(filename: candidate, db: db) { continue }
            do {
                try write(destination)
                return try canonicalEntryName(for: destination)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw AgentDropError.conflict("Couldn't find a free name for \(name)")
    }

    private func insert(_ placement: Placement, db: Database, title: String, description: String?, project: String?,
                        tags: [String], from: String, handoff: Bool) throws -> Drop {
        let now = self.now()
        do {
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
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw AgentDropError.conflict("\(placement.filename) is already registered")
        }
    }
}
