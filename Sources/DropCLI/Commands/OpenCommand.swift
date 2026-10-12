import AgentDropCore
import AgentDropServer
import ArgumentParser
import Foundation

/// Spec §4 `drop open`: the app shows the drop's rendered view, launching if needed.
struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Show the drop in the Agent Drop app.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let context = CLIContext.current
        let drop = try context.openStore().resolve(id)
        let link = AppLink.url(forDrop: drop.id)
        do {
            // By bundle id, like `drop watch`, so a stray copy of the app can't take the link.
            _ = try context.runProcess(URL(fileURLWithPath: "/usr/bin/open"),
                                       ["-b", CLIContext.appBundleID, link.absoluteString])
        } catch let error as AgentDropError {
            throw AgentDropError.invalid("Couldn't open Agent Drop. Is AgentDrop.app installed? (\(error.message))")
        }
        if output.json { Output.emitJSON(["opened": link.absoluteString]) }
    }
}
