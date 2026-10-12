import Testing
@testable import AgentDropCore

struct DropIDTests {
    @Test func alphabetHas32UnambiguousSymbols() {
        #expect(DropID.alphabet.count == 32)
        for banned: Character in ["o", "l", "0", "1"] {
            #expect(!DropID.alphabet.contains(banned))
        }
    }

    @Test func generatedIdsAreWellFormed() {
        for _ in 0..<1_000 {
            let id = DropID.generate()
            #expect(id.count == 6)
            #expect(DropID.isWellFormed(id))
        }
    }

    @Test func wellFormedRejectsWrongLengthAndCharacters() {
        #expect(!DropID.isWellFormed("k7f2q"))
        #expect(!DropID.isWellFormed("k7f2qaa"))
        #expect(!DropID.isWellFormed("k7f2qo"))
        #expect(!DropID.isWellFormed("plan.md"))
        #expect(DropID.isWellFormed("k7f2qa"))
    }

    @Test func storeIDIsTwelveCharacters() {
        let a = DropID.storeID(), b = DropID.storeID()
        #expect(a.count == 12)
        #expect(a != b)
    }

    @Test func errorExitCodes() {
        #expect(AgentDropError.invalid("x").exitCode == 1)
        #expect(AgentDropError.notFound("x").exitCode == 2)
        #expect(AgentDropError.conflict("x").exitCode == 3)
        #expect(AgentDropError.conflict("msg").message == "msg")
    }
}
