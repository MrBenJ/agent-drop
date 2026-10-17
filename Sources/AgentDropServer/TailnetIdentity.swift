import Foundation

/// This Mac's address and name on the tailnet.
public struct TailnetIdentity: Sendable, Equatable {
    public var address: String
    /// FQDN, lowercased, no trailing dot.
    public var dnsName: String?

    public init(address: String, dnsName: String?) {
        self.address = address
        self.dnsName = dnsName
    }

    public var preferredHost: String { dnsName ?? address }

    /// Every `Host` header value a legitimate tailnet client can send.
    public func allowedHosts(port: Int) -> Set<String> {
        var hosts: Set<String> = ["\(address):\(port)".lowercased()]
        if let dnsName = dnsName?.lowercased(), !dnsName.isEmpty {
            hosts.insert("\(dnsName):\(port)")
            if let short = dnsName.split(separator: ".").first {
                hosts.insert("\(short):\(port)")
            }
        }
        return hosts
    }
}

public enum TailnetAccess {
    /// IPv4 in `100.64.0.0/10`.
    public static func isTailnetPeer(_ ipv4: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, ipv4, &addr) == 1 else { return false }
        return isTailnet(UInt32(bigEndian: addr.s_addr))
    }

    static func isTailnet(_ hostOrderAddress: UInt32) -> Bool {
        hostOrderAddress & 0xFFC0_0000 == 0x6440_0000
    }
}

public struct TailnetLocator: Sendable {
    public var locate: @Sendable () async -> TailnetIdentity?

    public init(locate: @escaping @Sendable () async -> TailnetIdentity?) {
        self.locate = locate
    }

    /// The tailnet IPv4 on a `utun` interface (cross-checked against `tailscale status
    /// --json` when the CLI answers), plus the DNS name from that same status. The status
    /// is cached (see `TailscaleStatusCache`), so the service's 10 s poll doesn't spawn
    /// the CLI each time.
    public static let live = TailnetLocator {
        let interfaces = interfaceIPv4s()
        let status = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            // A GCD thread, not the cooperative pool: the subprocess wait blocks.
            DispatchQueue.global().async {
                cont.resume(returning: statusCache.status(for: candidates(in: interfaces), now: Date(),
                                                          fetch: statusJSON))
            }
        }
        guard let address = pickAddress(interfaces: interfaces,
                                        tailscaleIPs: status.flatMap(tailscaleIPs(fromStatusJSON:)))
        else { return nil }
        return TailnetIdentity(address: address, dnsName: status.flatMap(dnsName(fromStatusJSON:)))
    }

    private static let statusCache = TailscaleStatusCache()

    /// The addresses `pickAddress` could choose before the CLI is consulted: tailnet-range
    /// IPv4s on `utun` interfaces. The status cache is keyed on them.
    static func candidates(in interfaces: [(name: String, ipv4: String)]) -> [String] {
        interfaces.filter { $0.name.hasPrefix("utun") && TailnetAccess.isTailnetPeer($0.ipv4) }.map(\.ipv4)
    }

    /// The first address in `100.64.0.0/10` on a `utun` interface. That range is also
    /// carrier-grade NAT, so a match on `en0` and the like is a LAN address and never
    /// counts. When `tailscaleIPs` is known (the CLI answered), the address must be in it.
    static func pickAddress(interfaces: [(name: String, ipv4: String)], tailscaleIPs: [String]?) -> String? {
        interfaces.first { candidate in
            candidate.name.hasPrefix("utun") && TailnetAccess.isTailnetPeer(candidate.ipv4)
                && (tailscaleIPs?.contains(candidate.ipv4) ?? true)
        }?.ipv4
    }

    /// `Self.TailscaleIPs` from `tailscale status --json`.
    static func tailscaleIPs(fromStatusJSON data: Data) -> [String]? {
        struct Status: Decodable {
            struct Me: Decodable { var TailscaleIPs: [String]? }
            var `Self`: Me?
        }
        return (try? JSONDecoder().decode(Status.self, from: data))?.`Self`?.TailscaleIPs
    }

    /// `Self.DNSName` from `tailscale status --json`, lowercased, trailing dot stripped.
    static func dnsName(fromStatusJSON data: Data) -> String? {
        struct Status: Decodable {
            struct Me: Decodable { var DNSName: String? }
            var `Self`: Me?
        }
        guard var name = (try? JSONDecoder().decode(Status.self, from: data))?.`Self`?.DNSName else { return nil }
        while name.hasSuffix(".") { name.removeLast() }
        name = name.lowercased()
        return name.isEmpty ? nil : name
    }

    /// Every interface's IPv4 addresses, in `getifaddrs` order.
    private static func interfaceIPv4s() -> [(name: String, ipv4: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [(name: String, ipv4: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil else { continue }
            let ipv4 = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append((name: String(cString: ptr.pointee.ifa_name), ipv4: ipv4))
        }
        return result
    }

    private static let cliPaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// Blocking; call only from a GCD thread. nil on any failure or after 3 s.
    private static func statusJSON() -> Data? {
        guard let exe = cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Drain stdout concurrently so a large status can't fill the pipe and stall the child.
        final class Box: @unchecked Sendable { var data = Data() }
        let output = Box()
        let reader = DispatchQueue(label: "tailscale.status.read")
        let readDone = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        reader.async {
            output.data = handle.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return nil
        }
        readDone.wait()
        return process.terminationStatus == 0 ? output.data : nil
    }
}

/// The last `tailscale status --json` answer, reused while the tailnet address candidates
/// stay the same and the answer is younger than `maxAge`. No candidates means Tailscale
/// isn't up here, so the CLI isn't run at all. A failed fetch is never cached.
final class TailscaleStatusCache: @unchecked Sendable {
    static let maxAge: TimeInterval = 300

    private let lock = NSLock()
    private var entry: (candidates: [String], status: Data, fetchedAt: Date)?

    /// `fetch` blocks (it runs the CLI), so call this from a GCD thread. The lock isn't
    /// held while fetching.
    func status(for candidates: [String], now: Date, fetch: () -> Data?) -> Data? {
        let key = candidates.sorted()
        guard !key.isEmpty else { return nil }
        let cached = lock.withLock { entry }
        if let cached, cached.candidates == key, now.timeIntervalSince(cached.fetchedAt) < Self.maxAge {
            return cached.status
        }
        guard let fresh = fetch() else { return nil }
        lock.withLock { entry = (key, fresh, now) }
        return fresh
    }
}
