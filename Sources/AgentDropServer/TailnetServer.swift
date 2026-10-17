import AgentDropCore
import Foundation
import Hummingbird
import HummingbirdCore
import NIOCore

/// The receiving listener for drops sent from other tailnet machines: bound only to this
/// Mac's tailnet address, it accepts `POST /drops` and `POST /ping` and nothing else. No
/// route reads the store, so a sender's key can add drops but never list or fetch them.
public final class TailnetServer: Sendable {
    public struct PortInUse: Error, Equatable {
        public let port: Int
    }

    public struct Limits: Sendable {
        /// Per-drop cap on the uploaded bytes (and on a folder's unpacked file bytes).
        public var maxBytes: Int64
        public var maxInFlight = 2
        /// Free space the volume must keep after the upload.
        public var minFreeBytes: Int64 = 1 << 30
        /// A connection that sends nothing for this long, even mid-body, is closed: the
        /// upload fails and its slot, reservation and staging directory are freed.
        public var bodyIdleTimeout: Duration = .seconds(30)

        public init(maxBytes: Int64) {
            self.maxBytes = maxBytes
        }
    }

    public let port: Int
    private let running: BoundServer

    private init(port: Int, running: BoundServer) {
        self.port = port
        self.running = running
    }

    /// Binds `bindHost:port` exactly; never tries another port. `key` is read on every
    /// request, so a regenerated key applies at once (nil: every request is refused).
    public static func start(store: DropStore, bindHost: String, port: Int, identity: TailnetIdentity, limits: Limits,
                             key: @escaping @Sendable () -> String?,
                             peerAllowed: @escaping @Sendable (String) -> Bool = TailnetAccess.isTailnetPeer,
                             freeBytes: @escaping @Sendable (URL) -> Int64? = TailnetServer.volumeFreeBytes)
        async throws -> TailnetServer {
        let receiver = TailnetReceiver(store: store, limits: limits, freeBytes: freeBytes,
                                       slots: UploadSlots(limit: limits.maxInFlight))
        let router = Router(context: TailnetRequestContext.self)
        // Outermost first, for every request including unknown routes: errors become
        // JSON, then the peer address, Host, and key are checked.
        router.add(middleware: ErrorMiddleware<TailnetRequestContext>(
            internalErrorMessage: "Internal error on the receiving Mac"))
        router.add(middleware: TailnetAccessMiddleware(allowedHosts: identity.allowedHosts(port: port),
                                                       key: key, peerAllowed: peerAllowed))
        router.post("/ping") { _, _ in Response(status: .noContent) }
        router.post("/drops") { request, _ in try await receiver.receive(request) }
        // Anything else (an unknown path, or a known one with another method) reaches
        // Hummingbird's not-found responder, which ErrorMiddleware turns into 404 JSON.
        guard let running = await bindServer(router, host: bindHost, port: port, reuseAddress: true,
                                             idleTimeout: limits.bodyIdleTimeout) else {
            throw PortInUse(port: port)
        }
        return TailnetServer(port: port, running: running)
    }

    public func stop() async {
        await running.stop()
    }

    /// Space available for important usage on the volume holding `url`, or nil if unknown.
    public static func volumeFreeBytes(_ url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

/// Carries the connection's peer address for the access check.
struct TailnetRequestContext: RequestContext {
    typealias Source = ApplicationRequestContextSource
    var coreContext: CoreRequestContextStorage
    /// The remote IP, nil if the channel has none (e.g. a Unix socket).
    let peer: String?

    init(source: Source) {
        coreContext = .init(source: source)
        peer = source.channel.remoteAddress?.ipAddress
    }
}

/// Peer address (403), `Host` (403, with `AccessMiddleware`'s duplicate-Host rule), then
/// `Authorization: Bearer <key>` (401).
struct TailnetAccessMiddleware: RouterMiddleware {
    typealias Context = TailnetRequestContext
    let allowedHosts: Set<String>
    let key: @Sendable () -> String?
    let peerAllowed: @Sendable (String) -> Bool

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let peer = context.peer, peerAllowed(peer) else {
            throw APIError(.forbidden, "Not a tailnet address")
        }
        // The first Host header becomes `authority`; any further one stays a header field.
        let extraHost = request.headers.contains { $0.name.canonicalName == "host" }
        guard let host = request.head.authority, allowedHosts.contains(host.lowercased()), !extraHost else {
            throw APIError(.forbidden, "Host not allowed")
        }
        guard let key = key(),
              Secrets.constantTimeEquals(request.headers[.authorization] ?? "", "Bearer \(key)") else {
            throw APIError(.unauthorized, "missing or invalid key")
        }
        return try await next(request, context)
    }
}

/// Counts uploads in progress and the disk space they've reserved. A lock rather than an
/// actor, so `release(reserved:)` can run from a `defer` (which can't `await`).
final class UploadSlots: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var count = 0
    private var reservedBytes: Int64 = 0

    init(limit: Int) {
        self.limit = limit
    }

    func claim() -> Bool {
        lock.withLock {
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    /// Reserves `bytes` if `fits` accepts the total reserved with them included. A total
    /// that overflows Int64 doesn't fit.
    func reserve(_ bytes: Int64, if fits: (Int64) -> Bool) -> Bool {
        lock.withLock {
            let (total, overflow) = reservedBytes.addingReportingOverflow(bytes)
            guard !overflow, fits(total) else { return false }
            reservedBytes = total
            return true
        }
    }

    /// Frees a claimed slot and the bytes it reserved (0 if it reserved none).
    func release(reserved bytes: Int64) {
        lock.withLock {
            count -= 1
            reservedBytes = reservedBytes.subtractingReportingOverflow(bytes).partialValue
        }
    }
}

/// `POST /drops`: stream the body into a staging directory, then register it as a drop.
struct TailnetReceiver: Sendable {
    enum Kind: String {
        case file, folder
    }

    /// The query parameters of `POST /drops`.
    struct Upload {
        var kind: Kind
        var name: String
        var from: String
        var title: String?
        var desc: String?
        var project: String?
        var tags: [String]
        var handoff: Bool

        init(_ query: FlatDictionary<Substring, Substring>) throws {
            let allowed: Set<String> = ["kind", "name", "from", "title", "desc", "project", "tag", "handoff"]
            for (key, _) in query where !allowed.contains(String(key)) {
                throw APIError(.badRequest, "unknown query parameter '\(key)'")
            }
            func required(_ name: String) throws -> String {
                guard let value = query[Substring(name)] else {
                    throw APIError(.badRequest, "missing query parameter '\(name)'")
                }
                return String(value)
            }
            guard let kind = Kind(rawValue: try required("kind")) else {
                throw APIError(.badRequest, "kind must be file or folder")
            }
            self.kind = kind
            name = try required("name")
            from = try required("from")
            title = query["title"].map(String.init)
            desc = query["desc"].map(String.init)
            project = query["project"].map(String.init)
            tags = query[values: "tag"].map(String.init)
            switch query["handoff"] {
            case nil, "false": handoff = false
            case "true": handoff = true
            default: throw APIError(.badRequest, "handoff must be true or false")
            }
        }
    }

    let store: DropStore
    let limits: TailnetServer.Limits
    let freeBytes: @Sendable (URL) -> Int64?
    let slots: UploadSlots

    private var tooLarge: APIError {
        APIError(.contentTooLarge, "Drop is larger than the \(limits.maxBytes / 1_048_576) MB limit")
    }

    func receive(_ request: Request) async throws -> Response {
        let upload = try Upload(request.uri.queryParameters)
        guard slots.claim() else {
            throw APIError(.serviceUnavailable, "Agent Drop is busy receiving; retry shortly")
        }
        var reserved: Int64 = 0
        defer { slots.release(reserved: reserved) }

        let declared = request.headers[.contentLength].flatMap { Int64($0) }
        if let declared, declared > limits.maxBytes { throw tooLarge }
        // Without a length the body may grow to the cap. A folder holds the pack and its
        // unpacked tree at once: count it twice. Uploads in flight have reserved theirs.
        // An overflowing product can't fit: refuse it (507) rather than trap.
        let (product, productOverflow) = (declared ?? limits.maxBytes)
            .multipliedReportingOverflow(by: upload.kind == .folder ? 2 : 1)
        let needed = productOverflow ? Int64.max : product
        let free = freeBytes(store.folder)
        let minFree = limits.minFreeBytes
        guard !productOverflow, slots.reserve(needed, if: { total in
            free.map { value in
                let (remaining, overflow) = value.subtractingReportingOverflow(total)
                return !overflow && remaining >= minFree
            } ?? true
        }) else {
            throw APIError(HTTPResponse.Status(code: 507, reasonPhrase: "Insufficient Storage"),
                           "Not enough free disk space on the receiving Mac")
        }
        reserved = needed

        let staging = try store.makeStagingDirectory()
        // Runs on every exit, including a dropped connection (the body stream throws) and
        // cancellation.
        defer { try? FileManager.default.removeItem(at: staging) }
        let uploaded = staging.appendingPathComponent("upload")
        let content = staging.appendingPathComponent("content")
        try await write(request.body, to: uploaded)

        switch upload.kind {
        case .file:
            try FileManager.default.moveItem(at: uploaded, to: content)
        case .folder:
            try await unpack(uploaded, into: content)
            try? FileManager.default.removeItem(at: uploaded)
        }
        let drop = try store.add(AddRequest(
            source: .staged(content, isFolder: upload.kind == .folder), name: upload.name, title: upload.title,
            description: upload.desc, project: upload.project, tags: upload.tags, from: upload.from,
            handoff: upload.handoff))
        return HTTPAPI.json(store.json(drop), status: .created)
    }

    /// Streams the body to `file`, refusing (413) as soon as it passes `maxBytes`.
    private func write(_ body: RequestBody, to file: URL) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw APIError(.internalServerError, "Can't create the staging file")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var received: Int64 = 0
        for try await buffer in body {
            received += Int64(buffer.readableBytes)
            if received > limits.maxBytes { throw tooLarge }
            try buffer.withUnsafeReadableBytes { try handle.write(contentsOf: $0) }
        }
    }

    /// Unpacks on a GCD thread: a large folder would otherwise block a Swift concurrency
    /// thread for the whole unpack. Any failure other than size is the sender's fault
    /// (400), never a 500.
    private func unpack(_ pack: URL, into destination: URL) async throws {
        let maxBytes = limits.maxBytes
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Result { try DropPack.unpack(pack, into: destination, maxBytes: maxBytes) })
            }
        }
        do {
            try result.get()
        } catch DropPack.Failure.tooLarge {
            throw tooLarge
        } catch DropPack.Failure.malformed(let reason) {
            throw APIError(.badRequest, "invalid folder upload: \(reason)")
        } catch {
            throw APIError(.badRequest, "invalid folder upload: \(error.localizedDescription)")
        }
    }
}
