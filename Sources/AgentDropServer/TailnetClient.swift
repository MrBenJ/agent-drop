import AgentDropCore
import Foundation

/// The sending side of a tailnet drop: POSTs to another Mac's `TailnetServer`.
/// Every failure is an `AgentDropError`, worded for the person running the CLI.
public struct TailnetClient: Sendable {
    public struct Remote: Sendable, Equatable, Codable {
        public var url: URL
        public var key: String

        public init(url: URL, key: String) {
            self.url = url
            self.key = key
        }
    }

    public enum Payload: Sendable {
        case file(URL), folder(URL), data(Data)
    }

    public struct Metadata: Sendable {
        public var name: String
        public var from: String
        public var title: String?
        public var desc: String?
        public var project: String?
        public var tags: [String]
        public var handoff: Bool

        public init(name: String, from: String, title: String? = nil, desc: String? = nil, project: String? = nil,
                    tags: [String] = [], handoff: Bool = false) {
            self.name = name
            self.from = from
            self.title = title
            self.desc = desc
            self.project = project
            self.tags = tags
            self.handoff = handoff
        }
    }

    static let timeout: TimeInterval = 300

    private let remoteName: String
    private let remote: Remote
    private let session: URLSession

    public init(remoteName: String, remote: Remote, session: URLSession = .shared) {
        self.remoteName = remoteName
        self.remote = remote
        self.session = session
    }

    /// Uploads the payload and returns the receiver's 201 JSON body.
    public func send(_ payload: Payload, _ metadata: Metadata) async throws -> Data {
        var request = try makeRequest(path: "drops", query: Self.query(payload, metadata))
        request.timeoutInterval = Self.timeout
        switch payload {
        case .file(let file):
            return try await perform { try await session.upload(for: request, fromFile: file) }
        case .folder(let folder):
            let pack = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentdrop-\(UUID().uuidString).adpk")
            defer { try? FileManager.default.removeItem(at: pack) }
            try DropPack.write(folder: folder, to: pack)
            return try await perform { try await session.upload(for: request, fromFile: pack) }
        case .data(let data):
            return try await perform { try await session.upload(for: request, from: data) }
        }
    }

    /// Checks that the remote is reachable and accepts the key.
    public func ping() async throws {
        var request = try makeRequest(path: "ping", query: [])
        request.timeoutInterval = 15
        _ = try await perform { try await session.data(for: request) }
    }

    // MARK: - Request

    private static func query(_ payload: Payload, _ m: Metadata) -> [(String, String)] {
        var items = [("kind", { if case .folder = payload { "folder" } else { "file" } }()),
                     ("name", m.name), ("from", m.from)]
        if let title = m.title { items.append(("title", title)) }
        if let desc = m.desc { items.append(("desc", desc)) }
        if let project = m.project { items.append(("project", project)) }
        items += m.tags.map { ("tag", $0) }
        if m.handoff { items.append(("handoff", "true")) }
        return items
    }

    /// Unreserved characters only. `URLComponents.queryItems` leaves `+` (and `&`, `=`) as
    /// they are in a value, and servers commonly decode `+` as a space.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private func makeRequest(path: String, query: [(String, String)]) throws -> URLRequest {
        guard var components = URLComponents(url: remote.url, resolvingAgainstBaseURL: false) else {
            throw AgentDropError.invalid("'\(remoteName)' has an invalid URL: \(remote.url.absoluteString)")
        }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/" + path
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }
                .joined(separator: "&")
        }
        guard let url = components.url else {
            throw AgentDropError.invalid("'\(remoteName)' has an invalid URL: \(remote.url.absoluteString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(remote.key)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Response

    private static let unreachableCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .dnsLookupFailed,
    ]

    private func perform(_ call: () async throws -> (Data, URLResponse)) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await call()
        } catch let error as URLError where Self.unreachableCodes.contains(error.code) {
            throw AgentDropError.invalid(
                "Can't reach '\(remoteName)' (\(remote.url.absoluteString)). Is that Mac awake, on Tailscale, with Agent Drop running and Tailnet turned on?")
        } catch let error as URLError {
            throw AgentDropError.invalid("Sending to '\(remoteName)' failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AgentDropError.invalid("'\(remoteName)' sent a response that isn't HTTP.")
        }
        if (200..<300).contains(http.statusCode) { return data }
        let message = Self.serverMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        switch http.statusCode {
        case 401:
            throw AgentDropError.invalid(
                "The key for '\(remoteName)' was rejected. It may have been regenerated: run `drop remote add \(remoteName) --url \(remote.url.absoluteString) --key <new key>` again.")
        case 413: throw AgentDropError.invalid(message)
        case 404: throw AgentDropError.notFound(message)
        default: throw AgentDropError.invalid("'\(remoteName)' answered \(http.statusCode): \(message)")
        }
    }

    private static func serverMessage(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }
}
