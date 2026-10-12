// A development stand-in for AgentDrop.app without a window: hosts the same
// AgentDropService (content watcher + local server + server.json) in the foreground, so
// `drop watch` and other clients can be tried from a terminal. Not shipped; run it with
// `swift run agentdrop-devhost`. Don't run it while the app is running: both would serve.
import AgentDropCore
import AgentDropServer
import Foundation

let usage = """
    usage: swift run agentdrop-devhost [--temporary-setup]

    Serves the drop folder from config.json the way the app does, until Ctrl-C.

    --temporary-setup  For a machine where the app's first-run setup hasn't happened. This
                       marks setup complete, and confirms a protected drop folder, only
                       while the dev host runs. Both values are put back on exit.
    """

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}
let unknown = arguments.subtracting(["--temporary-setup"])
guard unknown.isEmpty else {
    FileHandle.standardError.write(Data("agentdrop-devhost: unknown option \(unknown.sorted().joined(separator: " "))\n\(usage)\n".utf8))
    exit(1)
}

let config = ConfigStore.live()
var temporarySetup: TemporarySetup?
let service = AgentDropService(config: config)

@MainActor func fail(_ message: String) -> Never {
    temporarySetup?.restore()
    FileHandle.standardError.write(Data("agentdrop-devhost: \(message)\n".utf8))
    exit(1)
}

// Installed before anything changes, so even an early Ctrl-C puts config.json back.
// Handlers run on the main queue: top-level code is main-actor isolated in Swift 6, and
// touching `service` / `temporarySetup` from another queue traps at runtime.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        Task { @MainActor in
            await service.stop()
            temporarySetup?.restore()
            print("\nagentdrop-devhost: stopped.")
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

if arguments.contains("--temporary-setup") {
    do {
        temporarySetup = try TemporarySetup.apply(to: config)
    } catch {
        fail("couldn't update config.json: \(error.localizedDescription)")
    }
}

let state: AgentDropService.State
do {
    state = try await service.start()
} catch let error as AgentDropError {
    if error.message == ServiceMessages.setupIncomplete || error.message == ServiceMessages.confirmFolder {
        fail("\(error.message)\n(pass --temporary-setup to run without the app's setup)")
    }
    fail(error.message)
} catch {
    fail(error.localizedDescription)
}

let folder = config.folderURL((try? config.load()) ?? AgentDropConfig()).path
switch state {
case .running(let port):
    print("agentdrop-devhost: serving \(folder) on 127.0.0.1:\(port), pid \(getpid()). Ctrl-C to stop.")
case .noPort:
    print("agentdrop-devhost: watching \(folder), but no port was free (server.json says no-port). Ctrl-C to stop.")
case .stopped:
    fail("the service didn't start")
}
if temporarySetup?.changedAnything == true {
    print("agentdrop-devhost: setup is marked complete only while this runs.")
}

while true {
    try await Task.sleep(for: .seconds(3600))
}
