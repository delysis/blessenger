import AVFoundation
import FluidAudio
import class FluidAudio.AudioConverter
import XCTest
@testable import CallGemma

/// Distinguish short-utterance synthesis failures from name-classifier failures.
final class WakeSynthesisProbeTests: XCTestCase {
    func testCarrierComparison() async throws {
        guard let path = ProcessInfo.processInfo.environment["CALL_GEMMA_WAKE_SYNTHESIS_PROBE"] else { throw XCTSkip("Opt-in acoustic training-source inspection") }
        let output = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await AudioModelPins.configure()
        let directory = AudioModelPins.pocketDirectory(in: output)
        try await AudioModelPins.preparePocketCache(at: directory)
        try await AudioModelPins.prepareVoiceEncoder(at: directory)
        let manager = PocketTtsManager(directory: directory, placement: .ane,
            computeUnits: PocketTtsComputeUnits(conditioner: .cpuAndNeuralEngine, flowLM: .cpuAndNeuralEngine,
                flowDecoder: .cpuAndNeuralEngine, mimiDecoder: .cpuOnly, mimiEncoder: .cpuOnly))
        try await manager.initialize()
        let decoder = WakePhonetics()
        var rows: [[String: String]] = []
        for voice in ["gabor_mate", "dolores_mosquera"] {
            let conditioning = try await manager.cloneVoice(from: VoiceSample.read(from: XCTUnwrap(BlessengerResources.voiceURL(voice))))
            for name in ["Gabor", "Peter", "Christine", "Francine"] {
                for text in ["\(name).", "Hey \(name).", "Hello there. \(name), can you help me?"] {
                    let session = try await manager.makeSession(voiceData: conditioning, seed: 90000)
                    session.enqueue(text); session.finish()
                    var samples: [Float] = []
                    do { for try await frame in session.frames { samples.append(contentsOf: frame.samples) }; await session.cancel() }
                    catch { await session.cancel(); throw error }
                    let pcm = try AudioConverter(sampleRate: 16000).resample(samples, from: 24000)
                    let decoded = try await decoder.decode(pcm)
                    let cropped = text.hasPrefix("Hello there.") ? try await decoder.decode(pcm, trainingText: text) : ""
                    let filename = "\(rows.count).wav"
                    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)))
                    buffer.frameLength = AVAudioFrameCount(pcm.count)
                    pcm.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                    var settings = format.settings
                    settings[AVLinearPCMBitDepthKey] = 16; settings[AVLinearPCMIsFloatKey] = false
                    try AVAudioFile(forWriting: output.appending(path: filename), settings: settings).write(from: buffer)
                    rows.append(["voice": voice, "text": text, "decoded": decoded, "path": filename, "cropped": cropped])
                    print("WAKE_SYNTH \(voice): \(text) => \(decoded) | carrier removed: \(cropped)")
                }
            }
        }
        await decoder.close()
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys]).write(to: output.appending(path: "manifest.json"))
    }
}
