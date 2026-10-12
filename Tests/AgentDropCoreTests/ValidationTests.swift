import Testing
@testable import AgentDropCore

struct ValidationTests {
    @Test func identityKeepsSlashesSpacesBrackets() throws {
        let v = try Validation.identity("  djleague/autodev/AutoDev DJ-1234 [ef013ae]\t", field: "--from")
        #expect(v == "djleague/autodev/AutoDev DJ-1234 [ef013ae]")
    }

    @Test func identityRejectsEmptyNewlinesControlAndLong() {
        expectError(1) { _ = try Validation.identity("   ", field: "--from") }
        expectError(1) { _ = try Validation.identity("a\nb", field: "--from") }
        expectError(1) { _ = try Validation.identity("a\u{0007}b", field: "--from") }
        expectError(1) { _ = try Validation.identity(String(repeating: "x", count: 201), field: "--from") }
        #expect((try? Validation.identity(String(repeating: "x", count: 200), field: "--from")) != nil)
    }

    @Test func tagsKeepCase() throws {
        #expect(try Validation.tag(" PR ") == "PR")
        #expect(try Validation.tag("pr") == "pr")
    }

    @Test func dropNameRule() throws {
        #expect(try Validation.dropName("plan.md") == "plan.md")
        #expect(try Validation.dropName("Q3 plan — draft ✅.md") == "Q3 plan — draft ✅.md")
        for bad in ["", ".", "..", ".notes.md", "a/b.md"] {
            expectError(1) { _ = try Validation.dropName(bad) }
        }
    }

    @Test func fromUnderMatchesWholeLevelsOnly() {
        #expect(Validation.isUnder("djleague", prefix: "djleague"))
        #expect(Validation.isUnder("djleague/autodev/tab", prefix: "djleague"))
        #expect(!Validation.isUnder("djleague2", prefix: "djleague"))
        #expect(!Validation.isUnder("dj", prefix: "djleague"))
    }

    @Test func suffixing() {
        #expect(Validation.suffixed("plan.md", n: 2, isFolder: false) == "plan-2.md")
        #expect(Validation.suffixed("archive.tar.gz", n: 3, isFolder: false) == "archive.tar-3.gz")
        #expect(Validation.suffixed("README", n: 2, isFolder: false) == "README-2")
        #expect(Validation.suffixed("bundle.v2", n: 2, isFolder: true) == "bundle.v2-2")
    }

    @Test func textTrimsAndRejectsEmpty() throws {
        #expect(try Validation.text("  Why\nthis exists \n", field: "--desc") == "Why\nthis exists")
        expectError(1) { _ = try Validation.text(" \n ", field: "--title") }
    }

    @Test func uniqueKeepsFirstOccurrenceOrder() {
        #expect(Validation.unique(["b", "a", "b", "c", "a"]) == ["b", "a", "c"])
    }
}
