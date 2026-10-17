import Foundation
import Testing
@testable import AgentDropServer

struct TailnetIdentityTests {
    @Test(arguments: ["100.64.0.1", "100.85.64.112", "100.127.255.255"])
    func tailnetPeers(ip: String) {
        #expect(TailnetAccess.isTailnetPeer(ip))
    }

    @Test(arguments: ["100.63.255.255", "100.128.0.0", "127.0.0.1", "10.0.0.1", "not-an-ip", ""])
    func nonTailnetPeers(ip: String) {
        #expect(!TailnetAccess.isTailnetPeer(ip))
    }

    @Test func allowedHostsCoversIpFqdnAndShortName() {
        let id = TailnetIdentity(address: "100.85.64.112", dnsName: "bens-macbook-pro.tail07da74.ts.net")
        #expect(id.allowedHosts(port: 47400) == [
            "100.85.64.112:47400", "bens-macbook-pro.tail07da74.ts.net:47400", "bens-macbook-pro:47400",
        ])
        #expect(id.preferredHost == "bens-macbook-pro.tail07da74.ts.net")
    }

    @Test func allowedHostsWithoutDNSIsJustTheIP() {
        let id = TailnetIdentity(address: "100.85.64.112", dnsName: nil)
        #expect(id.allowedHosts(port: 47400) == ["100.85.64.112:47400"])
        #expect(id.preferredHost == "100.85.64.112")
    }

    @Test func dnsNameParsesStatusJSON() {
        let json = Data(#"{"Self":{"DNSName":"Bens-MacBook-Pro.tail07da74.ts.net.","HostName":"x"}}"#.utf8)
        #expect(TailnetLocator.dnsName(fromStatusJSON: json) == "bens-macbook-pro.tail07da74.ts.net")
        #expect(TailnetLocator.dnsName(fromStatusJSON: Data("nope".utf8)) == nil)
        #expect(TailnetLocator.dnsName(fromStatusJSON: Data(#"{"Self":{}}"#.utf8)) == nil)
    }

    @Test func pickAddressIgnoresCGNATOnNonUtunInterfaces() {
        let interfaces = [(name: "en0", ipv4: "100.72.1.5"), (name: "lo0", ipv4: "127.0.0.1")]
        #expect(TailnetLocator.pickAddress(interfaces: interfaces, tailscaleIPs: nil) == nil)
        #expect(TailnetLocator.pickAddress(interfaces: interfaces, tailscaleIPs: ["100.72.1.5"]) == nil)
    }

    @Test func pickAddressChoosesTheUtunTailnetAddress() {
        let interfaces = [(name: "en0", ipv4: "100.72.1.5"), (name: "utun3", ipv4: "10.0.0.2"),
                          (name: "utun4", ipv4: "100.85.64.112")]
        #expect(TailnetLocator.pickAddress(interfaces: interfaces, tailscaleIPs: nil) == "100.85.64.112")
        #expect(TailnetLocator.pickAddress(interfaces: interfaces, tailscaleIPs: ["100.85.64.112", "fd7a::1"])
            == "100.85.64.112")
    }

    @Test func pickAddressRejectsUtunAddressNotInTailscaleIPs() {
        let interfaces = [(name: "utun2", ipv4: "100.100.1.1"), (name: "utun4", ipv4: "100.85.64.112")]
        #expect(TailnetLocator.pickAddress(interfaces: interfaces, tailscaleIPs: ["100.85.64.112"]) == "100.85.64.112")
        #expect(TailnetLocator.pickAddress(interfaces: [(name: "utun2", ipv4: "100.100.1.1")],
                                           tailscaleIPs: ["100.85.64.112"]) == nil)
    }

    @Test func tailscaleIPsParseStatusJSON() {
        let json = Data(#"{"Self":{"DNSName":"x.ts.net.","TailscaleIPs":["100.85.64.112","fd7a:115c::1"]}}"#.utf8)
        #expect(TailnetLocator.tailscaleIPs(fromStatusJSON: json) == ["100.85.64.112", "fd7a:115c::1"])
        #expect(TailnetLocator.tailscaleIPs(fromStatusJSON: Data(#"{"Self":{}}"#.utf8)) == nil)
        #expect(TailnetLocator.tailscaleIPs(fromStatusJSON: Data("nope".utf8)) == nil)
    }
}
