import AVFoundation
import CoreML
import Foundation

/// Aligns a complete, reproducible synthesis reference off the playback path.
/// Truncated audio is rejected: forcing unheard text onto it invents words.
actor HeardTextAlignment {
    struct Word: Sendable {
        let textEnd: String.Index
        let endSeconds: Double
    }

    private var model: MLModel?
    private var loadedURL: URL?
    private var compiledURL: URL?

    func prepare(modelDirectory: URL) async throws {
        guard model == nil || loadedURL != modelDirectory else { return }
        let start = LatencyTrace.now()
        defer { AudioTrace.latency.duration("interruption.aligner_load", since: start) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let compiled = modelDirectory.pathExtension == "mlmodelc"
            ? modelDirectory : try await MLModel.compileModel(at: modelDirectory)
        model = try MLModel(contentsOf: compiled, configuration: configuration)
        compiledURL = compiled
        loadedURL = modelDirectory
    }

    func words(text: String, referencePCM: [Float], sampleRate: Double,
               modelDirectory: URL, referenceComplete: Bool = true) async throws -> [Word] {
        guard referenceComplete else {
            throw GemmaError(message: "A complete synthesis reference is required to recover the spoken text.")
        }
        guard !text.isEmpty, text.utf8.count <= 4_096, sampleRate > 0,
              !referencePCM.isEmpty, referencePCM.count <= Int(sampleRate * 60),
              referencePCM.allSatisfy(\.isFinite) else {
            throw GemmaError(message: "The speech alignment reference is invalid.")
        }
        try await prepare(modelDirectory: modelDirectory)
        guard model != nil else { throw GemmaError(message: "The speech aligner is unavailable.") }
        let samples = try Self.resample(referencePCM, sampleRate: sampleRate)
        guard samples.count >= 400 else { return [] }
        let waveform = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
        samples.withUnsafeBufferPointer {
            waveform.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: $0.count)
        }
        let start = LatencyTrace.now()
        // Actor isolation serializes the non-Sendable Core ML model. This
        // bounded CPU pass runs outside the main actor and the playback path.
        let output = try predict(waveform)
        guard let emissions = output.featureValue(for: "emissions")?.multiArrayValue,
              emissions.shape.count == 3, emissions.shape[0].intValue == 1,
              emissions.shape[2].intValue == 32,
              emissions.shape[1].intValue == (samples.count - 400) / 320 + 1 else {
            throw GemmaError(message: "The speech alignment model returned an invalid shape.")
        }
        let frames = emissions.shape[1].intValue
        var logProbabilities: [[Float]] = []
        logProbabilities.reserveCapacity(frames)
        for frame in 0..<frames {
            var row: [Float] = []
            row.reserveCapacity(32)
            for token in 0..<32 {
                let value = emissions[[0, NSNumber(value: frame), NSNumber(value: token)]].floatValue
                guard value.isFinite, value > -200, value <= 0.01 else {
                    throw GemmaError(message: "The speech aligner returned invalid probabilities.")
                }
                row.append(value)
            }
            logProbabilities.append(row)
        }
        let target = try Self.target(text)
        let spans = try ForcedTextAlignment.align(logProbabilities: logProbabilities,
                                                  tokens: target.tokens, blank: 0)
        AudioTrace.latency.duration("interruption.text_alignment", since: start)
        return target.words.map { word in
            Word(textEnd: word.end, endSeconds: Double(spans[word.lastToken].endFrame) * 0.02)
        }
    }

    private func predict(_ waveform: MLMultiArray) throws -> MLFeatureProvider {
        guard let model else { throw GemmaError(message: "The speech aligner is unavailable.") }
        return try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": waveform]))
    }

    private static func target(_ text: String) throws -> (tokens: [Int], words: [(end: String.Index, lastToken: Int)]) {
        // Exactly the pinned facebook/wav2vec2-base-960h vocabulary.
        let labels = Dictionary(uniqueKeysWithValues: Array("ETAONIHSRDLUMWCFGYPBVK'XJQZ").enumerated().map { ($0.element, $0.offset + 5) })
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) {
            _, range, _, _ in ranges.append(range)
        }
        var tokens: [Int] = []
        var words: [(end: String.Index, lastToken: Int)] = []
        let numberFormatter = NumberFormatter()
        numberFormatter.locale = Locale(identifier: "en_US")
        numberFormatter.numberStyle = .spellOut
        for range in ranges {
            var word = String(text[range]).replacingOccurrences(of: "’", with: "'")
            if let number = Decimal(string: word, locale: Locale(identifier: "en_US_POSIX")),
               word.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) {
                guard let spoken = numberFormatter.string(from: NSDecimalNumber(decimal: number)) else {
                    throw GemmaError(message: "Cannot align this spoken number.")
                }
                word = spoken
            }
            word = word.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US")).uppercased()
            if !tokens.isEmpty { tokens.append(4) }
            for character in word {
                if character == " " || character == "-" { tokens.append(4) }
                else if let label = labels[character] { tokens.append(label) }
                else { throw GemmaError(message: "The English speech aligner cannot resolve this text.") }
            }
            words.append((range.upperBound, tokens.count - 1))
        }
        guard !tokens.isEmpty else { throw GemmaError(message: "The speech segment has no alignable words.") }
        return (tokens, words)
    }

    static func prefix(text: String, words: [Word], playedSeconds: Double) -> String {
        guard playedSeconds.isFinite, playedSeconds > 0,
              let last = words.last(where: { $0.endSeconds <= playedSeconds }) else { return "" }
        return String(text[..<last.textEnd])
    }

    private static func resample(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        if sampleRate == 16_000 { return samples }
        guard let source = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16_000 / sampleRate)) + 1_024),
              let channel = input.floatChannelData?[0] else {
            throw GemmaError(message: "Cannot prepare the speech alignment audio.")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let result = output.floatChannelData?[0],
              output.frameLength > 0 else {
            if let error { throw error }
            throw GemmaError(message: "Cannot convert the speech alignment audio.")
        }
        return Array(UnsafeBufferPointer(start: result, count: Int(output.frameLength)))
    }
}
