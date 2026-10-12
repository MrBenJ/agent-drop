import AgentDropCore
import Foundation

/// `agentdrop://drop/<id>` (spec §4 `drop open`): how `drop open` and notifications ask
/// AgentDrop.app to show a drop.
public enum AppLink {
    public static let scheme = "agentdrop"

    public static func url(forDrop id: String) -> URL {
        URL(string: "\(scheme)://drop/\(id)")!
    }

    /// The drop id in an `agentdrop://drop/<id>` URL; nil for anything else.
    public static func dropID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "drop" else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1, DropID.isWellFormed(String(parts[0])) else { return nil }
        return String(parts[0])
    }
}
