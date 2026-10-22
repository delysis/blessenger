import Foundation

/// Aligns known text to its complete synthesized audio. It cannot establish
/// what was heard from elapsed time, and must not be run against a truncated
/// waveform while claiming that the entire target was spoken.
enum ForcedTextAlignment {
    struct TokenSpan: Equatable, Sendable {
        let firstFrame: Int
        let endFrame: Int
    }

    static func align(logProbabilities: [[Float]], tokens: [Int], blank: Int) throws -> [TokenSpan] {
        guard !tokens.isEmpty, !logProbabilities.isEmpty,
              let width = logProbabilities.first?.count, width > 0,
              blank >= 0, blank < width,
              tokens.allSatisfy({ $0 >= 0 && $0 < width && $0 != blank }),
              logProbabilities.allSatisfy({ $0.count == width && $0.allSatisfy(\.isFinite) }) else {
            throw GemmaError(message: "Invalid text alignment input.")
        }
        let frames = logProbabilities.count
        let states = tokens.count * 2 + 1
        // Bound both computation and backtrace storage; a synthesis segment is
        // bounded independently to one minute.
        guard tokens.count <= 1_024, frames <= 3_000, frames * states <= 4_000_000 else {
            throw GemmaError(message: "Text alignment exceeds the segment limit.")
        }
        let impossible = -Float.infinity
        var previous = [Float](repeating: impossible, count: states)
        var current = previous
        var moves = [UInt8](repeating: 255, count: frames * states)
        previous[0] = logProbabilities[0][blank]
        previous[1] = logProbabilities[0][tokens[0]]
        for frame in 1..<frames {
            for state in 0..<states {
                let token = state.isMultiple(of: 2) ? blank : tokens[state / 2]
                var best = previous[state]
                var move: UInt8 = 0
                if state > 0, previous[state - 1] > best {
                    best = previous[state - 1]
                    move = 1
                }
                // CTC requires an intervening blank for repeated token IDs.
                if state > 1, !state.isMultiple(of: 2),
                   tokens[state / 2] != tokens[state / 2 - 1],
                   previous[state - 2] > best {
                    best = previous[state - 2]
                    move = 2
                }
                current[state] = best + logProbabilities[frame][token]
                moves[frame * states + state] = move
            }
            swap(&previous, &current)
        }
        var state = previous[states - 1] > previous[states - 2] ? states - 1 : states - 2
        guard previous[state].isFinite else {
            throw GemmaError(message: "The audio cannot align to the complete text.")
        }
        let emitted = (state + 1) / 2
        var first = [Int](repeating: frames, count: emitted)
        var end = [Int](repeating: 0, count: emitted)
        for frame in stride(from: frames - 1, through: 0, by: -1) {
            if !state.isMultiple(of: 2) {
                let index = state / 2
                first[index] = frame
                end[index] = max(end[index], frame + 1)
            }
            if frame > 0 { state -= Int(moves[frame * states + state]) }
        }
        guard zip(first, end).allSatisfy({ $0 < $1 }) else {
            throw GemmaError(message: "Text alignment omitted a token.")
        }
        return zip(first, end).map { TokenSpan(firstFrame: $0, endFrame: $1) }
    }
}
