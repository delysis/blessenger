#if os(macOS)
import XCTest
@testable import CallGemma

final class CompanionRTCCallTests: XCTestCase {
    @MainActor
    func testClosedConnectionCannotBeAdmittedAndClosesOnce() throws {
        var closes = 0
        let connection = try CompanionRTCCall(iceServers: Data("[]".utf8), echoCancellation: true) { closes += 1 }
        XCTAssertFalse(connection.admitted)
        connection.close(); connection.close()
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(connection.transport.closed)
        XCTAssertThrowsError(try connection.start())
        XCTAssertThrowsError(try connection.signal(cursor: 0, candidates: []))
    }

    @MainActor
    func testSingleAdmissionAndCandidateCursorValidation() throws {
        let connection = try CompanionRTCCall(iceServers: Data("[]".utf8), echoCancellation: true) { }
        defer { connection.close() }
        XCTAssertThrowsError(try connection.signal(cursor: -1, candidates: []))
        XCTAssertEqual(try connection.signal(cursor: 0, candidates: [])["cursor"] as? Int, 0)
        try connection.start()
        XCTAssertThrowsError(try connection.start())
        // Only successful engine admission transfers hang-up ownership.
        XCTAssertFalse(connection.admitted)
        connection.didDial()
        XCTAssertTrue(connection.admitted)
    }

    func testPCMLeadIsSplitAndNotResentByHeartbeats() throws {
        var output = CompanionRTCOutput()
        let packets = (0..<8).map { ["sequence": $0, "samples": Array(repeating: 0.1, count: 1920)] as [String: Any] }
        let snapshot: [String: Any] = ["id": "call", "epoch": "first", "packets": packets]
        let messages = try output.messages(snapshot)
        XCTAssertEqual(messages.count, 8)
        XCTAssertTrue(messages.allSatisfy { $0.count <= 65_536 })
        for data in messages {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((value["packets"] as? [Any])?.count, 1)
        }
        let heartbeat = try output.messages(snapshot)
        XCTAssertEqual(heartbeat.count, 1)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: heartbeat[0]) as? [String: Any])
        XCTAssertEqual((value["packets"] as? [Any])?.count, 0)
        XCTAssertEqual(try output.messages(["id": "call", "epoch": "second", "packets": packets]).count, 8)
    }

    @MainActor
    func testLimitedSnapshotsDoNotAcknowledgeUnheardOutput() throws {
        let transport = RemoteCallTransport(echoCancellation: true)
        var completed: [Int] = []
        try transport.enqueue([0.1]) { completed.append(0) }
        try transport.enqueue([0.2]) { completed.append(1) }
        let first = try transport.acknowledgePlayback([], epoch: transport.epoch, limit: 1)
        XCTAssertEqual((first["packets"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(completed, [])
        let second = try transport.acknowledgePlayback([0], epoch: transport.epoch, limit: 1)
        XCTAssertEqual((second["packets"] as? [[String: Any]])?.first?["sequence"] as? Int, 1)
        XCTAssertEqual(completed, [0])
        transport.cancelPlayback()
        XCTAssertEqual(completed, [0])
    }
}
#endif
