import Foundation
import Testing
@testable import AgentDropApp
@testable import AgentDropServer
@testable import DropCLI

struct LaunchOptionsTests {
    @Test func windowlessOnlyWhenPassed() {
        #expect(LaunchOptions(arguments: ["/x/AgentDrop", "--windowless"]).windowless)
        #expect(!LaunchOptions(arguments: ["/x/AgentDrop"]).windowless)
        // argv[0] is the executable path, never an option.
        #expect(!LaunchOptions(arguments: ["--windowless"]).windowless)
    }

    @Test func backgroundOnlyWhenPassed() {
        let options = LaunchOptions(arguments: ["/x/AgentDrop", "--background"])
        #expect(options.background && !options.windowless)
        #expect(!LaunchOptions(arguments: ["/x/AgentDrop"]).background)
        #expect(!LaunchOptions(arguments: ["--background"]).background)
    }

    @Test func bundleIdentityMatchesTheCLIAndInfoPlist() throws {
        #expect(AppIdentity.bundleID == CLIContext.appBundleID)
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == AppIdentity.bundleID)
        #expect(plist["CFBundleExecutable"] as? String == "AgentDrop")
        let schemes = (plist["CFBundleURLTypes"] as? [[String: Any]])?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == [AppLink.scheme])
        // A windowless menu bar app hosting a server must never be quit by the system
        // (spec §4 Watching: once launched, it runs until the user quits it).
        #expect(plist["NSSupportsAutomaticTermination"] as? Bool == false)
        #expect(plist["NSSupportsSuddenTermination"] as? Bool == false)
        // The icon build-app.sh copies into Contents/Resources.
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        let icon = plistURL.deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
        #expect(FileManager.default.fileExists(atPath: icon.path))
    }
}
