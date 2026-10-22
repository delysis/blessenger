#if os(macOS)
import XCTest
@testable import CallGemma

final class CompanionRTCSessionTests: XCTestCase {
    func testOverflowFailsClosedInsteadOfSilentlyLosingSpeech() async {
        let inbox = CompanionRTCInbox(capacity: 2)
        inbox.submit(.audio(Data([1])))
        inbox.submit(.audio(Data([2])))
        XCTAssertFalse(inbox.submit(.audio(Data([3]))))
        XCTAssertThrowsError(try inbox.check())
        inbox.submit(.audio(Data([4])))
        var received = 0
        for await _ in inbox.events { received += 1 }
        XCTAssertEqual(received, 2)
    }

    func testAudioOverflowSignalsIndependentControlQueue() async throws {
        let audio = CompanionRTCInbox(capacity: 1), control = CompanionRTCInbox(capacity: 2)
        XCTAssertTrue(audio.submit(.audio(Data([1]))))
        // No consumer drains audio: simulate suspended model input.
        if !audio.submit(.audio(Data([2]))) { control.submit(.overflow) }
        control.close()
        var signaled = false
        for await event in control.events {
            if case .overflow = event { signaled = true }
        }
        XCTAssertTrue(signaled)
        XCTAssertThrowsError(try audio.check())
    }

    func testClosedInboxRejectsLateNativeCallbacks() async throws {
        let inbox = CompanionRTCInbox()
        inbox.close()
        inbox.submit(.audio(Data(repeating: 0, count: 320)))
        var received = 0
        for await _ in inbox.events { received += 1 }
        XCTAssertEqual(received, 0)
        try inbox.check()
    }

    @MainActor
    func testSessionCloseRejectsSignalingAndControl() async throws {
        let session = try CompanionRTCSession(iceServers: Data("[]".utf8),
            audio: { _ in XCTFail("Unexpected audio") },
            message: { _ in XCTFail("Unexpected message") }, state: { _ in },
            failure: { _ in XCTFail("Explicit close is not a failure") })
        XCTAssertEqual(try session.localCandidates(after: 0).next, 0)
        XCTAssertThrowsError(try session.localCandidates(after: 1))
        session.close(); session.close()
        XCTAssertTrue(session.closed)
        XCTAssertThrowsError(try session.localCandidates(after: 0))
        XCTAssertThrowsError(try session.addCandidate(Data("{}".utf8)))
        XCTAssertThrowsError(try session.send(Data("{}".utf8)))
        do { _ = try await session.answer("v=0\r\n"); XCTFail("Closed session accepted an offer") }
        catch { }
    }
}
#endif
