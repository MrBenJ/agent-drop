import Foundation
import Observation

/// The app's own preferences (spec §6), kept in UserDefaults. Shared settings (folder,
/// retention, port) live in config.json instead, because the CLI reads them too.
@MainActor @Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Spec §6 "Notify on new drops", default on.
    public var notifyOnNewDrops: Bool {
        didSet { defaults.set(notifyOnNewDrops, forKey: Keys.notify) }
    }

    /// Spec §6 "Hide Dock icon": accessory activation policy, menu bar only.
    public var hideDockIcon: Bool {
        didSet { defaults.set(hideDockIcon, forKey: Keys.hideDock) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifyOnNewDrops = defaults.object(forKey: Keys.notify) as? Bool ?? true
        hideDockIcon = defaults.bool(forKey: Keys.hideDock)
    }

    private enum Keys {
        static let notify = "notifyOnNewDrops"
        static let hideDock = "hideDockIcon"
    }
}
