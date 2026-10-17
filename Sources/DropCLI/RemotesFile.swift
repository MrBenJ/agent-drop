import AgentDropCore
import AgentDropServer
import Foundation

/// `<configDir>/remotes.json`: the other Macs this one sends drops to, by name.
/// Holds their keys, so it is written privately (mode 0600).
public struct RemotesFile {
    public let url: URL

    public init(configDir: URL) {
        url = configDir.appendingPathComponent("remotes.json")
    }

    private struct Body: Codable {
        var remotes: [String: TailnetClient.Remote]
    }

    /// Empty when the file doesn't exist yet.
    public func load() throws -> [String: TailnetClient.Remote] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            throw AgentDropError.invalid("Can't read \(url.path): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Body.self, from: data).remotes
        } catch {
            throw AgentDropError.invalid("\(url.path) is not valid remotes JSON. Fix or delete it.")
        }
    }

    /// Load, mutate and save as one transaction under an exclusive `flock` on
    /// `remotes.json.lock`, so concurrent `drop remote add/remove` processes can't lose
    /// each other's changes. Nothing is saved if `body` throws.
    @discardableResult
    public func update<T>(_ body: (inout [String: TailnetClient.Remote]) throws -> T) throws -> T {
        let lockURL = url.appendingPathExtension("lock")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw AgentDropError.invalid("Can't create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw AgentDropError.invalid("Can't open \(lockURL.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) } // closing releases the lock
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw AgentDropError.invalid("Can't lock \(lockURL.path): \(String(cString: strerror(errno)))")
            }
        }
        var remotes = try load()
        let result = try body(&remotes)
        try save(remotes)
        return result
    }

    public func save(_ remotes: [String: TailnetClient.Remote]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try PrivateFile.write(try encoder.encode(Body(remotes: remotes)), to: url)
        } catch {
            throw AgentDropError.invalid("Can't write \(url.path): \(error.localizedDescription)")
        }
    }
}

extension CLIContext {
    /// `env` reads the remote from the environment; any other name comes from remotes.json.
    public func remote(named name: String) throws -> TailnetClient.Remote {
        if name == "env" {
            guard let rawURL = environment["AGENT_DROP_REMOTE_URL"], let url = URL(string: rawURL),
                  let key = environment["AGENT_DROP_REMOTE_KEY"], !key.isEmpty else {
                throw AgentDropError.invalid("--to env needs AGENT_DROP_REMOTE_URL and AGENT_DROP_REMOTE_KEY")
            }
            return TailnetClient.Remote(url: url, key: key)
        }
        guard let remote = try RemotesFile(configDir: config.configDir).load()[name] else {
            throw AgentDropError.notFound("No remote named '\(name)'. Add it with `drop remote add \(name) --url … --key …`")
        }
        return remote
    }
}
