import Foundation

/// All positions are in the original 16 kHz capture timeline, without padding.
struct SpeechEndpoint {
    struct Result {
        let start: Int?
        let end: Int?
        let candidate: Int?
        let speculationBegan: Bool
        let resumed: Bool
        let silenceBegan: Bool
        let processedSamples: Int
    }

    private(set) var processedSamples = 0
    private var speaking = false
    private var silenceStart: Int?
    private var speculating = false
    private var candidateStart: Int?
    private var candidateReported = false
    let candidateTailSamples: Int
    private var lowestProbability: Float = 1
    let speculationThreshold: Float
    let silenceSamples: Int
    let speechThreshold: Float
    let silenceThreshold: Float

    init(silenceSamples: Int = 3_072, speechThreshold: Float = 0.65, silenceThreshold: Float = 0.5, speculationThreshold: Float? = nil, candidateTailSamples: Int = 0) {
        self.candidateTailSamples = max(0, candidateTailSamples)
        self.speculationThreshold = max(silenceThreshold, speculationThreshold ?? silenceThreshold)
        self.silenceSamples = silenceSamples
        self.speechThreshold = speechThreshold
        self.silenceThreshold = silenceThreshold
    }

    mutating func process(probability: Float, frames: Int) -> Result {
        let frameStart = processedSamples
        processedSamples += frames
        var start: Int?
        var end: Int?
        var candidate: Int?
        let silenceBegan = speaking && probability < silenceThreshold && silenceStart == nil
        // A declining score can start generation without ending capture. A
        // rebound invalidates the frozen speculative input, retaining all PCM
        // for the next attempt. Once strict silence starts, use its stricter
        // threshold for revocation as well.
        let resumed = speaking && speculating &&
            (probability >= speculationThreshold ||
             probability >= lowestProbability + 0.05 ||
             (silenceStart != nil && probability >= silenceThreshold))
        if resumed { speculating = false; candidateStart = nil; candidateReported = false }
        let speculationBegan = speaking && !speculating && !resumed && probability < speculationThreshold
        if speculationBegan {
            candidateStart = frameStart
            candidateReported = false
            speculating = true
            lowestProbability = probability
        }
        if speculating {
            lowestProbability = min(lowestProbability, probability)
            if !candidateReported, let candidateStart,
               processedSamples - candidateStart >= candidateTailSamples {
                candidate = candidateStart
                candidateReported = true
            }
        }
        if probability >= speechThreshold {
            silenceStart = nil
            if !speaking {
                speaking = true
                start = max(0, frameStart - 1_600)
            }
        } else if speaking, probability < silenceThreshold {
            if silenceStart == nil { silenceStart = frameStart }
            if let silenceStart, processedSamples - silenceStart >= silenceSamples {
                end = silenceStart
                speaking = false
                speculating = false
                self.silenceStart = nil
            }
        } else if speaking {
            // Ambiguous frames cannot count as uninterrupted silence.
            silenceStart = nil
        }
        return Result(start: start, end: end, candidate: candidate, speculationBegan: speculationBegan, resumed: resumed, silenceBegan: silenceBegan, processedSamples: processedSamples)
    }
}
