import Foundation
@testable import AgentDropCore
@testable import DropCLI

/// Each test gets its own home, config dir, drop folder and cwd. No real paths are touched.
final class TestEnv: @unchecked Sendable {
    let root: URL
    let config: ConfigStore
    let cwd: URL
    var stdin = Data()
    var codeExecutable: URL?
    var useRealProcess = false
    /// When set, the fake `runProcess` records the call and then throws this.
    var processError: AgentDropError?
    /// `drop watch` hooks. By default launching fails, so a test must opt in.
    var launchApp: @Sendable () throws -> Void = { throw AgentDropError.invalid("no app in tests") }
    var isProcessAlive: @Sendable (Int32) -> Bool = { pid in pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
    var serverWait: Duration = .seconds(3)
    /// What `CLIContext.environment` returns (e.g. `AGENT_DROP_REMOTE_URL`).
    var environment: [String: String] = [:]
    let clock = Date(timeIntervalSince1970: 1_760_208_240)
    private let lock = NSLock()
    private var _processCalls: [(URL, [String])] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropcli-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        cwd = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        config = ConfigStore(
            configDir: home.appendingPathComponent("Library/Application Support/AgentDrop", isDirectory: true),
            homeDir: home)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var home: URL { config.homeDir }
    var dropFolder: URL { home.appendingPathComponent("AgentDrop", isDirectory: true) }
    var processCalls: [(URL, [String])] { lock.withLock { _processCalls } }

    struct Result {
        let code: Int32
        let out: String
        let err: String
        let outData: Data
        var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: outData)) as? [String: Any]) ?? [:] }
        var jsonArray: [[String: Any]] { ((try? JSONSerialization.jsonObject(with: outData)) as? [[String: Any]]) ?? [] }
        var trimmedOut: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func makeContext(out: OutputSink, err: OutputSink) -> CLIContext {
        let stdin = self.stdin, clock = self.clock, code = self.codeExecutable
        let useRealProcess = self.useRealProcess, processError = self.processError
        let environment = self.environment
        return CLIContext(
            config: config, cwd: cwd, now: { clock }, readStdin: { stdin },
            stdout: out, stderr: err,
            findExecutable: { $0 == "code" ? code : nil },
            runProcess: { [weak self] executable, args in
                if useRealProcess { return try CLIContext.live().runProcess(executable, args) }
                self?.lock.withLock { self?._processCalls.append((executable, args)) }
                if let processError { throw processError }
                return 0
            },
            launchApp: launchApp, isProcessAlive: isProcessAlive, serverWait: serverWait, environment: environment)
    }

    @discardableResult
    func run(_ arguments: String...) -> Result {
        let out = OutputSink(), err = OutputSink()
        let status = DropCLI.run(arguments, context: makeContext(out: out, err: err))
        return Result(code: status, out: out.text, err: err.text, outData: out.data)
    }

    /// For `drop watch` and `drop add --to`. `out` can be read while the command is still running.
    func runAsync(_ arguments: [String], out: OutputSink = OutputSink()) async -> Result {
        let err = OutputSink()
        let status = await DropCLI.runAsync(arguments, context: makeContext(out: out, err: err))
        return Result(code: status, out: out.text, err: err.text, outData: out.data)
    }

    @discardableResult
    func file(_ relative: String, _ contents: String) throws -> URL {
        try data(relative, Data(contents.utf8))
    }

    @discardableResult
    func data(_ relative: String, _ data: Data) throws -> URL {
        let url = cwd.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}
