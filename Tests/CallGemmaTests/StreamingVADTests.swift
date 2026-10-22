import XCTest
@testable import CallGemma

final class StreamingVADTests: XCTestCase {
    func testRejectedFramesIdentifyTheFailedContract() async throws {
        let vad = try StreamingVAD()
        let epoch = UUID()
        let cases: [([Float], String)] = [
            (Array(repeating: 0, count: 255), "255 samples"),
            ([Float.nan] + Array(repeating: 0, count: 255), "1 non-finite"),
            ([Float.infinity] + Array(repeating: 0, count: 255), "1 non-finite")
        ]
        for (samples, expected) in cases {
            do {
                _ = try await vad.process(samples, epoch: epoch)
                XCTFail("Invalid frame was admitted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
            }
        }
        // A rejected frame must not corrupt the detector's subsequent state.
        let result = try await vad.process(Array(repeating: 0, count: 256), epoch: epoch)
        XCTAssertTrue(result.isFinite && (0...1).contains(result))
    }

    func testLiveOverrangeFrameDoesNotEndOrResetDetection() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "live-vad-overrange", withExtension: "f32"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 256 * MemoryLayout<Float>.size)
        var frame = [Float](repeating: 0, count: 256)
        _ = frame.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        XCTAssertEqual(frame.filter { abs($0) > 1 }.count, 1)
        XCTAssertEqual(frame[224], 1.015946, accuracy: 0.000001)
        let vad = try StreamingVAD(), reference = try StreamingVAD()
        let epoch = UUID()
        // Include both saturation polarities and subsequent quiet frames. The
        // reference receives normalized PCM directly, with continuous state.
        for input in [frame, frame.map { -$0 }, frame, Array(repeating: Float(0), count: 256)] {
            let actual = try await vad.process(input, epoch: epoch)
            let expected = try await reference.process(input.map { min(1, max(-1, $0)) }, epoch: epoch)
            XCTAssertEqual(actual, expected)
        }
    }
}
