import CEarshot
import Foundation

/// Pinned Earshot detector. The C boundary receives exactly one 16 ms frame.
/// The actor owns its state; epoch changes reset it before consuming new audio.
actor StreamingVAD {
    static let chunkSize = 256
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer
        private let storage: UnsafeMutableRawPointer
        init() throws {
            storage = .allocate(byteCount: ESVoiceActivityDetectorSize(), alignment: 64)
            pointer = OpaquePointer(storage)
            ESVoiceActivityDetectorInit(pointer)
        }
        deinit { storage.deallocate() }
    }
    private let handle: Handle
    private var epoch: UUID?

    init() throws { handle = try Handle() }

    func process(_ samples: [Float], epoch: UUID) throws -> Float {
        guard samples.count == Self.chunkSize else {
            AudioTrace.latency.mark("vad.invalid_frame_length", counts: ["samples": samples.count])
            throw CallAudioError.unavailable("VAD received \(samples.count) samples; expected \(Self.chunkSize).")
        }
        if let index = samples.firstIndex(where: { !$0.isFinite }) {
            let nonfinite = samples.filter { !$0.isFinite }.count
            let overrange = samples.filter { $0.isFinite && !(-1...1).contains($0) }.count
            // Preserve an exact rejected frame only in the opted-in local test
            // directory. The ordinary latency trace must not contain voice data.
            if let path = ProcessInfo.processInfo.environment["BLESSENGER_QUALIFICATION_DIRECTORY"] {
                let folder = URL(fileURLWithPath: path).appending(path: "RejectedVAD")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    try samples.withUnsafeBytes {
                        try Data($0).write(to: folder.appending(path: UUID().uuidString + ".f32"))
                    }
                } catch {
                    AudioTrace.logger.error("Rejected VAD frame export failed: \(error.localizedDescription)")
                }
            }
            AudioTrace.latency.mark("vad.invalid_samples", counts: [
                "nonfinite": nonfinite, "overrange": overrange, "first_index": index])
            let reason = nonfinite > 0 ? "non-finite" : "outside ±1"
            throw CallAudioError.unavailable("VAD input is \(reason): sample \(index) = \(samples[index]); \(nonfinite) non-finite, \(overrange) outside ±1.")
        }
        if self.epoch != epoch {
            ESVoiceActivityDetectorReset(handle.pointer)
            self.epoch = epoch
        }
        // Float PCM from voice processing/resampling can exceed full scale.
        // Earshot requires normalized PCM: saturate its input, without changing
        // the original capture or applying frame-dependent gain normalization.
        let overrange = samples.filter { !(-1...1).contains($0) }.count
        let detectorSamples: [Float]
        if overrange > 0 {
            AudioTrace.latency.mark("vad.input_saturated", counts: ["samples": overrange])
            detectorSamples = samples.map { min(1, max(-1, $0)) }
        } else {
            detectorSamples = samples
        }
        let probability = detectorSamples.withUnsafeBufferPointer {
            ESVoiceActivityDetectorPredictF32(handle.pointer, $0.baseAddress!, $0.count)
        }
        guard probability.isFinite, (0...1).contains(probability) else {
            throw CallAudioError.unavailable("The voice detector returned an invalid probability.")
        }
        return probability
    }
}
