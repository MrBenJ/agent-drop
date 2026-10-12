import AgentDropCore
import Foundation

/// Text the menu bar and lists show for a drop (spec §6).
public enum DropFormatting {
    /// One menu line: unread dot, title, project, from, relative time.
    public static func menuLine(_ drop: Drop, relativeTo now: Date = Date()) -> String {
        let title = drop.title.count > 60 ? drop.title.prefix(59) + "…" : drop.title
        let details = [drop.project, drop.from, relativeTime(drop.createdAt, relativeTo: now)]
            .compactMap { $0 }.joined(separator: " · ")
        return (drop.isUnread ? "● " : "") + title + " — " + details
    }

    /// The window title for a sidebar view. AppKit draws it in the toolbar without
    /// truncating, so a long project or From name would run across the list column.
    public static func windowTitle(_ name: String, limit: Int = 28) -> String {
        name.count > limit ? name.prefix(limit - 1) + "…" : name
    }

    public static func relativeTime(_ date: Date, relativeTo now: Date = Date()) -> String {
        // Under a minute old (or a moment "ahead", from another process's clock).
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    public static func statusLabel(_ status: HandoffStatus) -> String {
        switch status {
        case .open: "Open"
        case .claimed: "Claimed"
        case .done: "Done"
        }
    }

    /// The **Copy** command for pasting into an agent. `drop cat` prints a file; for a
    /// folder drop the agent needs its path instead.
    public static func copyCommand(_ drop: Drop) -> String {
        drop.isFolder ? "drop path \(drop.id)" : "drop cat \(drop.id)"
    }
}

/// Settings → Event history (spec §5.1): presets plus **Custom…**, which keeps any value
/// set from the CLI displayed as-is.
public enum RetentionChoice: Hashable, CaseIterable, Sendable {
    case days7, days30, days90, forever, custom

    public init(_ retention: Retention) {
        switch retention {
        case .days(7): self = .days7
        case .days(30): self = .days30
        case .days(90): self = .days90
        case .forever: self = .forever
        case .days: self = .custom
        }
    }

    /// nil for `.custom`, whose days come from the text field.
    public var retention: Retention? {
        switch self {
        case .days7: .days(7)
        case .days30: .days(30)
        case .days90: .days(90)
        case .forever: .forever
        case .custom: nil
        }
    }

    public var label: String {
        switch self {
        case .days7: "7 days"
        case .days30: "30 days"
        case .days90: "90 days"
        case .forever: "Forever"
        case .custom: "Custom…"
        }
    }

    /// The disclosure note, verbatim from the spec.
    public static let note = "Old entries in the change log are deleted as new changes come in. Your drops and files are never deleted."
}
