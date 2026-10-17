import Testing
@testable import AgentDropServer

struct SecretsTests {
    @Test func equalStringsMatch() {
        #expect(Secrets.constantTimeEquals("Bearer abc123", "Bearer abc123"))
        #expect(Secrets.constantTimeEquals("", ""))
    }

    @Test(arguments: [("abc", "abd"), ("abc", "ab"), ("", "a"), ("a", "")])
    func differentStringsDoNot(a: String, b: String) {
        #expect(!Secrets.constantTimeEquals(a, b))
    }
}
