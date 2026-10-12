import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer

/// What the app relies on from the service: change notifications and
/// reconciliation on start.
struct ServiceAppHookTests {
    func service(_ f: ServiceFixture, onChange: @escaping @Sendable () -> Void) -> AgentDropService {
        var options = AgentDropService.Options()
        options.portBase = randomPortBase()
        options.debounce = .milliseconds(50)
        options.onChange = onChange
        return AgentDropService(config: f.config, options: options)
    }

    @Test func onChangeFiresForInProcessWritesCLIWritesAndNewEntries() async throws {
        let f = try ServiceFixture()
        let count = Locked(0)
        let service = service(f) { count.withLock { $0 += 1 } }
        try await service.start()
        defer { Task { await service.stop() } }
        let store = try #require(await service.store)

        func expectChange(_ change: () throws -> Void) async throws {
            let seen = count.value
            try change()
            #expect(await eventually { count.value > seen })
        }
        try await expectChange { _ = try addFile(store, "a.md", in: f.dir.url) }
        try await expectChange { _ = try addFile(try f.cliStore(), "b.md", in: f.dir.url) }
        try await expectChange { try Data("x".utf8).write(to: f.folder.appendingPathComponent("loose.txt")) }
    }

    @Test func startReconcilesMissingDrops() async throws {
        let f = try ServiceFixture()
        let cli = try f.cliStore()
        let drop = try addFile(cli, "gone.md", in: f.dir.url)
        try FileManager.default.removeItem(at: cli.path(of: drop))

        let service = service(f) {}
        try await service.start()
        defer { Task { await service.stop() } }
        let store = try #require(await service.store)
        let row = try #require(try store.list({ var l = ListFilter(); l.includeArchived = true; return l }()).first)
        #expect(row.missing)
        #expect(try store.events().last?.type == .missing)
    }
}
