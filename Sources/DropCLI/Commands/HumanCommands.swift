import AgentDropCore
import ArgumentParser

struct Code: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "code", abstract: "Open the drop in VS Code.")
    @Argument(help: "Id or exact filename.") var id: String
    @OptionGroup var output: JSONOption

    func run() throws {
        let context = CLIContext.current
        let store = try context.openStore()
        let url = try requireFile(try store.resolve(id), store: store)
        guard let code = context.findExecutable("code") else {
            throw AgentDropError.invalid(
                "VS Code's `code` command isn't on your PATH. In VS Code, run \"Shell Command: Install 'code' command in PATH\".")
        }
        let status = try context.runProcess(code, [url.path])
        guard status == 0 else { throw AgentDropError.invalid("`code` exited with status \(status)") }
        if output.json { Output.emitJSON(["opened": url.path]) }
    }
}

struct AgentInstructions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-instructions", abstract: "Print a snippet for CLAUDE.md / AGENTS.md.")
    @OptionGroup var output: JSONOption

    static let text = """
        ## Agent Drop

        This machine has Agent Drop: a shared drop folder, with context, for handing files to the human and to other agents. Use the `drop` CLI.

        **Your identity.** Pass the identity your harness gives you as `--from` (when dropping) and `--by` (when claiming), exactly as given. Always quote it, because it may contain spaces or brackets: `--from "djleague/autodev/AutoDev DJ-1234 [ef013ae]"`. If you don't have one, ask the user what to use.

        **Drop a file** (spec, plan, report, handoff) with context about what it is and why it matters:

            drop add plan.md --from "<identity>" --project "<project>" --title "Auth refactor plan" -m "Why this exists and what the reader should do"

        - Content without a file: `printf '%s' "$CONTENT" | drop add - --name notes.md --from "<identity>"`
        - A whole folder works too: `drop add ./handoff-bundle/ --from "<identity>"`
        - For another agent to pick up, add `--handoff`. Tag with `--tag <t>` (repeatable).

        **Pick up work:**

            drop inbox --project "<project>" --json      # open handoffs
            drop claim <id> --by "<identity>"            # exit 3 = someone else has it; pick another
            drop cat <id>                                # read it
            drop done <id> --note "What you did, e.g. shipped in PR #42"

        If you can't finish, run `drop release <id>` so someone else can claim it.

        Every command accepts `--json` (except `drop cat`). Exit codes: 0 ok, 1 error, 2 not found, 3 conflict.
        """

    func run() throws {
        if output.json { Output.emitJSON(["instructions": Self.text]) } else { Output.emit(Self.text) }
    }
}
