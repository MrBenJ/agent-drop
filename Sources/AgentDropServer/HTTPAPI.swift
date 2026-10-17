import AgentDropCore
import Foundation
import Hummingbird
import HummingbirdCore

/// Routes and request checks for the local server (spec §5.3).
enum HTTPAPI {
    static func router(store: DropStore, hub: EventHub, token: String, port: Int) -> Router<BasicRequestContext> {
        let router = Router()
        // Outermost first: errors become JSON, then Host and token are checked, for every
        // request including unknown routes.
        router.add(middleware: ErrorMiddleware<BasicRequestContext>())
        router.add(middleware: AccessMiddleware(token: token, port: port))

        router.get("/drops") { request, _ -> Response in
            let filter = try listFilter(request)
            return json(try store.list(filter).map(store.json))
        }

        router.get("/drops/{id}") { _, context -> Response in
            let drop = try store.resolve(try pathID(context))
            await hub.poke() // resolve may have recorded a missing-file event
            return json(store.json(drop))
        }

        router.get("/drops/{id}/content") { _, context -> Response in
            let drop = try store.resolve(try pathID(context))
            await hub.poke()
            guard !drop.missing else { throw AgentDropError.notFound("The file for \(drop.id) is missing") }
            let url = store.path(of: drop)
            if drop.isFolder { return json(try FolderListing(id: drop.id, folder: url)) }
            return Response(status: .ok, headers: [.contentType: contentType(for: url)],
                            body: .init(byteBuffer: ByteBuffer(bytes: try readRegularFile(url, id: drop.id))))
        }

        router.get("/events") { request, _ -> Response in
            var cursor: EventCursor?
            if let raw = request.headers.first(where: { $0.name.canonicalName == "last-event-id" })?.value {
                guard let parsed = EventCursor(lastEventID: raw) else {
                    throw APIError(.badRequest, "Last-Event-ID must look like <storeId>:<seq>")
                }
                cursor = parsed
            }
            let filter = try eventFilter(request, store: store, resumingWithin: cursor?.storeID == hub.storeID)
            let frames = try await hub.subscribe(filter, resumeFrom: cursor)
            return Response(
                status: .ok,
                headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                body: ResponseBody { writer in
                    try await writer.write(ByteBuffer(string: SSE.comment("connected")))
                    for await frame in frames {
                        try await writer.write(ByteBuffer(string: encode(frame)))
                    }
                    try await writer.finish(nil)
                })
        }
        return router
    }

    static func encode(_ frame: EventHub.Frame) -> String {
        switch frame {
        case .event(let message):
            SSE.frame(id: message.cursor.id, event: message.type, data: message.jsonString())
        case .cursor(let cursor):
            "id: \(cursor.id)\n\n"
        case .reset(let cursor):
            SSE.frame(id: cursor.id, event: "reset", data: SSE.resetData)
        case .heartbeat:
            SSE.comment("keepalive")
        }
    }

    // MARK: - Query parsing

    /// `drop list` filters as query parameters, with the same defaults and rules.
    static func listFilter(_ request: Request) throws -> ListFilter {
        let query = request.uri.queryParameters
        try rejectUnknown(query, allowed: ["project", "tag", "from", "from-under", "handoffs", "status", "unread",
                                           "limit", "all"])
        var filter = ListFilter()
        filter.project = query["project"].map(String.init)
        filter.tags = query[values: "tag"].map(String.init)
        filter.from = query["from"].map(String.init)
        filter.fromUnder = query["from-under"].map(String.init)
        filter.handoffsOnly = try flag(query, "handoffs")
        filter.unreadOnly = try flag(query, "unread")
        filter.includeArchived = try flag(query, "all")
        if let raw = query["status"] {
            guard let status = HandoffStatus(rawValue: String(raw)) else {
                throw APIError(.badRequest, "status must be open, claimed, or done")
            }
            filter.status = status
        }
        if let raw = query["limit"] {
            guard let limit = Int(raw), limit >= 1 else { throw APIError(.badRequest, "limit must be at least 1") }
            filter.limit = limit
        }
        return filter
    }

    /// `resumingWithin`: the client sent a cursor from this store. Then a well-formed id
    /// with no record (removed while the client was away) is still accepted, so the
    /// replay can deliver its `removed` event.
    static func eventFilter(_ request: Request, store: DropStore, resumingWithin: Bool = false) throws -> EventFilter {
        let query = request.uri.queryParameters
        try rejectUnknown(query, allowed: ["drop", "inbox", "project"])
        let inbox = try flag(query, "inbox")
        let project = query["project"].map(String.init)
        if let ref = query["drop"] {
            guard !inbox else { throw APIError(.badRequest, "use either drop or inbox, not both") }
            guard project == nil else { throw APIError(.badRequest, "project only applies to inbox") }
            do {
                return .drop(try store.resolve(String(ref)).id)
            } catch let error as AgentDropError where error.exitCode == 2 && resumingWithin
                && DropID.isWellFormed(String(ref)) {
                return .drop(String(ref))
            }
        }
        if inbox { return .inbox(project: project) }
        guard project == nil else { throw APIError(.badRequest, "project only applies to inbox") }
        return .all
    }

    /// A typo like `projct` must not silently widen the result.
    private static func rejectUnknown(_ query: FlatDictionary<Substring, Substring>, allowed: Set<String>) throws {
        for (key, _) in query where !allowed.contains(String(key)) {
            throw APIError(.badRequest, "unknown query parameter '\(key)'")
        }
    }

    /// Present with no value or `true` → true; `false` or absent → false.
    private static func flag(_ query: FlatDictionary<Substring, Substring>, _ name: String) throws -> Bool {
        guard let value = query[Substring(name)] else { return false }
        switch value {
        case "", "true": return true
        case "false": return false
        default: throw APIError(.badRequest, "\(name) must be true or false")
        }
    }

    /// Path parameters arrive percent-encoded (`my%20plan.md`).
    private static func pathID(_ context: BasicRequestContext) throws -> String {
        guard let raw = context.parameters.get("id"), let id = raw.removingPercentEncoding else {
            throw APIError(.badRequest, "invalid drop reference")
        }
        return id
    }

    /// Reads a drop's file without following a link: the entry could be swapped for a
    /// symlink after `resolve` checked it.
    private static func readRegularFile(_ url: URL, id: String) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AgentDropError.notFound("The file for \(id) is missing") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AgentDropError.notFound("The file for \(id) is missing")
        }
        return try handle.readToEnd() ?? Data()
    }

    // MARK: - Responses

    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": "text/markdown; charset=utf-8"
        case "txt", "log": "text/plain; charset=utf-8"
        case "json": "application/json"
        case "html", "htm": "text/html; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}

/// `{"error": "<message>", "status": <HTTP status>}` (spec §5.3).
struct APIError: Error {
    let status: HTTPResponse.Status
    let message: String

    init(_ status: HTTPResponse.Status, _ message: String) {
        self.status = status
        self.message = message
    }

    var response: Response {
        struct Body: Encodable {
            let error: String
            let status: Int
        }
        return HTTPAPI.json(Body(error: message, status: status.code), status: status)
    }
}

struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    /// When set (the tailnet listener), every 500 says only this, so raw error text
    /// (which can name paths on this Mac) never reaches another machine.
    var internalErrorMessage: String?

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let error: APIError
        do {
            return try await next(request, context)
        } catch let apiError as APIError {
            error = apiError
        } catch let storeError as AgentDropError {
            switch storeError {
            case .notFound(let m): error = APIError(.notFound, m)
            case .invalid(let m) where m == "store busy, retry": error = APIError(.serviceUnavailable, m)
            case .invalid(let m): error = APIError(.badRequest, m)
            case .conflict(let m): error = APIError(.conflict, m)
            }
        } catch let httpError as HTTPError {
            error = APIError(httpError.status, httpError.body ?? httpError.status.reasonPhrase)
        } catch let other {
            error = APIError(.internalServerError, "\(other)")
        }
        if let internalErrorMessage, error.status == .internalServerError {
            return APIError(.internalServerError, internalErrorMessage).response
        }
        return error.response
    }
}

/// Spec §5.2: `Host` must be `127.0.0.1:<port>` or `localhost:<port>` (403), and every
/// request needs `Authorization: Bearer <token>` (401). A web page can reach localhost,
/// but it can't send a matching `Host` through a browser or know the token.
struct AccessMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let token: String
    let port: Int

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let allowed = ["127.0.0.1:\(port)", "localhost:\(port)"]
        // The first Host header becomes `authority`; any further one stays a header field.
        let extraHost = request.headers.contains { $0.name.canonicalName == "host" }
        guard let host = request.head.authority, allowed.contains(host.lowercased()), !extraHost else {
            throw APIError(.forbidden, "Host not allowed")
        }
        guard Secrets.constantTimeEquals(request.headers[.authorization] ?? "", "Bearer \(token)") else {
            throw APIError(.unauthorized, "missing or invalid token")
        }
        return try await next(request, context)
    }
}

/// `GET /drops/:id/content` for a folder drop. Links are listed with their target text,
/// never followed (spec §3).
public struct FolderListing: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var type: String
        public var size: Int64?
        public var target: String?
    }

    public var id: String
    public var entries: [Entry]

    init(id: String, folder: URL) throws {
        self.id = id
        var entries: [Entry] = []
        try Self.walk(folder, prefix: "", into: &entries)
        self.entries = entries
    }

    private static func walk(_ directory: URL, prefix: String, into entries: inout [Entry]) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
            let url = directory.appendingPathComponent(name)
            let path = prefix + name
            let attributes = try fm.attributesOfItem(atPath: url.path) // does not follow links
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?:
                entries.append(Entry(path: path, type: "directory", size: nil, target: nil))
                try walk(url, prefix: path + "/", into: &entries)
            case .typeRegular?:
                entries.append(Entry(path: path, type: "file", size: (attributes[.size] as? NSNumber)?.int64Value,
                                     target: nil))
            case .typeSymbolicLink?:
                entries.append(Entry(path: path, type: "symlink", size: nil,
                                     target: try? fm.destinationOfSymbolicLink(atPath: url.path)))
            default:
                entries.append(Entry(path: path, type: "other", size: nil, target: nil))
            }
        }
    }
}
