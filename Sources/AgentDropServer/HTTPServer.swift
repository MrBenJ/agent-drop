import AgentDropCore
import Foundation
import Hummingbird
import Logging
import NIOCore
import ServiceLifecycle

/// The local HTTP + SSE server (spec §5.2, §5.3): 127.0.0.1 only, bearer token, `Host` allowlist.
public final class HTTPServer: Sendable {
    public struct PortsExhausted: Error, Equatable {
        public let range: ClosedRange<Int>
    }

    public let port: Int
    public let token: String
    private let hub: EventHub
    private let running: BoundServer

    private init(port: Int, token: String, hub: EventHub, running: BoundServer) {
        self.port = port
        self.token = token
        self.hub = hub
        self.running = running
    }

    /// Binds the first free port in `portBase ..< portBase + attempts` (spec: the default
    /// port plus the next 9).
    public static func start(store: DropStore, hub: EventHub, token: String, portBase: Int,
                             attempts: Int) async throws -> HTTPServer {
        for port in portBase..<(portBase + attempts) {
            let router = HTTPAPI.router(store: store, hub: hub, token: token, port: port)
            if let running = await bindServer(router, host: "127.0.0.1", port: port) {
                return HTTPServer(port: port, token: token, hub: hub, running: running)
            }
        }
        throw PortsExhausted(range: portBase...(portBase + attempts - 1))
    }

    /// Ends every open event stream first (a streaming response would otherwise keep
    /// shutdown waiting), then shuts the server down (see `BoundServer.stop()`).
    public func stop() async {
        await hub.close()
        await running.stop()
    }

}

/// A bound, running Hummingbird server.
struct BoundServer: Sendable {
    let group: ServiceGroup
    let task: Task<Void, Error>

    /// Shuts the server down gracefully. If that takes more than 2 s (a stuck
    /// connection, e.g. a sender holding a partial body), the server task is cancelled.
    /// The timer is unstructured on purpose: a task group would have to join the child
    /// awaiting `task.value` before it could cancel `task`, so it would never get there.
    func stop() async {
        await group.triggerGracefulShutdown()
        let task = task
        let timer = Task {
            try await Task.sleep(for: .seconds(2))
            task.cancel()
        }
        _ = try? await task.value
        timer.cancel()
    }
}

/// The running server, or nil if the port couldn't be bound. The first value on
/// `outcome` decides: `true` once the server listens, `false` if `run()` ended first.
/// `idleTimeout` closes a connection that reads nothing for that long, including in the
/// middle of a request body (Hummingbird's HTTP/1 idle handler); nil never does.
func bindServer<Context: RequestContext>(_ router: Router<Context>, host: String, port: Int,
                                         reuseAddress: Bool = false,
                                         idleTimeout: Duration? = nil) async -> BoundServer?
where Context.Source == ApplicationRequestContextSource {
    let (outcome, continuation) = AsyncStream<Bool>.makeStream()
    var logger = Logger(label: "AgentDropServer")
    logger.logLevel = .warning
    let app = Application(
        router: router,
        server: .http1(configuration: .init(idleTimeout: idleTimeout.map { TimeAmount($0) })),
        configuration: .init(address: .hostname(host, port: port), serverName: nil, reuseAddress: reuseAddress),
        onServerRunning: { _ in continuation.yield(true) },
        logger: logger)
    // Our own group (no signal handling), so stop() can shut down gracefully.
    let group = ServiceGroup(configuration: .init(services: [app], logger: logger))
    let task = Task {
        defer {
            continuation.yield(false)
            continuation.finish()
        }
        try await group.run()
    }
    var iterator = outcome.makeAsyncIterator()
    return await iterator.next() == true ? BoundServer(group: group, task: task) : nil
}
