#if os(macOS)
import XCTest
import CompanionRTC
import WebRTC
@testable import CallGemma

final class CompanionRTCLinkTests: XCTestCase {
    func testPackagedPeerConstructionAndRepeatedClose() throws {
        // Exercise the linked binary and custom device, without microphone,
        // speaker, signaling, or a network connection.
        for _ in 0..<3 {
            let peer = try BGCompanionPeer(iceServers: Data("[]".utf8), relayOnly: false,
                message: { _ in }, audio: { _ in }, candidate: { _ in }, state: { _ in })
            peer.close()
            peer.close()
            XCTAssertFalse(peer.sendMessage(Data("closed".utf8)))
        }
    }

    @MainActor
    func testCandidateCallbackFromNativeQueue() async throws {
        let delivered = expectation(description: "Native candidate callback")
        let inbox = CompanionRTCInbox(capacity: 4)
        let peer = try BGCompanionPeer(iceServers: Data("[]".utf8), relayOnly: false,
            message: { _ in }, audio: { _ in }, candidate: { data in
                inbox.submit(.candidate(data)); delivered.fulfill()
            }, state: { _ in })
        defer { peer.close(); inbox.close() }
        let candidate = RTCIceCandidate(sdp: "candidate:1 1 UDP 1 192.0.2.1 12345 typ host", sdpMLineIndex: 0, sdpMid: "0")
        // Invoke the same Objective-C delegate entry WebRTC uses. It dispatches
        // onto the native candidate queue, exercising the Swift actor boundary.
        _ = peer.perform(NSSelectorFromString("peerConnection:didGenerateIceCandidate:"), with: nil, with: candidate)
        await fulfillment(of: [delivered], timeout: 2)
        try inbox.check()
    }

    func testMalformedConfigurationRejectedBeforePeerCreation() {
        XCTAssertThrowsError(try BGCompanionPeer(iceServers: Data("{}".utf8), relayOnly: false,
            message: { _ in }, audio: { _ in }, candidate: { _ in }, state: { _ in }))
    }

    func testTrickleCandidateAdmissionIsBoundedBeforeOffer() throws {
        let peer = try BGCompanionPeer(iceServers: Data("[]".utf8), relayOnly: false,
            message: { _ in }, audio: { _ in }, candidate: { _ in }, state: { _ in })
        defer { peer.close() }
        func packet(line: Int = 0) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "candidate": "candidate:1 1 UDP 1 192.0.2.1 12345 typ host",
                "sdpMid": "0", "sdpMLineIndex": line])
        }
        XCTAssertFalse(peer.addRemoteCandidate(Data("[]".utf8)))
        XCTAssertFalse(peer.addRemoteCandidate(try packet(line: -1)))
        XCTAssertFalse(peer.addRemoteCandidate(Data(repeating: 32, count: 16_385)))
        for _ in 0..<64 { XCTAssertTrue(peer.addRemoteCandidate(try packet())) }
        XCTAssertFalse(peer.addRemoteCandidate(try packet()))
        peer.close()
        XCTAssertFalse(peer.addRemoteCandidate(try packet()))
    }
}
#endif
