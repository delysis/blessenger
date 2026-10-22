import Foundation

/// A call-scoped, bounded PCM transport. Delivery is confirmed by the browser's
/// audio renderer, never by a successful HTTP write. Epoch changes discard old sound.
@MainActor
final class RemoteCallTransport {
    struct Packet {
        let sequence: Int
        let samples: [Float]
        let completed: () -> Void
    }
    let id = UUID()
    let echoCancellation: Bool
    init(echoCancellation: Bool) { self.echoCancellation = echoCancellation }
    private(set) var epoch = UUID()
    private(set) var closed = false
    private var packets: [Packet] = []
    private var nextOutput = 0
    private var nextInput = 0
    private var receiving = false
    private var lastSeen = Date()
    private var watchdog: Task<Void, Never>?
    var input: (([Float]) async throws -> Void)?
    var failure: ((Error) -> Void)?

    func start() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.closed else { return }
                if Date().timeIntervalSince(self.lastSeen) > 5 {
                    self.failure?(GemmaError(message: "The phone audio connection was lost."))
                    self.close(); return
                }
            }
        }
    }
    func enqueue(_ samples: [Float], completed: @escaping () -> Void) throws {
        guard !closed, packets.count < 8 else { throw CallAudioError.captureOverrun }
        packets.append(Packet(sequence: nextOutput, samples: samples, completed: completed))
        nextOutput += 1
    }
    func exchange(sequence: Int, samples: [Float], acknowledged: [Int], epoch: UUID) async throws -> [String: Any] {
        try validateInput(sequence: sequence, samples: samples)
        let acceptedCount = try validateAcknowledgements(acknowledged, epoch: epoch)
        // Both halves are validated before either mutates state. The HTTP path
        // retains its atomic admission even though RTC delivers them separately.
        admitInput()
        commitAcknowledgements(acceptedCount)
        try await consumeAdmittedInput(samples)
        return snapshot()
    }

    /// Opus ingress has its own sequence; control/render acknowledgements must
    /// continue draining while the model is consuming an earlier audio frame.
    func receiveAudio(sequence: Int, samples: [Float]) async throws {
        try validateInput(sequence: sequence, samples: samples)
        admitInput()
        try await consumeAdmittedInput(samples)
    }

    private func admitInput() {
        receiving = true
        nextInput += 1
        lastSeen = Date()
    }

    private func consumeAdmittedInput(_ samples: [Float]) async throws {
        defer { receiving = false }
        if !samples.isEmpty { try await input?(samples) }
    }

    func acknowledgePlayback(_ acknowledged: [Int], epoch: UUID, limit: Int = 8) throws -> [String: Any] {
        guard !closed else { throw GemmaError(message: "Call expired.") }
        let acceptedCount = try validateAcknowledgements(acknowledged, epoch: epoch)
        commitAcknowledgements(acceptedCount)
        lastSeen = Date()
        return snapshot(limit: limit)
    }

    private func validateInput(sequence: Int, samples: [Float]) throws {
        guard !closed, !receiving, sequence == nextInput, samples.count <= 3_200,
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }) else {
            throw GemmaError(message: "Phone audio sequence is invalid.")
        }
    }

    private func validateAcknowledgements(_ acknowledged: [Int], epoch: UUID) throws -> Int {
        // Validate the entire batch before advancing input or committing any
        // rendered audio. A malformed suffix must not partially accept a request.
        let acceptedCount = epoch == self.epoch ? acknowledged.count : 0
        guard acknowledged.count <= 8, acceptedCount <= packets.count,
              zip(acknowledged.prefix(acceptedCount), packets).allSatisfy({ $0.0 == $0.1.sequence }) else {
            throw GemmaError(message: "Phone playback acknowledgement is out of order.")
        }
        return acceptedCount
    }

    private func commitAcknowledgements(_ acceptedCount: Int) {
        let completed = Array(packets.prefix(acceptedCount))
        packets.removeFirst(acceptedCount)
        for packet in completed { packet.completed() }
    }

    private func snapshot(limit: Int = 8) -> [String: Any] {
        return ["id": id.uuidString, "epoch": self.epoch.uuidString, "closed": closed,
                "packets": packets.prefix(max(0, min(8, limit))).map { ["sequence": $0.sequence, "samples": $0.samples] as [String: Any] }]
    }
    func cancelPlayback() { epoch = UUID(); packets.removeAll() }
    func close() { closed = true; watchdog?.cancel(); watchdog = nil; cancelPlayback(); input = nil; failure = nil }
}
