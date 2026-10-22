#if os(macOS)
import Foundation
import CompanionRTC

/// One peer lifetime. The owner authenticates signaling and supplies handlers;
/// no native callback creates a Task or an unbounded main-actor backlog.
@MainActor
final class CompanionRTCSession {
    let id = UUID()
    private(set) var closed = false
    private var peer: BGCompanionPeer?
    private var consumer: Task<Void, Never>?
    private var audioConsumer: Task<Void, Never>?
    private let inbox = CompanionRTCInbox(capacity: 64)
    private let audioInbox = CompanionRTCInbox(capacity: 50)
    private var candidates: [Data] = []
    private var candidateBytes = 0
    private var failure: ((Error) -> Void)?

    init(iceServers: Data, relayOnly: Bool = false,
         audio: @escaping ([Float]) async throws -> Void,
         message: @escaping (Data) async throws -> Void,
         state: @escaping (String) -> Void,
         failure: @escaping (Error) -> Void) throws {
        self.failure = failure
        let inbox = self.inbox, audioInbox = self.audioInbox
        peer = try BGCompanionPeer(iceServers: iceServers, relayOnly: relayOnly,
            message: { inbox.submit(.message($0)) },
            audio: { if !audioInbox.submit(.audio($0)) { inbox.submit(.overflow) } },
            candidate: { inbox.submit(.candidate($0)) },
            state: { inbox.submit(.state($0)) })
        consumer = Task { [weak self] in
            for await event in inbox.events {
                guard let self, !self.closed else { return }
                do {
                    try inbox.check()
                    switch event {
                    case .overflow: throw GemmaError(message: "WebRTC input buffer exhausted.")
                    case .audio: throw GemmaError(message: "Audio on control queue.")
                    case .message(let data): try await message(data)
                    case .candidate(let data):
                        guard self.candidates.count < 256, self.candidateBytes + data.count <= 262_144 else {
                            throw GemmaError(message: "Too many WebRTC candidates.")
                        }
                        self.candidates.append(data); self.candidateBytes += data.count
                    case .state(let value): state(value)
                    }
                } catch { self.fail(error); return }
            }
            // Overflow finishes the stream even if the consumer was suspended.
            guard let self, !self.closed else { return }
            do { try inbox.check() } catch { self.fail(error) }
        }
        // Model consumption can suspend. Control/cancellation must still drain.
        audioConsumer = Task { [weak self] in
            for await event in audioInbox.events {
                guard let self, !self.closed else { return }
                do {
                    try audioInbox.check()
                    guard case .audio(let data) = event, data.count == 320 else {
                        throw GemmaError(message: "Invalid WebRTC audio frame.")
                    }
                    let samples = data.withUnsafeBytes { bytes in
                        (0..<160).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
                    }
                    try await audio(samples)
                } catch { self.fail(error); return }
            }
            guard let self, !self.closed else { return }
            do { try audioInbox.check() } catch { self.fail(error) }
        }

    }

    func answer(_ offer: String) async throws -> String {
        guard !closed, let peer else { throw GemmaError(message: "Connection closed.") }
        let answer: String = try await withCheckedThrowingContinuation { continuation in
            peer.answerOffer(offer) { answer, error in
                if let error { continuation.resume(throwing: error) }
                else if let answer { continuation.resume(returning: answer) }
                else { continuation.resume(throwing: GemmaError(message: "Missing WebRTC answer.")) }
            }
        }
        guard !closed else { throw GemmaError(message: "Connection closed.") }
        return answer
    }

    func addCandidate(_ data: Data) throws {
        guard !closed, peer?.addRemoteCandidate(data) == true else {
            throw GemmaError(message: "WebRTC candidate rejected.")
        }
    }

    /// Cursor reads are repeatable: a lost HTTPS response cannot lose candidates.
    func localCandidates(after cursor: Int) throws -> (next: Int, values: [Data]) {
        guard !closed, (0...candidates.count).contains(cursor) else {
            throw GemmaError(message: "Invalid WebRTC candidate cursor.")
        }
        return (candidates.count, Array(candidates.dropFirst(cursor)))
    }

    func send(_ data: Data) throws {
        guard !closed, peer?.sendMessage(data) == true else {
            throw GemmaError(message: "WebRTC control channel unavailable.")
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        inbox.close(); audioInbox.close()
        consumer?.cancel(); consumer = nil
        audioConsumer?.cancel(); audioConsumer = nil
        peer?.close(); peer = nil
        candidates.removeAll(); candidateBytes = 0; failure = nil
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        let callback = failure
        close()
        callback?(error)
    }
}

/// Thread-safe bridge ingress. A full queue fails the entire session instead of
/// dropping speech or delaying cancellation behind an arbitrarily long backlog.
final class CompanionRTCInbox: @unchecked Sendable {
    enum Event: Sendable { case audio(Data), message(Data), candidate(Data), state(String), overflow }
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let lock = NSLock()
    private var closed = false
    private var overflowed = false

    init(capacity: Int = 96) {
        precondition(capacity > 0)
        let stream = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        events = stream.stream; continuation = stream.continuation
    }

    @discardableResult
    func submit(_ event: Event) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        switch continuation.yield(event) {
        case .dropped:
            overflowed = true; closed = true; continuation.finish()
        case .terminated: closed = true
        case .enqueued: return true
        @unknown default:
            overflowed = true; closed = true; continuation.finish()
        }
        return false
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if overflowed { throw GemmaError(message: "WebRTC input buffer exhausted.") }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; continuation.finish()
    }
}
#endif
