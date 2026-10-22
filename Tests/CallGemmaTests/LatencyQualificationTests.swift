import AVFoundation
import FluidAudio
import Foundation
import XCTest
@testable import CallGemma

/// Component timings. These are not substitutes for acoustic end-to-end measurements.
final class LatencyQualificationTests: XCTestCase {
    func testConversionTimingAndSignalDelay() async throws {
        for rate in [48_000.0, 24_000.0, 16_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: rate, channels: 1, interleaved: false))
            let converter = CaptureResampler()
            var times: [Double] = []
            var outputCount = 0
            let frames = Int(rate / 100) // 10 ms input chunks.
            for block in 0..<210 {
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
                pcm.frameLength = UInt32(frames)
                for frame in 0..<frames {
                    pcm.floatChannelData![0][frame] = Float(sin(Double(block * frames + frame) * 2 * .pi * 440 / rate)) * 0.2
                }
                let start = LatencyTrace.now()
                let samples = try await converter.process(CapturedBuffer(pcm: pcm))
                let duration = Double(LatencyTrace.now() - start) / 1e6
                if block >= 10 { times.append(duration) }
                outputCount += samples.count
            }
            let sorted = times.sorted()
            print("LATENCY conversion rate=\(rate) chunk_ms=10 n=\(times.count) p50_ms=\(sorted[100]) p95_ms=\(sorted[190]) output_samples=\(outputCount)")
            XCTAssertEqual(Double(outputCount), 210 * 160, accuracy: 64)
        }
    }

    func testFixedSpeechEndpointTiming() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = try AVAudioFile(forReading: root.appending(path: "Qualification/Fixtures/question.wav"))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
        try file.read(into: pcm)
        let speech = Array(UnsafeBufferPointer(start: try XCTUnwrap(pcm.floatChannelData)[0], count: Int(pcm.frameLength)))
        let manager = try await VadManager(config: VadConfig(defaultThreshold: 0.65, computeUnits: .cpuOnly),
                                           modelDirectory: AudioModelPins.prepareVAD())
        for silence in [0.5, 0.25] {
            var state = VadStreamState.initial()
            let input = [Float](repeating: 0, count: 16_000) + speech + [Float](repeating: 0, count: 32_000)
            var inference: [Double] = []
            var starts: [Int] = [], ends: [Int] = []
            for offset in stride(from: 0, through: input.count - VadManager.chunkSize, by: VadManager.chunkSize) {
                let start = LatencyTrace.now()
                let result = try await manager.processStreamingChunk(Array(input[offset..<offset + VadManager.chunkSize]),
                    state: state, config: VadSegmentationConfig(minSilenceDuration: silence, maxSpeechDuration: 30))
                inference.append(Double(LatencyTrace.now() - start) / 1e6)
                state = result.state
                if result.event?.isStart == true { starts.append(offset + VadManager.chunkSize) }
                if result.event?.isEnd == true { ends.append(offset + VadManager.chunkSize) }
            }
            let sorted = inference.dropFirst().sorted()
            print("LATENCY vad silence_s=\(silence) inference_p50_ms=\(sorted[sorted.count/2]) inference_p95_ms=\(sorted[Int(Double(sorted.count)*0.95)]) start_delivery_samples=\(starts) end_delivery_samples=\(ends) file_end_samples=\(16000+speech.count)")
            XCTAssertFalse(starts.isEmpty)
            XCTAssertEqual(starts.count, ends.count)
        }
    }
}
