import Foundation

enum CallAudioEvent: Sendable {
    case input(UUID, [Float], begin: Bool)
    case speechStarted
    case candidate(UUID, [Float], endpointNS: UInt64)
    case confirmed(UUID)
    case resumed(UUID)
    case utterance([Float], endpointNS: UInt64) // Mono Float32 PCM at 16 kHz.
    case diagnostics(String)
    case notice(String)
}

enum CallAudioError: LocalizedError {
    case microphoneDenied
    case unavailable(String)
    case captureOverrun
    case capturePoolExhausted
    case captureBufferMismatch
    case captureQueueOverflow
    case eventOverrun
    case responseNotStarted
    case concurrentProducer
    case invalidVoice
    case aneFailedAfterAudio(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Allow microphone access in System Settings to start a call."
        case .unavailable(let reason):
            return reason
        case .captureOverrun:
            return "Microphone processing fell behind. Please restart the call."
        case .capturePoolExhausted:
            return "Microphone buffer pool exhausted. Please restart the call."
        case .captureBufferMismatch:
            return "The microphone supplied an unsupported buffer. Please restart the call."
        case .captureQueueOverflow:
            return "The microphone processing queue filled. Please restart the call."
        case .eventOverrun:
            return "The call could not keep up with microphone events. Please restart it."
        case .responseNotStarted:
            return "Start a speech response before adding text."
        case .concurrentProducer:
            return "Speech text must be submitted by one producer in order."
        case .invalidVoice:
            return "Select one to ten seconds of valid audio containing clear speech."
        case .aneFailedAfterAudio(let reason):
            return "Speech stopped after a Neural Engine failure. The next response will use the CPU. \(reason)"
        }
    }
}

/// Deliberately excludes generic Core ML, download, and malformed-input errors.
enum NeuralEngineFailure {
    static func isExplicit(_ error: Error) -> Bool {
        var pending = [(error as NSError, 0)]
        while let (current, depth) = pending.popLast(), depth < 8 {
            let detail = [current.localizedDescription, current.localizedFailureReason ?? "",
                          current.userInfo[NSDebugDescriptionErrorKey] as? String ?? ""]
                .joined(separator: " ").lowercased()
            let domain = current.domain.lowercased()
            if domain.contains("appleneuralengine") || domain == "com.apple.ane" {
                return true
            }
            if current.domain != NSURLErrorDomain && current.domain != NSCocoaErrorDomain {
                if detail.contains("aneprogramprocessrequestdirect") && detail.contains("status") {
                    return true
                }
                if domain == "com.apple.coreml", detail.contains("neural engine"),
                   ["failed", "failure", "error", "unavailable"].contains(where: { detail.contains($0) }) {
                    return true
                }
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append((underlying, depth + 1))
            }
        }
        return false
    }
}

/// The policy is persisted with each speech segment. Remove only the
/// leading quiet prefix, retain 2 ms before the first -40 dBFS sample,
/// and leave every later sample untouched. Work stops after the gate opens.
struct LeadingSilenceGate {
    private var open = false
    private let threshold: Float = 0.01
    private(set) var skippedFrames = 0
    mutating func process(_ samples: [Float]) -> [Float] {
        guard !open else { return samples }
        guard let signal = samples.firstIndex(where: { abs($0) >= threshold }) else {
            skippedFrames += samples.count
            return []
        }
        open = true
        let skip = max(0, signal - 48)
        skippedFrames += skip
        return Array(samples.dropFirst(skip))
    }
}

/// Segment boundaries are not spoken characters. A punctuation continuation of
/// the preceding segment attaches to it; ordinary word boundaries retain a space.
enum SpokenText {
    static func joinSegments(_ parts: [String]) -> String {
        parts.reduce(into: "") { result, part in
            guard !part.isEmpty else { return }
            if !result.isEmpty, let first = part.first, !",;:.!?)]}”’".contains(first) { result += " " }
            result += part
        }
    }
}

