import Foundation
import FluidAudio
import class FluidAudio.AudioConverter
import XCTest
@testable import CallGemma

/// Opt-in data preparation, never run in a call or against user contact storage.
final class WakeCorpusQualificationTests: XCTestCase {
    struct Row: Codable {
        let path: String
        let source: String
        let source_sha256: String
        let voice: String
        let voice_pcm_sha256: String
        let text: String
        let split: String
        let label: String
        let seed: UInt64
    }

    func testGenerateContactVoiceCorpus() async throws {
        guard let path = ProcessInfo.processInfo.environment["CALL_GEMMA_WAKE_CORPUS"] else {
            throw XCTSkip("Opt-in silent contact-voice corpus generation")
        }
        let root = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contactsURL = try XCTUnwrap(BlessengerResources.bundle.url(forResource: "contacts", withExtension: "json"))
        let contacts = try JSONDecoder().decode([Persona].self, from: Data(contentsOf: contactsURL))
        // Partition conditioning sources BEFORE synthesizing or augmenting. Each
        // voice speaks every label, so speaker identity cannot predict the name.
        let challenge = ProcessInfo.processInfo.environment["CALL_GEMMA_WAKE_CHALLENGE"] == "1"
        let partitions = challenge ? [("judith_herman", "test"), ("ad_de_jongh", "test")] : [("peter_levine", "train"), ("gabor_mate", "train"),
                          ("francine_shapiro", "validation"), ("judith_herman", "test")]
        let negatives = challenge ? ["I left my keys upstairs.", "The tea has gone cold.", "She smiled when I told her.",
            "We were discussing her childhood.", "I worry about getting it wrong.", "Could you speak more slowly?",
            "The ferry leaves at seven.", "My brother moved last year.", "This feels uncomfortable.",
            "I disagree with that interpretation.", "The rain has stopped.", "My shoulders feel tense.",
            "What should I notice first?", "I think I need some sleep.", "How does that fit together?",
            "We have been working on boundaries.", "It reminds me of school.", "The road was closed.",
            "I feel a little less anxious.", "I was afraid of being judged.", "My sister is on the telephone.",
            "That is difficult to explain.", "I would rather wait until tomorrow.", "There was nobody in the room."] : ["Hello there.", "Thank you.", "Please continue.", "What do you think?",
            "I understand.", "Can you explain?", "Tell me more.", "Let me think.",
            "That makes sense.", "I am still here.", "A little better.", "Please repeat that.",
            "The vessel is empty.", "The heater is running.", "The gate is open.",
            "Just add some water.", "The fisherman left.", "It is Christmas soon.",
            "I met her yesterday.", "We should go home.", "No, not yet.", "Yes, that's right.",
            "I need a moment.", "The room is quiet."]
        var phrases: [(String, String)] = negatives.map { ($0, "other") }
        for contact in contacts {
            let name = contact.wakeName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw CheckpointError.invalidMetadata }
            phrases += ["\(name).", "Hey \(name).", "\(name), what do you think?", "Thank you, \(name)."]
                .map { ($0, contact.id.uuidString.lowercased()) }
        }
        await AudioModelPins.configure()
        let directory = AudioModelPins.pocketDirectory(in: root)
        try await AudioModelPins.preparePocketCache(at: directory)
        try await AudioModelPins.prepareVoiceEncoder(at: directory)
        let manager = PocketTtsManager(directory: directory, placement: .ane,
            computeUnits: PocketTtsComputeUnits(conditioner: .cpuAndNeuralEngine,
                flowLM: .cpuAndNeuralEngine, flowDecoder: .cpuAndNeuralEngine,
                mimiDecoder: .cpuOnly, mimiEncoder: .cpuOnly))
        try await manager.initialize()
        var rows: [Row] = []
        var seenVoices = Set<String>()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (voice, split) in partitions {
            let url = try XCTUnwrap(BlessengerResources.voiceURL(voice))
            let reference = try VoiceSample.read(from: url)
            let voiceHash = reference.withUnsafeBytes { digest(Data($0)) }
            guard seenVoices.insert(voiceHash).inserted else { throw CheckpointError.invalidMetadata }
            let conditioning = try await manager.cloneVoice(from: reference)
            for (index, phrase) in phrases.enumerated() {
                try Task.checkCancellation()
                let seed = UInt64(index + 1000 * rows.count)
                let session = try await manager.makeSession(voiceData: conditioning, seed: seed)
                session.enqueue(phrase.0); session.finish()
                var pcm: [Float] = []
                do {
                    for try await frame in session.frames {
                        try Task.checkCancellation()
                        pcm.append(contentsOf: frame.samples)
                        guard pcm.count <= 24_000 * 15, pcm.allSatisfy(\.isFinite) else { throw CallAudioError.invalidVoice }
                    }
                    await session.cancel()
                } catch { await session.cancel(); throw error }
                guard !pcm.isEmpty else { throw CallAudioError.invalidVoice }
                let resampled = try AudioConverter(sampleRate: 16_000).resample(pcm, from: 24_000)
                let data = try WaveFile.encode(samples: resampled)
                let source = digest(Data("\(voiceHash)|\(seed)|\(phrase.0)".utf8))
                let relative = "\(split)/\(phrase.1)/\(source)-0.wav"
                let file = root.appending(path: relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .withoutOverwriting)
                rows.append(Row(path: relative, source: source, source_sha256: digest(data), voice: voice,
                    voice_pcm_sha256: voiceHash, text: phrase.0, split: split, label: phrase.1, seed: seed))
                try encoder.encode(rows).write(to: root.appending(path: "manifest.json"), options: .atomic)
                print("WAKE_CORPUS \(rows.count)/\(partitions.count * phrases.count) \(split)")
            }
        }
        let provenance: [String: String] = ["pocketSnapshot": AudioModelPins.pocket,
            "correctedExports": PocketSpeechAssets.identity, "scope": "Synthetic contact voices; no live routing acceptance"]
        try JSONSerialization.data(withJSONObject: provenance, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appending(path: "provenance.json"), options: .withoutOverwriting)
        try Data("Complete; synthetic contact voices only, no live routing acceptance.\n".utf8)
            .write(to: root.appending(path: "COMPLETE"), options: .withoutOverwriting)
    }
}
