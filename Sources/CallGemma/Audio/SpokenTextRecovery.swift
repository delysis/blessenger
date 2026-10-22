import Foundation

/// The source of truth is delivered PCM, never the decoder's unplayed tail.
/// A partial sentence is aligned against its complete deterministic synthesis;
/// regenerating only a truncated reference would force future words into it.
actor SpokenTextRecovery {
    typealias Render = @Sendable (HeardTurnJournal.Segment, [Float]?) async throws -> [Float]
    private let aligner = HeardTextAlignment()

    func text(journal: HeardTurnJournal, modelDirectory: URL, render: Render) async throws -> String {
        try await journal.flush()
        guard let pending = try await journal.loadPending() else { return "" }
        var parts: [String] = []
        var reachedEnd = false
        for segment in pending.segments {
            guard !reachedEnd || segment.playedFrames == 0 else {
                throw GemmaError(message: "The saved playback positions are out of order.")
            }
            if segment.playedFrames == 0 {
                reachedEnd = true
                continue
            }
            if segment.complete && segment.playedFrames == segment.generatedFrames {
                parts.append(segment.text)
                continue
            }
            reachedEnd = true
            if let text = try HeardTurnJournal.heardPrefix(segment) {
                if !text.isEmpty { parts.append(text) }
                continue
            }
            let voice = try await journal.voicePrompt(segment.voice)
            let reference = try await render(segment, voice)
            guard !reference.isEmpty, reference.count <= 24_000 * 60,
                  reference.count >= segment.generatedFrames, reference.allSatisfy(\.isFinite),
                  !segment.complete || reference.count == segment.generatedFrames else {
                throw GemmaError(message: "The interrupted speech reference could not be reproduced.")
            }
            let prefix = reference.prefix(segment.generatedFrames)
            let hash = prefix.withUnsafeBytes { digest(Data($0)) }
            guard hash == segment.generatedSHA256 else {
                throw GemmaError(message: "The speech reference differs from the audio that played. Recovery has been preserved.")
            }
            let words = try await aligner.words(text: segment.text, referencePCM: reference,
                                                sampleRate: 24_000, modelDirectory: modelDirectory)
            let heard = HeardTextAlignment.prefix(text: segment.text, words: words,
                                                  playedSeconds: Double(segment.playedFrames) / 24_000)
            if !heard.isEmpty { parts.append(heard) }
        }
        return SpokenText.joinSegments(parts)
    }
}
