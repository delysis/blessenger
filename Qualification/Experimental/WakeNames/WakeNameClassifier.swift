import Foundation
import Accelerate

/// Small, locally trained phonetic-text head. Its inputs are CTC decodes, not
/// conversational transcripts. Unknown speech remains a first-class label.
/// Training examples must be split by source voice before any augmentation.
struct WakeNameClassifier: Codable, Sendable {
    struct Example: Sendable {
        let text: String
        let label: String
    }
    enum Failure: Error { case invalidCorpus, invalidModel }
    let vocabulary: [String]
    let idf: [Float]
    let labels: [String]
    let weights: [Float]
    let margin: Float

    private static func grams(_ text: String) -> [String: Float] {
        let chars = Array(text.lowercased())
        var counts: [String: Float] = [:]
        for length in 2...4 where chars.count >= length {
            for start in 0...(chars.count - length) {
                counts[String(chars[start..<(start + length)]), default: 0] += 1
            }
        }
        return counts
    }

    private static func vector(_ text: String, index: [String: Int], idf: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: idf.count + 1)
        for (gram, count) in grams(text) {
            if let column = index[gram] { result[column] = count * idf[column] }
        }
        let norm = sqrt(result.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { for column in idf.indices { result[column] /= norm } }
        result[idf.count] = 1 // Unregularized intercept.
        return result
    }

    func prediction(_ text: String) throws -> (label: String, margin: Float) {
        guard vocabulary.count == idf.count, Set(vocabulary).count == vocabulary.count,
              labels.count >= 2, labels.contains("other"),
              weights.count == labels.count * (vocabulary.count + 1),
              weights.allSatisfy(\.isFinite), idf.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw Failure.invalidModel }
        let index = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($1, $0) })
        let x = Self.vector(text, index: index, idf: idf)
        let d = x.count
        var logits = labels.indices.map { row in
            zip(x, weights[(row * d)..<((row + 1) * d)]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        }
        let peak = logits.max()!
        logits = logits.map { exp($0 - peak) }
        let sum = logits.reduce(0, +)
        let order = logits.indices.sorted { logits[$0] > logits[$1] }
        let separation = (logits[order[0]] - logits[order[1]]) / sum
        return (separation >= margin ? labels[order[0]] : "other", separation)
    }

    /// Native multinomial logistic regression, C=100. BLAS runs off the main
    /// actor; bounded corpus and vocabulary keep memory and work predictable.
    static func train(_ examples: [Example], margin: Float = 0.4) throws -> Self {
        guard examples.count >= 4, examples.count <= 4_000,
              examples.allSatisfy({ !$0.text.isEmpty && $0.text.utf8.count <= 1_024 }),
              margin.isFinite, (0...1).contains(margin) else { throw Failure.invalidCorpus }
        let labels = Set(examples.map(\.label)).sorted()
        guard labels.contains("other"), (2...65).contains(labels.count) else { throw Failure.invalidCorpus }
        var frequencies: [String: Int] = [:]
        for example in examples { for gram in grams(example.text).keys { frequencies[gram, default: 0] += 1 } }
        let vocabulary = frequencies.keys.sorted()
        guard !vocabulary.isEmpty, vocabulary.count <= 16_384 else { throw Failure.invalidCorpus }
        let idf = vocabulary.map { log(Float(1 + examples.count) / Float(1 + frequencies[$0]!)) + 1 }
        let index = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($1, $0) })
        let labelIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        let n = examples.count, k = labels.count, d = vocabulary.count + 1
        // Avoid unbounded dense training matrices when contacts/corpus grow.
        guard n * d <= 16_000_000 else { throw Failure.invalidCorpus }
        let x = examples.flatMap { vector($0.text, index: index, idf: idf) }
        var weights = [Float](repeating: 0, count: k * d)
        var accumulated = weights
        var probabilities = [Float](repeating: 0, count: n * k)
        var gradient = weights
        for _ in 0..<600 {
            try Task.checkCancellation()
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(k), Int32(d),
                        1, x, Int32(d), weights, Int32(d), 0, &probabilities, Int32(k))
            for row in 0..<n {
                let offset = row * k
                let peak = probabilities[offset..<(offset + k)].max()!
                var sum: Float = 0
                for column in 0..<k { probabilities[offset + column] = exp(probabilities[offset + column] - peak); sum += probabilities[offset + column] }
                for column in 0..<k { probabilities[offset + column] /= sum }
                probabilities[offset + labelIndex[examples[row].label]!] -= 1
            }
            cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(k), Int32(d), Int32(n),
                        1 / Float(n), probabilities, Int32(k), x, Int32(d), 0, &gradient, Int32(d))
            for position in weights.indices {
                if position % d != d - 1 { gradient[position] += weights[position] / Float(100 * n) }
                accumulated[position] += gradient[position] * gradient[position]
                weights[position] -= 0.5 * gradient[position] / (sqrt(accumulated[position]) + 1e-7)
            }
        }
        return Self(vocabulary: vocabulary, idf: idf, labels: labels, weights: weights, margin: margin)
    }
}
