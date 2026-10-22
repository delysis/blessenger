import AVFoundation
import FluidAudio
import Foundation
import XCTest
@testable import CallGemma

/// Resource screen only; this does not qualify word-boundary accuracy.
final class AlignmentQualificationTests: XCTestCase {
    func testPocketSeedReplay() async throws {
        guard let output = ProcessInfo.processInfo.environment["CALL_GEMMA_SEED_RECEIPT"] else {
            throw XCTSkip("Opt-in cross-process synthesis replay")
        }
        await AudioModelPins.configure()
        let directory = AudioModelPins.pocketDirectory(in: URL(fileURLWithPath: output))
        try await AudioModelPins.preparePocketCache(at: directory)
        let cpuOnly = ProcessInfo.processInfo.environment["CALL_GEMMA_SEED_CPU"] == "1"
        let units = cpuOnly ? PocketTtsComputeUnits.uniform(.cpuOnly) :
            PocketTtsComputeUnits(conditioner: .cpuAndNeuralEngine,
                flowLM: .cpuAndNeuralEngine, flowDecoder: .cpuAndNeuralEngine,
                mimiDecoder: .cpuOnly, mimiEncoder: .cpuOnly)
        let manager = PocketTtsManager(directory: directory, placement: .ane, computeUnits: units)
        try await manager.initialize()
        let text = ProcessInfo.processInfo.environment["CALL_GEMMA_SEED_TEXT"]
            ?? "The yellow bird flew over the quiet garden."
        let voice: PocketTtsVoiceData?
        if let file = ProcessInfo.processInfo.environment["CALL_GEMMA_SEED_VOICE"] {
            try await AudioModelPins.prepareVoiceEncoder(at: directory)
            voice = try await manager.cloneVoice(from: VoiceSample.read(from: URL(fileURLWithPath: file)))
        } else { voice = nil }
        if let voice,
           let destination = ProcessInfo.processInfo.environment["CALL_GEMMA_SEED_VOICE_EMBEDDING"] {
            try voice.audioPrompt.withUnsafeBytes { Data($0) }
                .write(to: URL(fileURLWithPath: destination), options: .withoutOverwriting)
            print("POCKET_VOICE frames=\(voice.promptLength) floats=\(voice.audioPrompt.count)")
        }
        var first: Data?
        for pass in 0..<2 {
            let started = DispatchTime.now().uptimeNanoseconds
            let session: PocketTtsSession
            if let voice { session = try await manager.makeSession(voiceData: voice, seed: 42) }
            else { session = try await manager.makeSession(seed: 42) }
            session.enqueue(text)
            session.finish()
            var samples: [Float] = []
            var firstPCM: UInt64?
            for try await frame in session.frames {
                if firstPCM == nil { firstPCM = DispatchTime.now().uptimeNanoseconds }
                samples.append(contentsOf: frame.samples)
            }
            let ended = DispatchTime.now().uptimeNanoseconds
            print("POCKET_TIMING pass=\(pass) first_ms=\(Double((firstPCM ?? ended)-started)/1e6) total_ms=\(Double(ended-started)/1e6)")
            await session.cancel()
            let data = samples.withUnsafeBytes { Data($0) }
            XCTAssertFalse(data.isEmpty)
            if let first { XCTAssertEqual(data, first, "Seed replay changed PCM within this process") }
            else { first = data }
            print("POCKET_SEED pass=\(pass) samples=\(samples.count) sha256=\(digest(data))")
        }
        let receipt = URL(fileURLWithPath: output)
        let data = try XCTUnwrap(first)
        if FileManager.default.fileExists(atPath: receipt.path) {
            XCTAssertEqual(data, try Data(contentsOf: receipt), "Seed replay changed PCM across processes")
        } else {
            try data.write(to: receipt, options: .withoutOverwriting)
        }
    }

    func testPocketSpeechAlignment() async throws {
        guard let root = ProcessInfo.processInfo.environment["CALL_GEMMA_ALIGNMENT_MODEL"],
              ProcessInfo.processInfo.environment["CALL_GEMMA_ALIGN_POCKET"] == "1" else {
            throw XCTSkip("Opt-in PocketTTS alignment fixture")
        }
        await AudioModelPins.configure()
        let directory = AudioModelPins.pocketDirectory(in: URL(fileURLWithPath: root))
        try await AudioModelPins.preparePocketCache(at: directory)
        let manager = PocketTtsManager(directory: directory, placement: .ane,
            computeUnits: PocketTtsComputeUnits(conditioner: .cpuAndNeuralEngine,
                flowLM: .cpuAndNeuralEngine, flowDecoder: .cpuAndNeuralEngine,
                mimiDecoder: .cpuOnly, mimiEncoder: .cpuOnly))
        try await manager.initialize()
        let text = "The yellow bird flew over the quiet garden."
        let session = try await manager.makeSession(seed: 0)
        session.enqueue(text)
        session.finish()
        var samples: [Float] = []
        for try await frame in session.frames { samples.append(contentsOf: frame.samples) }
        await session.cancel()
        XCTAssertFalse(samples.isEmpty)
        let aligner = HeardTextAlignment()
        let start = DispatchTime.now().uptimeNanoseconds
        let words = try await aligner.words(text: text, referencePCM: samples, sampleRate: 24_000,
                                            modelDirectory: URL(fileURLWithPath: root))
        XCTAssertEqual(words.count, 8)
        XCTAssertTrue(zip(words, words.dropFirst()).allSatisfy { $0.endSeconds <= $1.endSeconds })
        XCTAssertLessThanOrEqual(words.last!.endSeconds, Double(samples.count) / 24_000 + 0.1)
        print("POCKET_ALIGNMENT ms=\(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6) audio_s=\(Double(samples.count)/24_000)")
        for word in words {
            print("POCKET_WORD end_s=\(word.endSeconds) prefix=\(text[..<word.textEnd])")
        }
        // Structural checks only. Printed boundaries need independent acoustic
        // review; forced alignment by itself is not a correctness oracle.

        // An independent, deliberately segmented fixture: each word's entire
        // synthesis falls inside a known PCM interval. Cuts in the intervening
        // silence must retain exactly the preceding words.
        let vocabulary = ["yellow", "garden", "purple", "window"]
        var separated: [Float] = []
        var bounds: [(Double, Double)] = []
        for word in vocabulary {
            separated.append(contentsOf: [Float](repeating: 0, count: 6_000))
            let start = Double(separated.count) / 24_000
            let wordSession = try await manager.makeSession(seed: 0)
            wordSession.enqueue(word)
            wordSession.finish()
            for try await frame in wordSession.frames { separated.append(contentsOf: frame.samples) }
            await wordSession.cancel()
            bounds.append((start, Double(separated.count) / 24_000))
        }
        separated.append(contentsOf: [Float](repeating: 0, count: 6_000))
        let separatedText = vocabulary.joined(separator: " ")
        if let output = ProcessInfo.processInfo.environment["CALL_GEMMA_ALIGNMENT_OUTPUT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try separated.withUnsafeBytes { Data($0) }.write(to: directory.appending(path: "separated.f32"))
            try samples.withUnsafeBytes { Data($0) }.write(to: directory.appending(path: "sentence.f32"))
            let manifest: [String: Any] = ["sample_rate": 24_000, "sentence": text,
                "separated": separatedText, "bounds": bounds.map { [$0.0, $0.1] },
                "voice": "alba", "seed": 0, "pocket_revision": AudioModelPins.pocket]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appending(path: "fixture.json"))
        }
        let separatedWords = try await aligner.words(text: separatedText, referencePCM: separated,
            sampleRate: 24_000, modelDirectory: URL(fileURLWithPath: root))
        XCTAssertEqual(separatedWords.count, vocabulary.count)
        for (index, word) in separatedWords.enumerated() {
            XCTAssertGreaterThanOrEqual(word.endSeconds, bounds[index].0)
            XCTAssertLessThanOrEqual(word.endSeconds, bounds[index].1 + 0.08)
            let retained = HeardTextAlignment.prefix(text: separatedText, words: separatedWords,
                                                      playedSeconds: bounds[index].1 + 0.1)
            XCTAssertEqual(retained, vocabulary.prefix(index + 1).joined(separator: " "))
            print("POCKET_CUT seconds=\(bounds[index].1 + 0.1) retained=\(retained)")

        }
    }

    func testCTCResourceScreen() async throws {
        guard let root = ProcessInfo.processInfo.environment["CALL_GEMMA_CTC_SCREEN_MODEL"],
              let fixture = ProcessInfo.processInfo.environment["CALL_GEMMA_ALIGNMENT_AUDIO"] else {
            throw XCTSkip("Set alignment model and audio fixture for resource screening")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixture))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let baseline = PeakMemoryRecorder().stop()
        let memory = PeakMemoryRecorder()
        let load = DispatchTime.now().uptimeNanoseconds
        let models = try await CtcModels.loadDirect(from: URL(fileURLWithPath: root))
        print("ALIGNMENT load_ms=\(Double(DispatchTime.now().uptimeNanoseconds-load)/1e6)")
        let spotter = CtcKeywordSpotter(models: models)
        for pass in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try await spotter.spotKeywordsWithLogProbs(audioSamples: pcm,
                customVocabulary: CustomVocabularyContext(terms: []))
            XCTAssertFalse(result.logProbs.isEmpty)
            print("ALIGNMENT pass=\(pass) ms=\(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6) frames=\(result.totalFrames) frame_seconds=\(result.frameDuration)")
        }
        print("ALIGNMENT baseline=\(baseline) peak=\(memory.stop())")
    }
}
