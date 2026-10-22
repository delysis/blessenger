import Foundation
import Testing
@testable import CallGemma

struct SpeechEndpointTests {
    @Test func singleFrameConfirmationReportsTheFirstStrictCrossing() {
        var detector = SpeechEndpoint(silenceSamples: 256, speculationThreshold: 0.7)
        _ = detector.process(probability: 0.9, frames: 256)
        let speculative = detector.process(probability: 0.6, frames: 256)
        #expect(speculative.candidate != nil)
        #expect(speculative.end == nil)
        #expect(!speculative.silenceBegan)
        let confirmed = detector.process(probability: 0.4, frames: 256)
        #expect(confirmed.silenceBegan)
        #expect(confirmed.end == 512)
    }

    @Test func silenceDoesNotCreateSpeech() {
        var detector = SpeechEndpoint()
        for _ in 0..<100 {
            let event = detector.process(probability: 0, frames: 512)
            #expect(event.start == nil && event.end == nil)
        }
    }

    @Test func endpointIsUnpaddedAndHasBoundedDelay() {
        var detector = SpeechEndpoint()
        #expect(detector.process(probability: 0.9, frames: 512).start == 0)
        for _ in 0..<5 {
            #expect(detector.process(probability: 0.1, frames: 512).end == nil)
        }
        let event = detector.process(probability: 0.1, frames: 512)
        #expect(event.end == 512)
        #expect(event.processedSamples - event.end! == 3_072)
    }

    @Test func resumedSpeechAndAmbiguityCancelEndpoint() {
        var detector = SpeechEndpoint()
        _ = detector.process(probability: 0.9, frames: 512)
        for _ in 0..<5 { _ = detector.process(probability: 0.1, frames: 512) }
        #expect(detector.process(probability: 0.55, frames: 512).end == nil)
        for _ in 0..<5 {
            #expect(detector.process(probability: 0.1, frames: 512).end == nil)
        }
        #expect(detector.process(probability: 0.9, frames: 512).end == nil)
    }
}

struct SpeculativeEndpointTests {
    @Test func firstLowFrameStartsSpeculationWithoutEndingCapture() {
        var detector = SpeechEndpoint(silenceSamples: 1_536)
        _ = detector.process(probability: 0.9, frames: 256)
        let first = detector.process(probability: 0.49, frames: 256)
        #expect(first.candidate == 256)
        #expect(first.end == nil)
        for _ in 0..<4 {
            let next = detector.process(probability: 0.1, frames: 256)
            #expect(next.candidate == nil && next.end == nil)
        }
        #expect(detector.process(probability: 0.1, frames: 256).end == 256)
    }

    @Test func ambiguousFrameRevokesSpeculationAndPreservesUtterance() {
        var detector = SpeechEndpoint(silenceSamples: 1_536)
        var buffer = UtteranceBuffer(minimumSamples: 1)
        let start = detector.process(probability: 0.9, frames: 256)
        _ = buffer.append(Array(repeating: 1, count: 256), start: start.start)
        _ = detector.process(probability: 0.1, frames: 256)
        _ = buffer.append(Array(repeating: 0, count: 256))
        let first = buffer.snapshot()!
        #expect(detector.process(probability: 0.55, frames: 256).resumed)
        _ = buffer.append(Array(repeating: 2, count: 256))
        #expect(buffer.snapshot()!.prefix(first.count).elementsEqual(first))
        #expect(buffer.snapshot()!.count == 768)
    }

    @Test func earlySpeculationDoesNotMoveConfirmedBoundary() {
        var detector = SpeechEndpoint(silenceSamples: 1_536, speculationThreshold: 0.8)
        _ = detector.process(probability: 0.99, frames: 256)
        #expect(detector.process(probability: 0.79, frames: 256).candidate == 256)
        for p: Float in [0.73, 0.66, 0.59, 0.52] {
            let event = detector.process(probability: p, frames: 256)
            #expect(event.end == nil && !event.resumed && event.candidate == nil)
        }
        let strictStart = detector.processedSamples
        for _ in 0..<5 { #expect(detector.process(probability: 0.4, frames: 256).end == nil) }
        #expect(detector.process(probability: 0.4, frames: 256).end == strictStart)
    }

    @Test func reboundBelowTriggerRevokesFrozenInput() {
        var detector = SpeechEndpoint(silenceSamples: 1_536, speculationThreshold: 0.8)
        _ = detector.process(probability: 0.99, frames: 256)
        #expect(detector.process(probability: 0.7, frames: 256).candidate != nil)
        _ = detector.process(probability: 0.6, frames: 256)
        let rebound = detector.process(probability: 0.67, frames: 256)
        #expect(rebound.resumed && rebound.end == nil && rebound.candidate == nil)
        #expect(detector.process(probability: 0.6, frames: 256).candidate != nil)
    }

    @Test func speculationCannotChangeConfirmedSegmentation() {
        for threshold: Float in [0.7, 0.8, 0.9] {
            var baseline = SpeechEndpoint(silenceSamples: 1_536)
            var speculative = SpeechEndpoint(silenceSamples: 1_536, speculationThreshold: threshold)
            var state: UInt64 = 19
            for _ in 0..<20_000 {
                state = state &* 6364136223846793005 &+ 1
                let probability = Float((state >> 32) % 101) / 100
                let a = baseline.process(probability: probability, frames: 256)
                let b = speculative.process(probability: probability, frames: 256)
                #expect(a.start == b.start && a.end == b.end)
            }
        }
    }

    @Test @MainActor func revokedCandidateCannotAdmitPlayback() async throws {
        let gate = SpeculativeEndpoint(id: UUID())
        gate.revoke()
        try await gate.confirm()
        do { try await gate.wait(); Issue.record("Revoked candidate was admitted") }
        catch is CancellationError {} 
    }

    @Test @MainActor func confirmedCandidateIsImmediatelyAdmitted() async throws {
        let gate = SpeculativeEndpoint(id: UUID())
        try await gate.confirm()
        try await gate.wait()
    }
}

struct SpeculationOverlapTests {
    @Test func firstFrameStartsGenerationWhileStrictConfirmationRemainsPending() {
        var detector = SpeechEndpoint(silenceSamples: 256, speculationThreshold: 0.7)
        _ = detector.process(probability: 0.9, frames: 256)
        let early = detector.process(probability: 0.69, frames: 256)
        #expect(early.candidate == 256)
        #expect(early.end == nil && !early.silenceBegan)
        for p: Float in [0.64, 0.59, 0.54] {
            let event = detector.process(probability: p, frames: 256)
            #expect(event.candidate == nil && event.end == nil && !event.resumed)
        }
        let strict = detector.process(probability: 0.49, frames: 256)
        #expect(strict.silenceBegan && strict.end == 1_280)
    }

    @Test func reboundRevokesEarlyAttemptBeforeStrictConfirmation() {
        var detector = SpeechEndpoint(silenceSamples: 256, speculationThreshold: 0.7)
        _ = detector.process(probability: 0.9, frames: 256)
        #expect(detector.process(probability: 0.6, frames: 256).candidate != nil)
        let rebound = detector.process(probability: 0.8, frames: 256)
        #expect(rebound.resumed && rebound.end == nil)
        #expect(detector.process(probability: 0.6, frames: 256).candidate != nil)
    }
}

struct AcousticTailBoundaryTests {
    @Test func frozenInputIncludesCapturedTailBeforeAnyGeneration() {
        let tail = 1_600
        var detector = SpeechEndpoint(silenceSamples: tail, speculationThreshold: 0.7,
                                      candidateTailSamples: tail)
        var buffer = UtteranceBuffer(minimumSamples: 1)
        for _ in 0..<12 {
            let event = detector.process(probability: 0.9, frames: 256)
            _ = buffer.append(Array(repeating: 1, count: 256), start: event.start)
        }
        let boundary = detector.processedSamples
        var completed: UtteranceBuffer.Completed?
        for frame in 0..<7 {
            let event = detector.process(probability: 0.1, frames: 256)
            completed = buffer.append(Array(repeating: Float(frame + 2), count: 256),
                                      start: event.start, end: event.end.map { $0 + tail })
            #expect(event.speculationBegan == (frame == 0))
            if frame < 6 {
                #expect(event.candidate == nil)
                #expect(event.end == nil)
                #expect(completed == nil)
            } else {
                #expect(event.candidate == boundary)
                #expect(event.end == boundary)
            }
        }
        #expect(completed?.samples.count == boundary + tail)
        #expect(completed?.samples.suffix(64).allSatisfy { $0 == 8 } == true)
    }

    @Test func reboundDuringTailCollectionCannotFreezePartialWord() {
        var detector = SpeechEndpoint(silenceSamples: 1_600, speculationThreshold: 0.7,
                                      candidateTailSamples: 1_600)
        _ = detector.process(probability: 0.9, frames: 256)
        for _ in 0..<3 {
            let event = detector.process(probability: 0.1, frames: 256)
            #expect(event.candidate == nil && event.end == nil)
        }
        let resumed = detector.process(probability: 0.9, frames: 256)
        #expect(resumed.resumed && resumed.candidate == nil && resumed.end == nil)
        let newBoundary = detector.processedSamples
        for _ in 0..<6 { #expect(detector.process(probability: 0.1, frames: 256).candidate == nil) }
        #expect(detector.process(probability: 0.1, frames: 256).candidate == newBoundary)
    }
}
