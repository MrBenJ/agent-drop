import Foundation
import Testing
@testable import AgentDropServer

/// The service polls every 10 s; `tailscale status --json` should only run when the
/// tailnet address changes or the cached answer is old.
struct TailscaleStatusCacheTests {
    private let status = Data(#"{"Self":{"DNSName":"laptop.tail-test.ts.net."}}"#.utf8)
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    /// Counts calls to the fake `tailscale status`.
    private final class Fetcher: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Data?]
        private(set) var calls = 0

        init(_ answers: [Data?]) { self.answers = answers }

        func fetch() -> Data? {
            lock.withLock {
                calls += 1
                return answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
            }
        }
    }

    @Test func fetchesOnceWhileTheAddressStaysTheSame() {
        let cache = TailscaleStatusCache()
        let fetcher = Fetcher([status])
        for step in 0..<5 {
            let got = cache.status(for: ["100.85.64.112"], now: start + Double(step) * 10, fetch: fetcher.fetch)
            #expect(got == status)
        }
        #expect(fetcher.calls == 1)
    }

    @Test func refetchesWhenTheAddressChanges() {
        let cache = TailscaleStatusCache()
        let fetcher = Fetcher([status])
        _ = cache.status(for: ["100.85.64.112"], now: start, fetch: fetcher.fetch)
        _ = cache.status(for: ["100.85.64.113"], now: start + 10, fetch: fetcher.fetch)
        #expect(fetcher.calls == 2)
    }

    @Test func refetchesOnceTheAnswerIsOld() {
        let cache = TailscaleStatusCache()
        let fetcher = Fetcher([status])
        _ = cache.status(for: ["100.85.64.112"], now: start, fetch: fetcher.fetch)
        _ = cache.status(for: ["100.85.64.112"], now: start + TailscaleStatusCache.maxAge - 1, fetch: fetcher.fetch)
        #expect(fetcher.calls == 1)
        _ = cache.status(for: ["100.85.64.112"], now: start + TailscaleStatusCache.maxAge, fetch: fetcher.fetch)
        #expect(fetcher.calls == 2)
    }

    @Test func noTailnetAddressMeansNoFetch() {
        let cache = TailscaleStatusCache()
        let fetcher = Fetcher([status])
        #expect(cache.status(for: [], now: start, fetch: fetcher.fetch) == nil)
        #expect(fetcher.calls == 0)
    }

    @Test func aFailedFetchIsRetriedOnTheNextPoll() {
        let cache = TailscaleStatusCache()
        let fetcher = Fetcher([nil, status])
        #expect(cache.status(for: ["100.85.64.112"], now: start, fetch: fetcher.fetch) == nil)
        #expect(cache.status(for: ["100.85.64.112"], now: start + 10, fetch: fetcher.fetch) == status)
        #expect(cache.status(for: ["100.85.64.112"], now: start + 20, fetch: fetcher.fetch) == status)
        #expect(fetcher.calls == 2)
    }

    @Test func candidateOrderDoesNotMatter() {
        let cache = TailscaleStatusCache()
        let fetcher = Fetcher([status])
        _ = cache.status(for: ["100.85.64.112", "100.85.64.113"], now: start, fetch: fetcher.fetch)
        _ = cache.status(for: ["100.85.64.113", "100.85.64.112"], now: start + 10, fetch: fetcher.fetch)
        #expect(fetcher.calls == 1)
    }

    @Test func candidatesAreUtunTailnetAddressesOnly() {
        let interfaces = [(name: "en0", ipv4: "100.70.0.5"), (name: "utun3", ipv4: "100.85.64.112"),
                          (name: "utun4", ipv4: "10.0.0.2"), (name: "lo0", ipv4: "127.0.0.1")]
        #expect(TailnetLocator.candidates(in: interfaces) == ["100.85.64.112"])
    }
}
