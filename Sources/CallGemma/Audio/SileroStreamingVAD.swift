@preconcurrency import CoreML
import Foundation

/// The pinned 32 ms Silero graph accepts 512 new samples and 64 context samples.
/// This is a different graph from FluidAudio's 4096-sample wrapper.
actor SileroStreamingVAD {
    static let chunkSize = 512
    private let model: MLModel
    private let input: MLMultiArray
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var context = [Float](repeating: 0, count: 64)
    private var epoch: UUID?

    init(directory: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: directory, configuration: config)
        let descriptions = model.modelDescription.inputDescriptionsByName
        guard descriptions["audio_input"]?.multiArrayConstraint?.shape == [1, 576],
              descriptions["hidden_state"]?.multiArrayConstraint?.shape == [1, 128],
              descriptions["cell_state"]?.multiArrayConstraint?.shape == [1, 128] else {
            throw CallAudioError.unavailable("The VAD model has an incompatible input shape.")
        }
        input = try MLMultiArray(shape: [1, 576], dataType: .float32)
        hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
    }

    func process(_ samples: [Float], epoch: UUID) throws -> Float {
        guard samples.count == Self.chunkSize, samples.allSatisfy(\.isFinite) else {
            throw CallAudioError.unavailable("VAD requires 512 finite samples.")
        }
        return try autoreleasepool {
            if self.epoch != epoch {
                self.epoch = epoch
                context = Array(repeating: 0, count: 64)
                for index in 0..<128 {
                    hidden[index] = 0
                    cell[index] = 0
                }
            }
            for index in 0..<64 { input[index] = NSNumber(value: context[index]) }
            for index in samples.indices { input[index + 64] = NSNumber(value: samples[index]) }
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": input, "hidden_state": hidden, "cell_state": cell
            ])
            let output = try model.prediction(from: features)
            guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue,
                  let newHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  let newCell = output.featureValue(for: "new_cell_state")?.multiArrayValue,
                  probability.count == 1, newHidden.count == 128, newCell.count == 128 else {
                throw CallAudioError.unavailable("The VAD model returned incompatible outputs.")
            }
            let value = probability[0].floatValue
            guard value.isFinite, (0...1).contains(value) else {
                throw CallAudioError.unavailable("The VAD model returned an invalid probability.")
            }
            hidden = newHidden
            cell = newCell
            context = Array(samples.suffix(64))
            return value
        }
    }
}
