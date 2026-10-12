/// Every user-facing failure. The case decides the CLI exit code (spec §4 Global rules).
public enum AgentDropError: Error, Equatable, Sendable {
    case invalid(String)   // exit 1: bad input, wrong kind, unusable store
    case notFound(String)  // exit 2
    case conflict(String)  // exit 3: e.g. handoff already claimed

    public var exitCode: Int32 {
        switch self {
        case .invalid: 1
        case .notFound: 2
        case .conflict: 3
        }
    }

    public var message: String {
        switch self {
        case .invalid(let m), .notFound(let m), .conflict(let m): m
        }
    }
}
