import AgentDropCore
import Foundation

/// The detail pane's actions (spec §6). Each calls the same `AgentDropCore` operation as
/// the CLI, through the app's store, then reloads. Failures become `alert`, except the
/// two forms, which return their error so the sheet can stay open and show it.
extension LibraryModel {
    public func release(_ id: String) async { await perform { _ = try $0.release(id) } }

    public func markDone(_ id: String, note: String?) async {
        let note = note.map(MetadataForm.trim).flatMap { $0.isEmpty ? nil : $0 }
        await perform { _ = try $0.done(id, note: note) }
    }

    public func reopen(_ id: String) async { await perform { _ = try $0.reopen(id) } }

    /// Archives (or unarchives) each drop; the list's context menu passes several.
    public func setArchived(_ ids: [String], _ archived: Bool) async {
        await perform { store in
            for id in ids { _ = try store.setArchived(id, archived) }
        }
    }

    /// Spec §3.2 "Remove record", offered only for missing drops.
    public func removeRecord(_ id: String) async { await perform { try $0.removeRecord(id) } }

    /// nil on success (or when nothing changed), else the message to show in the sheet.
    public func edit(_ id: String, _ form: MetadataForm) async -> String? {
        guard let drop = drop(id) else { return "This drop no longer exists." }
        do {
            guard let request = try form.request(for: drop) else { return nil }
            try await write { _ = try $0.edit(id, request) }
            return nil
        } catch {
            return Self.message(error)
        }
    }

    /// Registers the entry in place and selects the new drop. nil on success.
    public func register(_ entry: UnregisteredEntry, _ form: RegisterForm) async -> String? {
        guard let store else { return "Agent Drop isn't serving a folder right now." }
        do {
            let request = try form.request(for: entry, in: store.folder)
            let drop = try await StoreQueue.run { try store.add(request) }
            registeredInApp.insert(drop.id)
            await reload()
            selection = [.drop(drop.id)]
            return nil
        } catch {
            return Self.message(error)
        }
    }

    private func perform(_ body: @escaping @Sendable (DropStore) throws -> Void) async {
        do {
            try await write(body)
        } catch {
            alert = Self.message(error)
        }
    }

    private func write(_ body: @escaping @Sendable (DropStore) throws -> Void) async throws {
        guard let store else { throw AgentDropError.invalid("Agent Drop isn't serving a folder right now.") }
        do {
            try await StoreQueue.run { try body(store) }
        } catch {
            await reload() // e.g. a conflict: show the state that caused it
            throw error
        }
        await reload()
    }
}
