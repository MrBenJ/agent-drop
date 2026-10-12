import Foundation
import Testing
@testable import AgentDropCore
@testable import DropCLI

/// Human-readable output must never pass terminal control sequences through: titles come
/// from file contents, so a dropped file could otherwise drive the reader's terminal.
struct TerminalSafetyTests {
    static let evil = "Evil \u{1B}]0;pwned\u{07}\u{1B}[2J\u{9B}31m\tnext\r\nline"

    func hasControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 || $0.value == 0x9B || $0.value == 0x0D }
    }

    @Test func sanitizer() {
        #expect(Output.terminalSafe("a\tb\nc\r\nd") == "a b c  d")
        #expect(Output.terminalSafe("x\u{1B}[31my\u{7F}\u{9B}") == "x\u{FFFD}[31my\u{FFFD}\u{FFFD}")
        #expect(Output.terminalSafe("one\ntwo\u{1B}", keepNewlines: true) == "one\ntwo\u{FFFD}")
        #expect(Output.terminalSafe("Q3 plan — draft ✅") == "Q3 plan — draft ✅")
    }

    @Test func listAndShowAreSafeButJSONIsExact() throws {
        let env = try TestEnv()
        try env.file("evil.md", "# \(Self.evil)\n")
        let id = env.run("add", "evil.md", "--from", "a", "-m", "first\nsecond\u{1B}[1m").trimmedOut

        let list = env.run("list")
        #expect(!hasControls(list.out))
        #expect(list.out.split(separator: "\n").count == 1)
        #expect(list.out.split(separator: "\t").count == 6)

        let show = env.run("show", id)
        #expect(!hasControls(show.out))
        #expect(show.out.contains("first\nsecond"))

        let json = env.run("show", id, "--json")
        #expect((json.json["title"] as? String)?.contains("\u{1B}]0;pwned") == true)
    }
}
