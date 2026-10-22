import XCTest
import Synchronization
@testable import CallGemma

final class CloudflareTURNTests: XCTestCase {
    func testOnlyProviderRelayURLsAndExpiringCredentialsReachClient() throws {
        let data = Data(#"{"iceServers":[{"urls":["stun:stun.cloudflare.com:3478"]},{"urls":["turn:turn.cloudflare.com:3478?transport=udp","turns:turn.cloudflare.com:443?transport=tcp","turn:turn.cloudflare.com:53?transport=udp","turn:attacker.invalid:3478?transport=udp"],"username":"short-lived","credential":"temporary-secret"}]}"#.utf8)
        let expiry = Date(timeIntervalSince1970: 1000)
        let result = try CloudflareTURN.decode(data, expiresAt: expiry)
        XCTAssertTrue(result.turnConfigured)
        XCTAssertEqual(result.expiresAt, expiry)
        XCTAssertEqual(result.iceServers.count, 2)
        XCTAssertEqual(result.iceServers[1].urls.count, 2)
        XCTAssertEqual(result.iceServers[1].username, "short-lived")
    }
    func testMissingCredentialFailsInsteadOfAdvertisingBrokenRelay() {
        let data = Data(#"{"iceServers":[{"urls":["turn:turn.cloudflare.com:3478?transport=udp"]}]}"#.utf8)
        XCTAssertThrowsError(try CloudflareTURN.decode(data, expiresAt: Date()))
    }
    func testUnusableRelayFailsInsteadOfSilentlyDowngrading() {
        let data = Data(#"{"iceServers":[{"urls":["turn:turn.cloudflare.com:53?transport=udp"],"username":"u","credential":"c"}]}"#.utf8)
        XCTAssertThrowsError(try CloudflareTURN.decode(data, expiresAt: Date()))
    }

    func testKeyReadOnceAndCredentialsRefreshOnlyNearExpiry() async throws {
        let fixture = TURNCacheFixture()
        let cache = fixture.cache()
        for _ in 0..<5 { _ = try await cache.generate() }
        XCTAssertEqual(fixture.counts, [1, 1])
        fixture.advance(3541)
        _ = try await cache.generate()
        XCTAssertEqual(fixture.counts, [1, 2])
    }
    func testProviderFailureDoesNotRereadKeychainOnRetry() async throws {
        let counts = Mutex([0, 0])
        let cache = CloudflareTURNCredentialCache(load: {
            counts.withLock { $0[0] += 1 }
            return .init(id: "fixture", token: "test-token")
        }, issue: { _ in
            let attempt = counts.withLock { $0[1] += 1; return $0[1] }
            if attempt == 1 { throw NSError(domain: "fixture", code: 1) }
            return .init(iceServers: [], expiresAt: Date().addingTimeInterval(3600), turnConfigured: true)
        })
        do { _ = try await cache.generate(); XCTFail("Expected provider failure") } catch {}
        _ = try await cache.generate()
        XCTAssertEqual(counts.withLock { $0 }, [1, 2])
    }
    func testConcurrentCallsShareOneRefresh() async throws {
        let fixture = TURNCacheFixture()
        let cache = fixture.cache()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await cache.generate() } }
            try await group.waitForAll()
        }
        XCTAssertEqual(fixture.counts, [1, 1])
    }
}

private final class TURNCacheFixture: Sendable {
    private struct State { var reads = 0; var issues = 0; var time: TimeInterval = 1000 }
    private let state = Mutex(State())
    var counts: [Int] { state.withLock { [$0.reads, $0.issues] } }
    func advance(_ seconds: TimeInterval) { state.withLock { $0.time += seconds } }
    func cache() -> CloudflareTURNCredentialCache {
        CloudflareTURNCredentialCache(load: { [self] in
            state.withLock { $0.reads += 1 }
            return .init(id: "fixture", token: "test-token")
        }, issue: { [self] _ in
            let expiry = state.withLock { $0.issues += 1; return Date(timeIntervalSince1970: $0.time + 3600) }
            try await Task.sleep(for: .milliseconds(20))
            return .init(iceServers: [CloudflareTURN.stun], expiresAt: expiry, turnConfigured: true)
        }, now: { [self] in state.withLock { Date(timeIntervalSince1970: $0.time) } })
    }
}
