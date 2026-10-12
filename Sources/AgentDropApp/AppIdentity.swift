import Foundation

public enum AppIdentity {
    /// Must match CFBundleIdentifier in App/Info.plist and `CLIContext.appBundleID`.
    public static let bundleID = "io.github.mrbenj.AgentDrop"

    /// True when running from AgentDrop.app. `swift run AgentDrop` is unbundled, and
    /// notifications and the login item need a bundle.
    public static var isBundled: Bool { Bundle.main.bundleIdentifier == bundleID }
}
