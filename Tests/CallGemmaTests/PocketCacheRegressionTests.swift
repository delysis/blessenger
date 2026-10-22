import CoreML
@testable import CallGemma
@testable import FluidAudio
import Foundation
import XCTest

final class PocketCacheRegressionTests: XCTestCase {
    func testEnglishShortTextMatchesModelPolicy() {
        let (text, tail) = PocketTtsSynthesizer.normalizeText("thank you.", language: .english)
        XCTAssertEqual(text, "Thank you.")
        XCTAssertEqual(tail, 3, "Removing lexical padding must not truncate the EOS tail")
    }

    /// Real exported-model regression: raw prefill accumulates padding in its
    /// dump slot. The SDK boundary must discard it without altering valid KV.
    func testFixedWidthPrefillPreservesOnlyValidContext() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixturePath = env["CALL_GEMMA_PREFILL_FIXTURE"],
              let modelPath = env["CALL_GEMMA_PREFILL_MODEL"] else {
            throw XCTSkip("Opt-in real-model conditioning regression")
        }
        let fixture = URL(fileURLWithPath: fixturePath)
        let shapes = try JSONDecoder().decode([String: [Int]].self,
            from: Data(contentsOf: fixture.appendingPathComponent("inputs.json")))
        var arrays: [String: MLMultiArray] = [:]
        for (name, shape) in shapes {
            let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
            let bytes = try Data(contentsOf: fixture.appendingPathComponent(name + ".f32"))
            XCTAssertEqual(bytes.count, array.count * 4)
            bytes.withUnsafeBytes { array.dataPointer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            arrays[name] = array
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: config)
        let raw = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: arrays))
        var state = PocketTtsSynthesizer.KVCacheState(
            caches: try (0..<6).map { try XCTUnwrap(arrays["k_cache\($0)"]) },
            vCaches: try (0..<6).map { try XCTUnwrap(arrays["v_cache\($0)"]) },
            positions: try (0..<6).map { try XCTUnwrap(arrays["position\($0)"]) })
        let count = try XCTUnwrap(arrays["valid_len"])[0].intValue
        let conditioning = try XCTUnwrap(arrays["conditioning"])
        let values = Array(UnsafeBufferPointer(start: conditioning.dataPointer.assumingMemoryBound(to: Float.self),
                                              count: count * 1024))
        try await PocketTtsSynthesizer.runCondPrefill(flatConditioning: values, tokenCount: count,
            state: &state, model: model, layerKeys: .aneKeys(layers: 6, kind: .condStep))
        var dirtyRawSlots = 0
        for layer in 0..<6 {
            let position = state.positions[layer][0].intValue
            XCTAssertEqual(position, 137)
            for (kind, actual) in [("k", state.caches[layer]), ("v", state.vCaches![layer])] {
                let expected = try XCTUnwrap(raw.featureValue(for: "new_\(kind)_cache\(layer)")?.multiArrayValue)
                XCTAssertEqual(actual.strides, expected.strides)
                let prefixBytes = position * 1024 * MemoryLayout<Float>.size
                XCTAssertEqual(Data(bytes: actual.dataPointer, count: prefixBytes),
                               Data(bytes: expected.dataPointer, count: prefixBytes), "Valid context changed")
                let a = actual.dataPointer.assumingMemoryBound(to: Float.self)
                let b = expected.dataPointer.assumingMemoryBound(to: Float.self)
                var nonzero = 0
                for index in (position * 1024)..<actual.count {
                    if a[index] != 0 { nonzero += 1 }
                    if b[index] != 0 { dirtyRawSlots += 1 }
                }
                XCTAssertEqual(nonzero, 0, "Padding escaped the prefill boundary")
            }
        }
        XCTAssertGreaterThan(dirtyRawSlots, 0, "Fixture no longer reproduces the export's dump-slot writes")
    }

    func testConditionerCacheViewReopensAcrossInstances() async throws {
        guard ProcessInfo.processInfo.environment["CALL_GEMMA_ASSET_REOPEN"] == "1" else {
            throw XCTSkip("Opt-in bundled model cache reopen regression")
        }
        await AudioModelPins.configure()
        let directory = AudioModelPins.pocketDirectory(in: FileManager.default.temporaryDirectory)
        try await AudioModelPins.preparePocketCache(at: directory)
        let snapshot = try await HFModelCache.snapshot(repository: "FluidInference/pocket-tts-coreml",
            revision: AudioModelPins.pocket, files: [])
        // Separate installer actors have no shared prepared-set shortcut.
        // Enumerated directory URLs carry a slash; symlink targets may not.
        try await PocketSpeechAssets().prepare(directory: directory, snapshot: snapshot)
        try await PocketSpeechAssets().prepare(directory: directory, snapshot: snapshot)
    }
}
