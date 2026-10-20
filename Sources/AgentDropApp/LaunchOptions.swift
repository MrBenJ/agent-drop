import Foundation

/// How the app was started (spec §4 Watching): `drop watch` launches it with
/// `--windowless`, which skips opening the main window. Setup still shows its window.
/// `drop open` (unless `--foreground`) launches it with `--background`: windows open without
/// taking focus.
public struct LaunchOptions: Equatable, Sendable {
    public var windowless: Bool
    public var background: Bool

    public init(arguments: [String]) {
        windowless = arguments.dropFirst().contains("--windowless")
        background = arguments.dropFirst().contains("--background")
    }
}
