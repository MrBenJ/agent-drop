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

    /// The first tailnet IPv4 on any interface, plus the DNS name from `tailscale status --json`.
    public static let live = TailnetLocator {
        guard let address = firstTailnetAddress() else { return nil }
        let name = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            // A GCD thread, not the cooperative pool: the subprocess wait blocks.
            DispatchQueue.global().async {
                cont.resume(returning: statusJSON().flatMap(dnsName(fromStatusJSON:)))
            }
        }
        return TailnetIdentity(address: address, dnsName: name)
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

    private static func firstTailnetAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            guard TailnetAccess.isTailnet(UInt32(bigEndian: sin.sin_addr.s_addr)) else { continue }
            var addr = sin.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil else { continue }
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
    }

    private static let candidates = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// Blocking; call only from a GCD thread. nil on any failure or after 3 s.
    private static func statusJSON() -> Data? {
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
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
