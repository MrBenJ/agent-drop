import Foundation
import Testing
@testable import AgentDropCore
@testable import AgentDropServer
@testable import DropCLI

/// Spec §4 `drop open`.
struct OpenCommandTests {
    @Test func opensTheDropLinkInTheAppByBundleIDWithoutTakingFocus() throws {
        let env = try TestEnv()
        try env.file("plan.md", "# Plan")
        let id = env.run("add", "plan.md", "--from", "a").trimmedOut
        let link = "agentdrop://drop/\(id)?background=1"
        #expect(env.run("open", "plan.md").code == 0) // a filename resolves to the id
        let call = try #require(env.processCalls.first)
        #expect(call.0.path == "/usr/bin/open")
        // -g keeps `open` from activating the app; --background covers a fresh launch.
        #expect(call.1 == ["-g", "-b", "io.github.mrbenj.AgentDrop", link, "--args", "--background"])
        #expect(env.run("open", id, "--json").json["opened"] as? String == link)
    }

    @Test func foregroundBringsTheAppForward() throws {
        let env = try TestEnv()
        try env.file("plan.md", "# Plan")
        let id = env.run("add", "plan.md", "--from", "a").trimmedOut
        #expect(env.run("open", id, "--foreground").code == 0)
        let call = try #require(env.processCalls.first)
        #expect(call.1 == ["-b", "io.github.mrbenj.AgentDrop", "agentdrop://drop/\(id)"])
        #expect(env.run("open", id, "-f", "--json").json["opened"] as? String == "agentdrop://drop/\(id)")
    }

    @Test func unknownIdIsExit2AndOpensNothing() throws {
        let env = try TestEnv()
        let r = env.run("open", "zzzzzz")
        #expect(r.code == 2)
        #expect(env.processCalls.isEmpty)
    }

    @Test func appNotInstalledIsExit1WithAHint() throws {
        let env = try TestEnv()
        try env.file("plan.md", "# Plan")
        let id = env.run("add", "plan.md", "--from", "a").trimmedOut
        env.processError = .invalid("`open` exited with status 1: Unable to find application")
        let r = env.run("open", id, "--json")
        #expect(r.code == 1)
        let message = r.json["error"] as? String ?? ""
        #expect(message.contains("Is AgentDrop.app installed?") && message.contains("Unable to find application"))
    }
}

struct AppLinkTests {
    @Test func roundTrips() {
        let url = AppLink.url(forDrop: "k7f2qa")
        #expect(url.absoluteString == "agentdrop://drop/k7f2qa")
        #expect(AppLink.dropID(from: url) == "k7f2qa")
        #expect(!AppLink.isBackground(url))
    }

    @Test func backgroundRoundTrips() throws {
        let url = AppLink.url(forDrop: "k7f2qa", background: true)
        #expect(url.absoluteString == "agentdrop://drop/k7f2qa?background=1")
        #expect(AppLink.dropID(from: url) == "k7f2qa")
        #expect(AppLink.isBackground(url))
        #expect(!AppLink.isBackground(try #require(URL(string: "agentdrop://drop/k7f2qa?background=0"))))
    }

    @Test(arguments: ["agentdrop://drop/", "agentdrop://drop/k7f2qa/extra", "agentdrop://other/k7f2qa",
                      "https://drop/k7f2qa", "agentdrop://drop/NOTANID", "agentdrop://drop/k7f2q0"])
    func rejectsAnythingElse(_ raw: String) throws {
        #expect(AppLink.dropID(from: try #require(URL(string: raw))) == nil)
    }
}
