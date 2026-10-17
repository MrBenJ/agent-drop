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
}
