/// What the tailnet receiving listener is doing, for the Settings toggle.
public enum TailnetState: Equatable, Sendable {
    /// The toggle is off.
    case off
    /// The toggle is on but the service isn't running (setup or folder confirmation pending).
    case waiting
    /// No tailnet address on this Mac.
    case notConnected
    case portInUse(Int)
    /// `host` is the identity's `preferredHost`.
    case receiving(host: String, port: Int)
}
