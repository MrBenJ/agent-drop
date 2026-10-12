// A stand-in for AgentDrop.app until Plan 3 builds it: hosts the same AgentDropService
// (content watcher + local server + server.json) in the foreground, so `drop watch` and
// other clients can be tried today. Not shipped; run it with `swift run agentdrop-devhost`.
import AgentDropCore
import AgentDropServer
import Foundation

let usage = """
    usage: swift run agentdrop-devhost [--temporary-setup]

    Serves the drop folder from config.json the way the app will, until Ctrl-C.

    --temporary-setup  The app's first-run setup hasn't happened yet (it can't: the app is
                       Plan 3). This marks setup complete, and confirms a protected drop
                       folder, only while the dev host runs. Both values are put back on exit.
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
if arguments.contains("--temporary-setup") {
    temporarySetup = try TemporarySetup.apply(to: config)
}

let service = AgentDropService(config: config)
let state: AgentDropService.State
do {
    state = try await service.start()
} catch let error as AgentDropError {
    temporarySetup?.restore()
    FileHandle.standardError.write(Data("agentdrop-devhost: \(error.message)\n".utf8))
    if error.message == ServiceMessages.setupIncomplete || error.message == ServiceMessages.confirmFolder {
        FileHandle.standardError.write(Data("(pass --temporary-setup to run before the app exists)\n".utf8))
    }
    exit(1)
}

let folder = config.folderURL(try config.load()).path
switch state {
case .running(let port):
    print("agentdrop-devhost: serving \(folder) on 127.0.0.1:\(port), pid \(getpid()). Ctrl-C to stop.")
case .noPort:
    print("agentdrop-devhost: watching \(folder), but no port was free (server.json says no-port). Ctrl-C to stop.")
case .stopped:
    exit(1)
}
if temporarySetup?.changedAnything == true {
    print("agentdrop-devhost: setup is marked complete only while this runs.")
}

// Stop cleanly on Ctrl-C / kill: close streams, remove server.json, restore config.json.
let signalQueue = DispatchQueue(label: "agentdrop-devhost.signals")
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler {
        Task {
            await service.stop()
            temporarySetup?.restore()
            print("\nagentdrop-devhost: stopped.")
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

while true {
    try await Task.sleep(for: .seconds(3600))
}
