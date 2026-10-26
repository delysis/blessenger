import CoreML
import Foundation

/// CPU-only keyword features. Actor isolation keeps inference off capture/UI.
actor WakePhonetics {
    private var model: MLModel?
    private var compiled: URL?
    func recipient(_ samples: [Float], names: [WakeNameModel.Name], classifier: WakeNameClassifier?,
                   diagnosticID: UUID) async throws -> UUID? {
        let decoded = try await decode(samples)
        try Task.checkCancellation()
        let recipient = try WakeNameModel.recipient(decoded, names: names,
            roster: Set(names.map(\.id)), classifier: classifier)
        if let root = AppQualificationEnvironment.root {
            let directory = root.appending(path: "WakeRouting")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = ["decoded": decoded, "recipient": recipient?.uuidString ?? ""]
            try JSONEncoder().encode(record).write(to: directory.appending(path: diagnosticID.uuidString + ".json"), options: .atomic)
        }
        return recipient
    }
    func prepare() async throws {
        guard model == nil else { return }
        let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
        let url = try await MLModel.compileModel(at: AudioModelPins.alignerDirectory)
        do { model = try MLModel(contentsOf: url, configuration: config); compiled = url }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    func decode(_ samples: [Float], trainingText: String? = nil, trailingTrainingWords: Int = 0) async throws -> String {
        guard samples.count >= 400, samples.count <= 480_000, samples.allSatisfy(\.isFinite) else { return "" }
        try Task.checkCancellation()
        try await prepare()
        let waveform = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
        samples.withUnsafeBufferPointer {
            waveform.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count)
        }
        let result = try predict(waveform)
        try Task.checkCancellation()
        guard let emissions = result.featureValue(for: "emissions")?.multiArrayValue,
              emissions.shape.count == 3, emissions.shape[0].intValue == 1, emissions.shape[2].intValue == 32 else {
            throw CheckpointError.invalidMetadata
        }
        let alphabet = Array("    |ETAONIHSRDLUMWCFGYPBVK'XJQZ")
        var firstFrame = 0
        var lastFrame = emissions.shape[1].intValue
        if let trainingText {
            // Training synthesis alone has a protective "Hello there" lead-in.
            // Alignment only locates its end; name features still come from an
            // unconstrained decode, never from the expected label's spelling.
            let normalized = Self.trainingCharacters(trainingText)
            let prefix = Array("HELLO|THERE")
            guard normalized.starts(with: prefix), normalized.count > prefix.count,
                  normalized[prefix.count] == "|" else { throw CheckpointError.invalidMetadata }
            let index = Dictionary(uniqueKeysWithValues: alphabet.enumerated().dropFirst(4).map { ($1, $0) })
            let tokens = try normalized.map { character -> Int in
                guard let token = index[character] else { throw CheckpointError.invalidMetadata }
                return token
            }
            let probabilities = (0..<emissions.shape[1].intValue).map { frame in
                (0..<32).map { emissions[[0, NSNumber(value: frame), NSNumber(value: $0)]].floatValue }
            }
            let spans = try ForcedTextAlignment.align(logProbabilities: probabilities, tokens: tokens, blank: 0)
            firstFrame = spans[prefix.count - 1].endFrame
            if trailingTrainingWords > 0 {
                let words = String(normalized).split(separator: "|")
                guard words.count > 2 + trailingTrainingWords else { throw CheckpointError.invalidMetadata }
                let contentEnd = words.dropLast(trailingTrainingWords).joined(separator: "|").count - 1
                lastFrame = spans[contentEnd].endFrame
            }
            guard firstFrame < lastFrame else { throw CheckpointError.invalidMetadata }
        }
        var text = "", previous = -1
        for frame in firstFrame..<lastFrame {
            var best = 0, maximum = -Float.infinity
            for token in 0..<32 {
                let value = emissions[[0, NSNumber(value: frame), NSNumber(value: token)]].floatValue
                guard value.isFinite else { throw CheckpointError.invalidMetadata }
                if value > maximum { maximum = value; best = token }
            }
            if best != previous, best >= 4 { text.append(alphabet[best]) }
            previous = best
        }
        return text.replacingOccurrences(of: "|", with: " ").trimmingCharacters(in: .whitespaces)
    }
    private static func trainingCharacters(_ text: String) -> [Character] {
        let folded = text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US")).uppercased()
        let words = folded.split(whereSeparator: { !$0.isASCII || (!$0.isLetter && $0 != "'") })
        return Array(words.joined(separator: "|"))
    }
    private func predict(_ waveform: MLMultiArray) throws -> MLFeatureProvider {
        guard let model else { throw CheckpointError.invalidMetadata }
        return try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": waveform]))
    }
    func close() {
        model = nil
        if let compiled { try? FileManager.default.removeItem(at: compiled) }
        compiled = nil
    }
}
