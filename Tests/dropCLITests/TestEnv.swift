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

    @discardableResult
    func run(_ arguments: String...) -> Result {
        let out = OutputSink(), err = OutputSink()
        let stdin = self.stdin, clock = self.clock, code = self.codeExecutable
        let useRealProcess = self.useRealProcess
        let context = CLIContext(
            config: config, cwd: cwd, now: { clock }, readStdin: { stdin },
            stdout: out, stderr: err,
            findExecutable: { $0 == "code" ? code : nil },
            runProcess: { [weak self] executable, args in
                if useRealProcess { return try CLIContext.live().runProcess(executable, args) }
                self?.lock.withLock { self?._processCalls.append((executable, args)) }
                return 0
            })
        let status = DropCLI.run(arguments, context: context)
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
