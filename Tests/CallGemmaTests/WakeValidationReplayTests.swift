import Foundation
import FluidAudio
import class FluidAudio.AudioConverter
import XCTest
@testable import CallGemma

final class WakeValidationReplayTests: XCTestCase {
    func testReplayValidation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["CALL_GEMMA_WAKE_MODEL"], let path = env["CALL_GEMMA_WAKE_VALIDATION"] else { throw XCTSkip("Opt-in validation error inspection") }
        let result = try JSONDecoder().decode(WakeNameTraining.Result.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        await AudioModelPins.configure()
        let directory = AudioModelPins.pocketDirectory(in: URL(fileURLWithPath: path))
        try await AudioModelPins.preparePocketCache(at: directory)
        try await AudioModelPins.prepareVoiceEncoder(at: directory)
        let manager = PocketTtsManager(directory: directory, placement: .ane,
            computeUnits: PocketTtsComputeUnits(conditioner: .cpuAndNeuralEngine, flowLM: .cpuAndNeuralEngine,
                flowDecoder: .cpuAndNeuralEngine, mimiDecoder: .cpuOnly, mimiEncoder: .cpuOnly))
        try await manager.initialize()
        let phonetics = WakePhonetics(), roster = Set(result.model.names.map(\.id))
        var count = 10 * (result.model.names.count * 4 + WakeNameTraining.trainingNegatives.count)
        var outcomes: [[String: String]] = []
        for voice in WakeNameTraining.voices where voice.validation {
            let conditioning = try await manager.cloneVoice(from: VoiceSample.read(from: XCTUnwrap(BlessengerResources.voiceURL(voice.name))))
            var phrases = WakeNameTraining.validationNegatives.map { ($0, "other") }
            for name in result.model.names {
                phrases += ["\(name.name).", "Hey \(name.name).", "\(name.name), what do you think?", "Thank you, \(name.name)."].map { ($0,name.id.uuidString.lowercased()) }
            }
            for (text,label) in phrases {
                let session = try await manager.makeSession(voiceData: conditioning, seed: UInt64(count+70_000))
                session.enqueue(text); session.finish()
                var pcm: [Float] = []
                do { for try await frame in session.frames { pcm.append(contentsOf: frame.samples) }; await session.cancel() }
                catch { await session.cancel(); throw error }
                let decoded = try await phonetics.decode(AudioConverter(sampleRate: 16_000).resample(pcm, from: 24_000))
                let predicted = try result.model.recipient(decoded, roster: roster)?.uuidString.lowercased() ?? "other"
                outcomes.append(["text":text,"decoded":decoded,"label":label,"predicted":predicted,"voice":voice.name])
                if label != predicted { print("WAKE_MISS \(voice.name): \(text) => \(decoded) -> \(predicted)") }
                count += 1
            }
        }
        await phonetics.close()
        try JSONSerialization.data(withJSONObject: outcomes, options: [.sortedKeys,.prettyPrinted]).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }
}
