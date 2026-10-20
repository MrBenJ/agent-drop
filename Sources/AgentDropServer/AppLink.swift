import AgentDropCore
import Foundation

/// `agentdrop://drop/<id>` (spec §4 `drop open`): how `drop open` and notifications ask
/// AgentDrop.app to show a drop.
public enum AppLink {
    public static let scheme = "agentdrop"

    /// `background`: show the drop without taking focus (`drop open`'s default).
    public static func url(forDrop id: String, background: Bool = false) -> URL {
        URL(string: "\(scheme)://drop/\(id)\(background ? "?background=1" : "")")!
    }

    /// Whether the link asks to leave focus with the app the user is in.
    public static func isBackground(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "background" && $0.value == "1" } ?? false
    }

    /// The drop id in an `agentdrop://drop/<id>` URL; nil for anything else.
    public static func dropID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "drop" else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1, DropID.isWellFormed(String(parts[0])) else { return nil }
        return String(parts[0])
    }
}
