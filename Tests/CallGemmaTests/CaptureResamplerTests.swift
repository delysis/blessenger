import AVFoundation
import XCTest
import os
@testable import CallGemma

final class CaptureResamplerTests: XCTestCase {
    func testCapturePoolConcurrentReturnsDoNotReportFalseExhaustion() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pool = try CaptureBufferPool(format: format)
        let active = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<2_000 {
                guard let buffer = pool.take() else {
                    XCTFail("Pool reported exhaustion with at most eight of 32 leases in use.")
                    return
                }
                let id = ObjectIdentifier(buffer)
                XCTAssertTrue(active.withLock { $0.insert(id).inserted }, "Two owners received the same PCM buffer.")
                buffer.frameLength = 512
                buffer.floatChannelData?[0][0] = 0.25
                XCTAssertTrue(active.withLock { $0.remove(id) != nil })
                pool.recycle(buffer)
            }
        }
        var held: [AVAudioPCMBuffer] = []
        for _ in 0..<32 { held.append(try XCTUnwrap(pool.take())) }
        XCTAssertNil(pool.take(), "Actual exhaustion must still fail rather than overwrite live PCM.")
        pool.recycle(held.removeLast())
        held.append(try XCTUnwrap(pool.take()))
        for buffer in held { pool.recycle(buffer) }
    }


    func testAggregateMicrophoneChannelSurvivesResampling() async throws {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 9,
            mBitsPerChannel: 32, mReserved: 0)
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &description,
            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9)))
        let resampler = CaptureResampler()
        var result: [Float] = []
        for block in 0..<48 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_000))
            buffer.frameLength = 1_000
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<9 {
                for frame in 0..<1_000 {
                    // A microphone signal on channel zero; other aggregate channels
                    // must neither erase it nor leak their opposite-polarity signal.
                    let signal = Float(sin(Double(block * 1_000 + frame) * 2 * .pi * 440 / 48_000)) * 0.2
                    channels[channel][frame] = channel == 0 ? signal : -signal
                }
            }
            result += try await resampler.process(CapturedBuffer(pcm: buffer))
        }
        XCTAssertEqual(Double(result.count), 16_000, accuracy: 64)
        let rms = sqrt(result.reduce(Float(0)) { $0 + $1 * $1 } / Float(result.count))
        XCTAssertEqual(rms, 0.2 / sqrt(2), accuracy: 0.005)
        // Allow the resampler's filter delay while checking the retained frequency.
        let steady = result.enumerated().dropFirst(100)
        let sine = steady.reduce(0.0) {
            $0 + Double($1.element) * sin(Double($1.offset) * 2 * .pi * 440 / 16_000)
        }
        let cosine = steady.reduce(0.0) {
            $0 + Double($1.element) * cos(Double($1.offset) * 2 * .pi * 440 / 16_000)
        }
        XCTAssertEqual(2 * hypot(sine, cosine) / Double(result.count - 100), 0.2, accuracy: 0.005)
    }
}
