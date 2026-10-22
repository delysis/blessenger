import XCTest
@testable import CallGemma

@MainActor
final class RemoteCallTransportTests: XCTestCase {
    func testRenderControlDrainsDuringSuspendedAudioInput() async throws {
        let transport = RemoteCallTransport(echoCancellation: true)
        var release: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "input consumer entered")
        transport.input = { _ in
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        var completed = 0
        try transport.enqueue([0.1]) { completed += 1 }
        let capture = Task { try await transport.receiveAudio(sequence: 0, samples: [0.2]) }
        await fulfillment(of: [entered], timeout: 2)
        defer { release?.resume(); transport.close() }
        _ = try transport.acknowledgePlayback([0], epoch: transport.epoch)
        XCTAssertEqual(completed, 1, "Model input must not block render receipts")
        do {
            try await transport.receiveAudio(sequence: 1, samples: [0.3])
            XCTFail("Concurrent input must stay bounded")
        } catch {}
        release?.resume(); release = nil
        try await capture.value
        transport.input = { _ in }
        try await transport.receiveAudio(sequence: 1, samples: [0.4])
        transport.close()
        XCTAssertThrowsError(try transport.acknowledgePlayback([], epoch: transport.epoch))
    }

    func testRenderAcknowledgementAndCancellationEpoch() async throws {
        let transport = RemoteCallTransport(echoCancellation: true)
        var completed = 0
        try transport.enqueue([0.1, 0.2]) { completed += 1 }
        let first = try await transport.exchange(sequence: 0, samples: [], acknowledged: [], epoch: transport.epoch)
        XCTAssertEqual((first["packets"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(completed, 0, "HTTP delivery does not mean audio was rendered")
        let oldEpoch = transport.epoch
        transport.cancelPlayback()
        try transport.enqueue([0.3]) { completed += 10 }
        _ = try await transport.exchange(sequence: 1, samples: [], acknowledged: [0], epoch: oldEpoch)
        XCTAssertEqual(completed, 0, "Old renderer acknowledgements cannot commit the new reply")
        _ = try await transport.exchange(sequence: 2, samples: [], acknowledged: [1], epoch: transport.epoch)
        XCTAssertEqual(completed, 10)
        transport.close()
    }
    func testBoundedQueueAndInputOrder() async throws {
        let transport = RemoteCallTransport(echoCancellation: false)
        for _ in 0..<8 { try transport.enqueue([0]) {} }
        XCTAssertThrowsError(try transport.enqueue([0]) {})
        do {
            _ = try await transport.exchange(sequence: 1, samples: [], acknowledged: [], epoch: transport.epoch)
            XCTFail("Skipped input accepted")
        } catch {}
        var received: [Float] = []
        transport.input = { received += $0 }
        _ = try await transport.exchange(sequence: 0, samples: [0.2], acknowledged: [0], epoch: transport.epoch)
        XCTAssertEqual(received, [0.2])
        do {
            _ = try await transport.exchange(sequence: 0, samples: [0.3], acknowledged: [], epoch: transport.epoch)
            XCTFail("Duplicate input accepted")
        } catch {}
        XCTAssertEqual(received, [0.2])
        transport.close()
    }
    func testRejectedAcknowledgementBatchDoesNotPartiallyCommit() async throws {
        let transport = RemoteCallTransport(echoCancellation: true)
        var completed: [Int] = []
        var captured: [Float] = []
        transport.input = { captured += $0 }
        for index in 0..<3 { try transport.enqueue([0]) { completed.append(index) } }
        for malformed in [[0, 2], [0, 0], [0, 1, 2, 3]] {
            do {
                _ = try await transport.exchange(sequence: 0, samples: [0.5], acknowledged: malformed, epoch: transport.epoch)
                XCTFail("Malformed batch accepted")
            } catch {}
            XCTAssertEqual(completed, [], "Rejected requests cannot commit a valid prefix")
            XCTAssertEqual(captured, [], "Rejected requests cannot feed model audio")
        }
        // The rejected requests must not consume the sequence number either.
        _ = try await transport.exchange(sequence: 0, samples: [0.5], acknowledged: [0, 1, 2], epoch: transport.epoch)
        XCTAssertEqual(completed, [0, 1, 2])
        XCTAssertEqual(captured, [0.5])
        transport.close()
    }

}
