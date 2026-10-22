import Foundation

/// Counts callback-confirmed PCM, independently of generation and synthesis.
/// The caller supplies the delivery cursor; this does not measure acoustic hearing.
/// Partial segments deliberately retain audio rather than guessing word timing.
struct PlaybackLedger {
    struct Segment: Sendable {
        let id: UUID
        let text: String
        let start: Int64
        var samples: [Float] = []
        var sealed = false
    }

    struct Receipt: Sendable {
        let response: UUID
        let completedText: [String]
        let partialText: String?
        let partialPCM: [Float]
        let partialSegment: UUID?
        let partialReferencePCM: [Float]
        let partialReferenceComplete: Bool
        let deliveredFrames: Int64
        let scheduledFrames: Int64
    }

    let response: UUID
    private(set) var scheduledFrames: Int64 = 0
    private(set) var deliveredFrames: Int64 = 0
    private var segments: [Segment] = []
    private var completedText: [String] = []

    mutating func beginSegment(_ id: UUID, text: String) throws {
        guard segments.last?.sealed != false, !segments.contains(where: { $0.id == id }) else {
            throw CallAudioError.unavailable("Speech segment ordering is invalid.")
        }
        segments.append(Segment(id: id, text: text, start: scheduledFrames))
    }

    mutating func schedule(_ samples: [Float], segment: UUID) throws -> Int64 {
        guard let index = segments.indices.last, segments[index].id == segment,
              !segments[index].sealed, !samples.isEmpty,
              samples.allSatisfy(\.isFinite) else {
            throw CallAudioError.unavailable("Speech PCM has no open segment.")
        }
        // The synthesis text cap bounds a segment; refuse unbounded model output.
        guard segments[index].samples.count + samples.count <= 24_000 * 60 else {
            throw CallAudioError.unavailable("A speech segment exceeded one minute.")
        }
        segments[index].samples.append(contentsOf: samples)
        scheduledFrames += Int64(samples.count)
        return scheduledFrames
    }

    mutating func seal(_ id: UUID) throws {
        guard let index = segments.indices.last, segments[index].id == id,
              !segments[index].sealed else {
            throw CallAudioError.unavailable("Speech segment completion is out of order.")
        }
        segments[index].sealed = true
        retireCompleted()
    }

    mutating func delivered(through frame: Int64, response id: UUID) {
        guard id == response else { return }
        deliveredFrames = max(deliveredFrames, min(scheduledFrames, max(0, frame)))
        retireCompleted()
    }

    func receipt() -> Receipt {
        let partial = segments.first { $0.start < deliveredFrames }
        let count = partial.map { min($0.samples.count, Int(deliveredFrames - $0.start)) } ?? 0
        return Receipt(response: response, completedText: completedText,
                       partialText: count > 0 ? partial?.text : nil,
                       partialPCM: partial.map { Array($0.samples.prefix(count)) } ?? [],
                       partialSegment: count > 0 ? partial?.id : nil,
                       partialReferencePCM: count > 0 ? partial?.samples ?? [] : [],
                       partialReferenceComplete: count > 0 && partial?.sealed == true,
                       deliveredFrames: deliveredFrames, scheduledFrames: scheduledFrames)
    }

    private mutating func retireCompleted() {
        while let first = segments.first, first.sealed,
              first.start + Int64(first.samples.count) <= deliveredFrames {
            if !first.samples.isEmpty { completedText.append(first.text) }
            segments.removeFirst() // Release completed PCM, retain only its text.
        }
    }
}
