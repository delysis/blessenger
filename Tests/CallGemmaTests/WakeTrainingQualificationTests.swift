import Foundation
import AVFoundation
import XCTest
@testable import CallGemma

final class WakeTrainingQualificationTests: XCTestCase {
    func testTrainContactCatalog() async throws {
        guard let path = ProcessInfo.processInfo.environment["CALL_GEMMA_WAKE_TRAIN"] else { throw XCTSkip("Opt-in native wake-name training") }
        let output = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(BlessengerResources.bundle.url(forResource: "contacts", withExtension: "json"))
        let contacts = try JSONDecoder().decode([Persona].self, from: Data(contentsOf: url))
        let identity = try WakeNameTraining.fingerprint(contacts)
        let featureCache = ProcessInfo.processInfo.environment["CALL_GEMMA_WAKE_FEATURE_CACHE"]
            .map { URL(fileURLWithPath: $0) } ?? output.appending(path: "Features")
        let result = try await WakeNameTraining.train(contacts: contacts, fingerprint: identity, cacheDirectory: featureCache) { done, total in
            if done % 25 == 0 { print("WAKE_TRAIN \(done)/\(total)") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: output.appending(path: identity + ".json"), options: .withoutOverwriting)
        print("WAKE_RESULT", String(decoding: try encoder.encode(result.receipt), as: UTF8.self))
        // A rejected result remains useful evidence; never silently enable it.
        XCTAssertGreaterThan(result.receipt.clips, 0)
    }
}

extension WakeTrainingQualificationTests {
    func testEvaluateCorpusAndEcho() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["CALL_GEMMA_WAKE_MODEL"], let corpusPath = env["CALL_GEMMA_WAKE_EVAL_CORPUS"],
              let outputPath = env["CALL_GEMMA_WAKE_EVAL_OUTPUT"] else { throw XCTSkip("Opt-in independent corpus and post-AEC evaluation") }
        struct Row: Decodable { let path: String; let label: String; let split: String; let text: String }
        struct Outcome: Codable { let path: String; let expected: String; let predicted: String; let decoded: String }
        let result = try JSONDecoder().decode(WakeNameTraining.Result.self, from: Data(contentsOf: URL(fileURLWithPath: modelPath)))
        let root = URL(fileURLWithPath: corpusPath), output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: root.appending(path: "manifest.json")))
        let phonetics = WakePhonetics(), roster = Set(result.model.names.map(\.id))
        var receipt = WakeNameTraining.Receipt(), outcomes: [Outcome] = []
        for row in rows where row.split == "test" {
            let samples = try Self.readWave(root.appending(path: row.path))
            let decoded = try await phonetics.decode(samples)
            let prediction = try result.model.recipient(decoded, roster: roster)?.uuidString.lowercased() ?? "other"
            if row.label == "other" { receipt.negatives += 1; if prediction != "other" { receipt.falseActivations += 1 } }
            else { receipt.positives += 1; if prediction == row.label { receipt.correct += 1 } else if prediction != "other" { receipt.wrong += 1 } }
            receipt.clips += 1
            outcomes.append(.init(path: row.path, expected: row.label, predicted: prediction, decoded: decoded))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(outcomes).write(to: output.appending(path: "predictions.json"))
        try encoder.encode(receipt).write(to: output.appending(path: "receipt.json"))
        print("WAKE_EVAL", String(decoding: try encoder.encode(receipt), as: UTF8.self))
        if let echoPath = env["CALL_GEMMA_WAKE_ECHO"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: echoPath))
            guard data.count % 4 == 0, data.count <= 16_000 * 60 * 4 else { throw CallAudioError.invalidVoice }
            let pcm = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var detections: [String] = [], windows = 0
            if pcm.count >= 48_000 {
                for start in stride(from: 0, through: pcm.count - 48_000, by: 8_000) {
                    let decoded = try await phonetics.decode(Array(pcm[start..<(start+48_000)]))
                    if let id = try result.model.recipient(decoded, roster: roster) { detections.append("\(Double(start)/16000):\(id)") }
                    windows += 1
                }
            }
            let echo: [String: Any] = ["windows": windows, "seconds": Double(pcm.count)/16_000,
                "detections": detections, "scope": "Retained post-AEC capture; not a new live speaker check"]
            try JSONSerialization.data(withJSONObject: echo, options: [.prettyPrinted,.sortedKeys]).write(to: output.appending(path: "echo.json"))
            print("WAKE_ECHO windows=\(windows) detections=\(detections.count)")
        }
        await phonetics.close()
    }
    private static func readWave(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length <= 480_000, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw CallAudioError.invalidVoice }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
