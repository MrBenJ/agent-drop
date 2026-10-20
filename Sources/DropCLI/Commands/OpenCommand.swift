import AgentDropCore
import AgentDropServer
import ArgumentParser
import Foundation

/// Spec §4 `drop open`: the app shows the drop's rendered view, launching if needed.
/// It leaves focus where it is unless `--foreground` asks for the app to come forward.
struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Show the drop in the Agent Drop app.")
    @Argument(help: "Id or exact filename.") var id: String
    @Flag(name: [.customShort("f"), .long], help: "Bring Agent Drop to the front and give it focus.")
    var foreground = false
    @OptionGroup var output: JSONOption

    func run() throws {
        let context = CLIContext.current
        let drop = try context.openStore().resolve(id)
        let background = !foreground
        let link = AppLink.url(forDrop: drop.id, background: background)
        // By bundle id, like `drop watch`, so a stray copy of the app can't take the link.
        // By default (background), -g stops `open` activating the app, the link stops a running
        // app activating itself, and --background (only read at launch) covers a fresh one.
        let arguments = background
            ? ["-g", "-b", CLIContext.appBundleID, link.absoluteString, "--args", "--background"]
            : ["-b", CLIContext.appBundleID, link.absoluteString]
        do {
            _ = try context.runProcess(URL(fileURLWithPath: "/usr/bin/open"), arguments)
        } catch let error as AgentDropError {
            throw AgentDropError.invalid("Couldn't open Agent Drop. Is AgentDrop.app installed? (\(error.message))")
        }
        if output.json { Output.emitJSON(["opened": link.absoluteString]) }
    }
}
