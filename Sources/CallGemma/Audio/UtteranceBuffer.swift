import Foundation

struct UtteranceBuffer {
    struct Completed {
        let samples: [Float]
        let reachedLimit: Bool
    }

    private var samples: [Float] = []
    private var firstSample = 0
    private var receivedSamples = 0
    private var speechStart: Int?
    private let maximumSamples: Int
    private let minimumSamples: Int
    private let retainedSamples: Int

    init(maximumSamples: Int = 30 * 16_000, minimumSamples: Int = 2_400,
         retainedSamples: Int = 4_096 + 1_600) {
        self.maximumSamples = maximumSamples
        self.minimumSamples = minimumSamples
        self.retainedSamples = retainedSamples
    }

    mutating func append(_ chunk: [Float], start: Int? = nil, end: Int? = nil) -> Completed? {
        samples.append(contentsOf: chunk)
        receivedSamples += chunk.count
        if let start { speechStart = max(firstSample, start) }
        if let speechStart {
            let reachedLimit = (end ?? receivedSamples) - speechStart >= maximumSamples
            if end != nil || reachedLimit {
                let stop = min(receivedSamples, end ?? receivedSamples, speechStart + maximumSamples)
                let result = Array(samples[(speechStart - firstSample)..<max(speechStart - firstSample, stop - firstSample)])
                self.speechStart = nil
                retainTail()
                return result.count >= minimumSamples ? Completed(samples: result, reachedLimit: reachedLimit) : nil
            }
        } else {
            retainTail()
        }
        return nil
    }

    /// Completion clears the retained speech range. A revoked speculative
    /// stream must still be restartable on that same frame, from the exact PCM.
    func streamingSnapshot(completed: Completed?) -> [Float]? {
        completed?.samples ?? snapshot()
    }

    func snapshot() -> [Float]? {
        guard let speechStart, receivedSamples - speechStart >= minimumSamples else { return nil }
        return Array(samples[(speechStart - firstSample)..<min(samples.count, speechStart - firstSample + maximumSamples)])
    }

    private mutating func retainTail() {
        let remove = max(0, samples.count - retainedSamples)
        samples.removeFirst(remove)
        firstSample += remove
    }
}
