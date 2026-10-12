import Foundation

/// A small client for the local server. Used by `drop watch` and the tests.
public struct AgentDropClient: Sendable {
    public struct HTTPFailure: Error, Equatable {
        public let status: Int
        public let message: String
    }

    public let port: Int
    public let token: String

    public init(port: Int, token: String) {
        self.port = port
        self.token = token
    }

    /// `/drops/<ref>` with `ref` percent-encoded as one path segment.
    public static func dropPath(_ ref: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        return "/drops/" + (ref.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref)
    }

    public func request(_ path: String, query: [URLQueryItem] = [], lastEventID: String? = nil) -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // An idle timeout, not a total one: heartbeats keep event streams under it.
        request.timeoutInterval = 60
        return request
    }

    /// Body and HTTP status.
    public func get(_ path: String, query: [URLQueryItem] = []) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request(path, query: query))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Opens `GET /events`. Throws `HTTPFailure` for a non-200 answer. The stream ends
    /// when the server closes the connection.
    /// `onCursor` receives every new last-event id, including those of id-only frames.
    public func events(query: [URLQueryItem] = [], lastEventID: String? = nil,
                       onCursor: @escaping @Sendable (String) -> Void = { _ in }) async throws
        -> AsyncThrowingStream<SSEEvent, Error>
    {
        let (bytes, response) = try await URLSession.shared.bytes(
            for: request("/events", query: query, lastEventID: lastEventID))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            let message = (try? JSONDecoder().decode([String: JSONValue].self, from: body))?["error"]?.stringValue
            throw HTTPFailure(status: status, message: message ?? String(decoding: body, as: UTF8.self))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    var cursor = lastEventID
                    for try await byte in bytes {
                        let event = parser.feed(byte: byte)
                        if let id = parser.lastEventID, id != cursor {
                            cursor = id
                            onCursor(id)
                        }
                        if let event { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
