import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropCore

struct FormattingTests {
    func drop(title: String = "Auth plan", project: String? = "courses-app", readAt: Date? = nil,
              isFolder: Bool = false) -> Drop {
        Drop(id: "k7f2qa", filename: "a.md", isFolder: isFolder, title: title, description: nil, project: project, tags: [],
             from: "djleague/build-x", createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: Date(), readAt: readAt,
             kind: .note, status: nil, claimedBy: nil, statusNote: nil, archived: false, missing: false)
    }

    @Test func menuLineHasDotTitleProjectFromAndTime() {
        let now = Date(timeIntervalSince1970: 1_000_000 + 300)
        let time = DropFormatting.relativeTime(Date(timeIntervalSince1970: 1_000_000), relativeTo: now)
        #expect(DropFormatting.menuLine(drop(), relativeTo: now) == "● Auth plan — courses-app · djleague/build-x · " + time)
        #expect(!DropFormatting.menuLine(drop(project: nil, readAt: now), relativeTo: now).contains("●"))
        #expect(DropFormatting.menuLine(drop(project: nil), relativeTo: now).contains("Auth plan — djleague/build-x"))
    }

    @Test func aJustCreatedDropNeverReadsAsInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // The formatter alone says "in 0s" for the current moment, and the CLI's clock can
        // be a moment ahead of the window's.
        #expect(DropFormatting.relativeTime(now.addingTimeInterval(1.5), relativeTo: now) == "just now")
        #expect(DropFormatting.relativeTime(now, relativeTo: now) == "just now")
        #expect(DropFormatting.relativeTime(now.addingTimeInterval(-59), relativeTo: now) == "just now")
        #expect(DropFormatting.relativeTime(now.addingTimeInterval(-120), relativeTo: now) != "just now")
    }

    @Test func longTitlesAreShortened() {
        let line = DropFormatting.menuLine(drop(title: String(repeating: "x", count: 100)))
        #expect(line.contains(String(repeating: "x", count: 59) + "…"))
    }

    @Test func longWindowTitlesEndInAnEllipsis() {
        #expect(DropFormatting.windowTitle("Inbox") == "Inbox")
        let title = DropFormatting.windowTitle("Claude Code (twitch-chat-bot-design worktree)")
        #expect(title == "Claude Code (twitch-chat-bo…")
        #expect(title.count == 28)
    }

    @Test func copyCommandFitsTheKindOfDrop() {
        #expect(DropFormatting.copyCommand(drop()) == "drop cat k7f2qa")
        #expect(DropFormatting.copyCommand(drop(isFolder: true)) == "drop path k7f2qa")
    }

    @Test func retentionChoicesRoundTripAndKeepCLIValues() {
        for choice in RetentionChoice.allCases where choice != .custom {
            #expect(RetentionChoice(choice.retention!) == choice)
        }
        #expect(RetentionChoice(.days(14)) == .custom)
        #expect(RetentionChoice.custom.retention == nil)
        #expect(RetentionChoice.note.contains("Your drops and files are never deleted."))
    }
}
