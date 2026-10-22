import Foundation
import Testing
@testable import CallGemma

struct AudioPolicyTests {
    @Test func sentenceBoundariesSpanTokenCallbacks() {
        var buffer = SentenceBuffer()
        #expect(buffer.append("Dr.") == [])
        #expect(buffer.append(" Lee paid 3.") == [])
        #expect(buffer.append("14 dollars.") == [])
        #expect(buffer.append(" Next sentence!") == ["Dr. Lee paid 3.14 dollars."])
        #expect(buffer.finish() == "Next sentence!")
        #expect(buffer.finish() == nil)
    }

    @Test func sentenceClosingQuoteAndNewline() {
        var buffer = SentenceBuffer()
        #expect(buffer.append("She said, \"Hello!") == ["She said,"])
        #expect(buffer.append("\"\nAnother line\n") == ["\"Hello!\"", "Another line"])
        #expect(buffer.finish() == nil)
    }

    @Test func unpunctuatedUnicodeTextIsBoundedWithoutLoss() {
        let text = String(repeating: "🧪", count: 701)
        var buffer = SentenceBuffer()
        var chunks = buffer.append(text)
        if let tail = buffer.finish() { chunks.append(tail) }
        #expect(chunks.map { $0.unicodeScalars.count } == [240, 240, 221])
        #expect(chunks.joined() == text)
    }

    @Test func firstClauseThenWholeSentences() {
        var buffer = SentenceBuffer()
        #expect(buffer.append("Here is the first useful clause,") == ["Here is the first useful clause,"])
        #expect(buffer.append(" followed by more detail; and a conclusion. Next, more detail; still one sentence! ") == [
            "followed by more detail; and a conclusion.",
            "Next, more detail; still one sentence!"])
        #expect(buffer.finish() == nil)
    }

    @Test func shortFirstClauseDoesNotWaitForTheSentence() {
        var buffer = SentenceBuffer()
        #expect(buffer.append("I'm sorry,") == ["I'm sorry,"])
        #expect(buffer.append(" but I can help. Yes, we can try. ") ==
                ["but I can help.", "Yes, we can try."])
    }

    @Test func eagerClausePreservesNumbersAndLaterSentences() {
        var buffer = SentenceBuffer()
        #expect(buffer.append("It costs 3,") == [])
        #expect(buffer.append("000 dollars,") == ["It costs 3,000 dollars,"])
        #expect(buffer.append(" including tax; and delivery.") == [])
        #expect(buffer.finish() == "including tax; and delivery.")
        var control = SentenceBuffer(eagerFirstClause: false)
        #expect(control.append("Well,") == [])
        #expect(control.append(" yes.") == ["Well,"])
        #expect(control.finish() == "yes.")
    }

    @Test func spokenSegmentsPreserveAttachedPunctuation() {
        #expect(SpokenText.joinSegments(["Well now", ", two plus two is four."]) == "Well now, two plus two is four.")
        #expect(SpokenText.joinSegments(["Well now", "that is interesting."]) == "Well now that is interesting.")
        #expect(SpokenText.joinSegments(["Hello.", "Next sentence."]) == "Hello. Next sentence.")
    }

    @Test func leadInContinuationDoesNotSpeakPunctuationAlone() {
        var buffer = SentenceBuffer()
        #expect(buffer.append(", ").isEmpty)
        #expect(buffer.append("two plus two is four. ") == [", two plus two is four."])
        #expect(buffer.finish() == nil)
    }

    @Test func leadingSilenceGatePreservesSpeechAndLaterPauses() {
        var gate = LeadingSilenceGate()
        #expect(gate.process(Array(repeating: 0, count: 1920)).isEmpty)
        let frame = Array(repeating: Float(0.0001), count: 120) + [Float(0.02), 0, -0.03]
        #expect(gate.process(frame) == Array(frame.dropFirst(72)))
        #expect(gate.skippedFrames == 1992)
        #expect(gate.process([0, 0, 0]) == [0, 0, 0])
        var restored = LeadingSilenceGate()
        _ = restored.process(Array(repeating: 0, count: 1920))
        #expect(restored.process(frame) == Array(frame.dropFirst(72)))
    }

    @Test func utteranceKeepsPrerollAndTrimsTrailingSilence() {
        var buffer = UtteranceBuffer(maximumSamples: 10, minimumSamples: 2, retainedSamples: 4)
        #expect(buffer.append([0, 1, 2, 3]) == nil)
        #expect(buffer.append([4, 5, 6, 7], start: 2) == nil)
        let completed = buffer.append([8, 9, 10, 11], end: 9)
        #expect(completed?.samples == [2, 3, 4, 5, 6, 7, 8])
        #expect(completed?.reachedLimit == false)
    }

    @Test func utteranceHasHardLimitAndRejectsTinyNoise() {
        var buffer = UtteranceBuffer(maximumSamples: 8, minimumSamples: 3, retainedSamples: 2)
        #expect(buffer.append([0, 1], start: 0, end: 2) == nil)
        #expect(buffer.append([2, 3, 4, 5], start: 2) == nil)
        let completed = buffer.append([6, 7, 8, 9, 10, 11])
        #expect(completed?.samples == [2, 3, 4, 5, 6, 7, 8, 9])
        #expect(completed?.reachedLimit == true)
    }

    @Test func onlyExplicitNeuralEngineFailureAllowsFallback() {
        let ane = NSError(domain: "com.apple.CoreML", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "ANEProgramProcessRequestDirect() Failed with status=0x16"
        ])
        let wrapped = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: ane])
        #expect(NeuralEngineFailure.isExplicit(wrapped))
        #expect(!NeuralEngineFailure.isExplicit(CancellationError()))
        #expect(!NeuralEngineFailure.isExplicit(NSError(domain: "com.apple.CoreML", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Prediction input has an invalid shape"
        ])))
        #expect(!NeuralEngineFailure.isExplicit(NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [
            NSLocalizedDescriptionKey: "Neural Engine model download failed"
        ])))
    }

    @Test func sentenceQueueAppliesBackpressureAndPreservesOrder() async throws {
        let queue = SentenceQueue(capacity: 1)
        let producer = Task {
            for text in ["One.", "Two.", "Three."] { try await queue.send(text) }
            await queue.finish()
        }
        var received: [String] = []
        while let text = try await queue.next() { received.append(text) }
        try await producer.value
        #expect(received == ["One.", "Two.", "Three."])
    }

    @Test func sentenceQueueCancellationReleasesProducer() async throws {
        let queue = SentenceQueue(capacity: 1)
        try await queue.send("One.")
        let producer = Task { try await queue.send("Two.") }
        await queue.cancel()
        await #expect(throws: CancellationError.self) {
            try await producer.value
        }
        await #expect(throws: CancellationError.self) {
            _ = try await queue.next()
        }
    }
}
