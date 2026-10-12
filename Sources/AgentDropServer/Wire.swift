import AgentDropCore
import Foundation

/// Any JSON value. Used to embed an event's stored `data` object in a message.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            if v == v.rounded(), abs(v) < 1e15 { try c.encode(Int64(v)) } else { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// The `data:` payload of every event frame (spec §5.3).
public struct EventMessage: Codable, Equatable, Sendable {
    public var storeId: String
    public var seq: Int64
    public var type: String
    public var dropId: String
    public var at: String
    public var data: JSONValue

    public init(storeID: String, event: StoredEvent) {
        storeId = storeID
        seq = event.seq
        type = event.type.rawValue
        dropId = event.dropID
        at = event.at.iso
        data = (try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8))) ?? .object([:])
    }

    public var cursor: EventCursor { EventCursor(storeID: storeId, seq: seq) }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}

/// `Last-Event-ID` / SSE `id:` value: `<storeId>:<seq>` (spec §5.3).
public struct EventCursor: Equatable, Sendable {
    public var storeID: String
    public var seq: Int64

    public init(storeID: String, seq: Int64) {
        self.storeID = storeID
        self.seq = seq
    }

    public init?(lastEventID: String) {
        guard let colon = lastEventID.lastIndex(of: ":") else { return nil }
        let store = String(lastEventID[..<colon])
        let digits = lastEventID[lastEventID.index(after: colon)...]
        guard !store.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let seq = Int64(digits) else { return nil }
        self.init(storeID: store, seq: seq)
    }

    public var id: String { "\(storeID):\(seq)" }
}

/// Which events a stream delivers (spec §5.3 `GET /events`).
public enum EventFilter: Equatable, Sendable {
    case all
    case drop(String)
    /// Arrivals only: events after which the drop is in the Inbox (scoped to `project`
    /// when given) and before which it was not.
    case inbox(project: String?)

    public func matches(_ event: StoredEvent) -> Bool {
        switch self {
        case .all:
            return true
        case .drop(let id):
            return event.dropID == id
        case .inbox(let project):
            let inScopeAfter = event.inboxAfter && (project == nil || event.projectAfter == project)
            let inScopeBefore = event.inboxBefore && (project == nil || event.projectBefore == project)
            return inScopeAfter && !inScopeBefore
        }
    }
}

/// Server-sent events framing (https://html.spec.whatwg.org/multipage/server-sent-events.html).
public enum SSE {
    /// `data` must not contain newlines (our payloads are single-line JSON).
    public static func frame(id: String?, event: String, data: String) -> String {
        var text = ""
        if let id { text += "id: \(id)\n" }
        return text + "event: \(event)\ndata: \(data)\n\n"
    }

    public static func comment(_ text: String) -> String { ": \(text)\n\n" }

    public static let resetReason = "drop folder changed"
    public static let resetData = #"{"reason":"drop folder changed"}"#
}

public struct SSEEvent: Equatable, Sendable {
    public var id: String?
    public var event: String
    public var data: String

    public init(id: String?, event: String, data: String) {
        self.id = id
        self.event = event
        self.data = data
    }
}

/// SSE parser. Feed raw bytes with `feed(byte:)`, or whole lines (including empty ones,
/// which end a frame) with `feed(line:)`. Lines are split on the LF byte; a trailing CR is
/// dropped. (Splitting a Swift `String` on "\n" would not work: "\r\n" is one Character.)
public struct SSEParser: Sendable {
    private var id: String?
    private var event: String?
    private var data: [String] = []
    private var lineBuffer: [UInt8] = []
    /// The last `id:` seen at the end of any frame, including id-only frames that dispatch
    /// no event (as an EventSource does). Send it back as `Last-Event-ID` on reconnect.
    public private(set) var lastEventID: String?

    public init() {}

    public mutating func feed(byte: UInt8) -> SSEEvent? {
        guard byte == 0x0A else {
            lineBuffer.append(byte)
            return nil
        }
        let line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)
        return feed(line: line)
    }

    public mutating func feed(line raw: String) -> SSEEvent? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            defer { id = nil; event = nil; data = [] }
            if let id { lastEventID = id }
            guard !data.isEmpty || event != nil else { return nil }
            return SSEEvent(id: id, event: event ?? "message", data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            let rest = line[line.index(after: colon)...]
            value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "id": id = String(value)
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}
