import AgentDropCore
import Foundation
import Hummingbird
import Logging

/// The local HTTP + SSE server (spec §5.2, §5.3): 127.0.0.1 only, bearer token, `Host` allowlist.
public final class HTTPServer: Sendable {
    public struct PortsExhausted: Error, Equatable {
        public let range: ClosedRange<Int>
    }

    public let port: Int
    public let token: String
    private let hub: EventHub
    private let task: Task<Void, Error>

    private init(port: Int, token: String, hub: EventHub, task: Task<Void, Error>) {
        self.port = port
        self.token = token
        self.hub = hub
        self.task = task
    }

    /// Binds the first free port in `portBase ..< portBase + attempts` (spec: the default
    /// port plus the next 9).
    public static func start(store: DropStore, hub: EventHub, token: String, portBase: Int,
                             attempts: Int) async throws -> HTTPServer {
        for port in portBase..<(portBase + attempts) {
            let router = HTTPAPI.router(store: store, hub: hub, token: token, port: port)
            if let task = await bind(router, port: port) {
                return HTTPServer(port: port, token: token, hub: hub, task: task)
            }
        }
        throw PortsExhausted(range: portBase...(portBase + attempts - 1))
    }

    /// Ends every open event stream first (a streaming response would otherwise keep
    /// shutdown waiting), then stops the server.
    public func stop() async {
        await hub.close()
        task.cancel()
        _ = try? await task.value
    }

    /// The running server's task, or nil if the port couldn't be bound. The first value
    /// on `outcome` decides: `true` once the server listens, `false` if `run()` ended first.
    private static func bind(_ router: Router<BasicRequestContext>, port: Int) async -> Task<Void, Error>? {
        let (outcome, continuation) = AsyncStream<Bool>.makeStream()
        var logger = Logger(label: "AgentDropServer")
        logger.logLevel = .warning
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: nil, reuseAddress: false),
            onServerRunning: { _ in continuation.yield(true) },
            logger: logger)
        let task = Task {
            defer {
                continuation.yield(false)
                continuation.finish()
            }
            try await app.run()
        }
        var iterator = outcome.makeAsyncIterator()
        return await iterator.next() == true ? task : nil
    }
}
