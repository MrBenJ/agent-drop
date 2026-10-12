import AgentDropCore
import AgentDropServer
import Foundation

/// Buffered (tests) or pass-through (live) output.
public final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let handle: FileHandle?

    public init(handle: FileHandle? = nil) {
        self.handle = handle
    }

    public func write(_ data: Data) {
        lock.withLock {
            if let handle { handle.write(data) } else { buffer.append(data) }
        }
    }

    public func write(_ string: String) { write(Data(string.utf8)) }
    public func line(_ string: String) { write(string + "\n") }
    public var data: Data { lock.withLock { buffer } }
    public var text: String { String(decoding: data, as: UTF8.self) }
}

/// Everything a command touches outside its own arguments. Tests inject all of it (spec §8).
public struct CLIContext: Sendable {
    public var config: ConfigStore
    public var cwd: URL
    public var now: @Sendable () -> Date
    public var readStdin: @Sendable () -> Data
    public var stdout: OutputSink
    public var stderr: OutputSink
    public var findExecutable: @Sendable (String) -> URL?
    public var runProcess: @Sendable (URL, [String]) throws -> Int32
    /// `drop watch`: start AgentDrop.app without opening its window (spec §4 Watching).
    public var launchApp: @Sendable () throws -> Void
    public var isProcessAlive: @Sendable (Int32) -> Bool
    /// How long `drop watch` waits for the app's server (spec: 10 s).
    public var serverWait: Duration

    public init(config: ConfigStore, cwd: URL, now: @escaping @Sendable () -> Date,
                readStdin: @escaping @Sendable () -> Data, stdout: OutputSink, stderr: OutputSink,
                findExecutable: @escaping @Sendable (String) -> URL?,
                runProcess: @escaping @Sendable (URL, [String]) throws -> Int32,
                launchApp: @escaping @Sendable () throws -> Void = {
                    throw AgentDropError.invalid("Launching Agent Drop isn't available here")
                },
                isProcessAlive: @escaping @Sendable (Int32) -> Bool = ServerInfo.isProcessAlive,
                serverWait: Duration = .seconds(10)) {
        self.config = config
        self.cwd = cwd
        self.now = now
        self.readStdin = readStdin
        self.stdout = stdout
        self.stderr = stderr
        self.findExecutable = findExecutable
        self.runProcess = runProcess
        self.launchApp = launchApp
        self.isProcessAlive = isProcessAlive
        self.serverWait = serverWait
    }

    /// AgentDrop.app's bundle identifier (App/Info.plist).
    public static let appBundleID = "io.github.mrbenj.AgentDrop"

    @TaskLocal public static var current: CLIContext = .live()

    public static func live() -> CLIContext {
        let runProcess: @Sendable (URL, [String]) throws -> Int32 = { executable, arguments in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Drain both streams together before waiting, so even verbose children
            // cannot fill a pipe or bypass the CLI's JSON/error output policy.
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let detail = String(decoding: diagnostics, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw AgentDropError.invalid("`\(executable.lastPathComponent)` exited with status \(process.terminationStatus)"
                    + (detail.isEmpty ? "" : ": \(detail)"))
            }
            return process.terminationStatus
        }
        return CLIContext(
            config: .live(),
            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            now: { Date() },
            readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
            stdout: OutputSink(handle: .standardOutput),
            stderr: OutputSink(handle: .standardError),
            findExecutable: { name in
                let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
                for directory in path.split(separator: ":") {
                    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
                    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                }
                return nil
            },
            runProcess: runProcess,
            launchApp: {
                // -g: don't bring it to the front. `--windowless` tells the app not to open its
                // window (spec §4 Watching); the menu bar icon still appears.
                do {
                    _ = try runProcess(URL(fileURLWithPath: "/usr/bin/open"),
                                       ["-g", "-b", appBundleID, "--args", "--windowless"])
                } catch let error as AgentDropError {
                    throw AgentDropError.invalid("Couldn't launch Agent Drop. Is AgentDrop.app installed? (\(error.message))")
                }
            })
    }

    /// `~`, relative-to-cwd, and trailing-slash handling for user-supplied paths.
    public func resolvePath(_ raw: String) -> URL {
        var path = raw
        if path == "~" {
            path = config.homeDir.path
        } else if path.hasPrefix("~/") {
            path = config.homeDir.path + String(path.dropFirst(1))
        }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : cwd.appendingPathComponent(path)
        return url.standardizedFileURL
    }

    /// Opens the store in the configured folder, creating the folder if needed (spec §7).
    public func openStore() throws -> DropStore {
        let settings = try config.load()
        let folder = config.folderURL(settings)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw AgentDropError.invalid("Can't create the drop folder at \(folder.path): \(error.localizedDescription)")
        }
        return try DropStore.open(folder: folder, retention: settings.eventRetentionDays, now: now)
    }
}
