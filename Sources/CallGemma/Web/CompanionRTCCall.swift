#if os(macOS)
import Foundation

/// Binds Opus ingress and rendered-output acknowledgements to the existing call
/// engine. Output remains PCM until the browser synthesis journal is integrated.
@MainActor
final class CompanionRTCCall {
    let id = UUID()
    let transport: RemoteCallTransport
    private(set) var closed = false
    private(set) var admitted = false
    private var started = false
    private var sequence = 0
    private var controlMessages = 0
    private var browserFailureRecorded = false
    private var output = CompanionRTCOutput()
    private var session: CompanionRTCSession?
    private var admissionDeadline: Task<Void, Never>?
    private var controlWatchdog: Task<Void, Never>?
    private var lastControl = ContinuousClock.now
    private var onClose: (() -> Void)?

    init(iceServers: Data, echoCancellation: Bool, onClose: @escaping () -> Void) throws {
        transport = RemoteCallTransport(echoCancellation: echoCancellation)
        self.onClose = onClose
        session = try CompanionRTCSession(iceServers: iceServers,
            audio: { [weak self] samples in
                guard let self, self.started, !self.closed else { return }
                let sequence = self.sequence; self.sequence += 1
                try await self.transport.receiveAudio(sequence: sequence, samples: samples)
            }, message: { [weak self] data in try self?.receive(data) },
            state: { [weak self] state in
                AudioTrace.latency.mark("rtc.state." + state)
                if state == "failed" || state == "closed" { self?.close(reason: "peer_" + state) }
            }, failure: { [weak self] error in
                NSLog("Blessenger RTC failure: %@", error.localizedDescription)
                self?.close(reason: "session_failure")
            })
        admissionDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, !self.started else { return }
            self.close(reason: "admission_timeout")
        }
    }

    func answer(_ offer: String) async throws -> String {
        guard !closed, let session else { throw GemmaError(message: "Connection closed.") }
        return try await session.answer(offer)
    }

    func signal(cursor: Int, candidates: [Any]) throws -> [String: Any] {
        guard !closed, let session, candidates.count <= 32 else { throw GemmaError(message: "Invalid signaling request.") }
        // Validate the read cursor before mutating candidate admission.
        let result = try session.localCandidates(after: cursor)
        for candidate in candidates { try session.addCandidate(JSONSerialization.data(withJSONObject: candidate)) }
        return ["cursor": result.next, "candidates": try result.values.map { try JSONSerialization.jsonObject(with: $0) }]
    }

    func start() throws {
        guard !closed, !started else { throw GemmaError(message: "Connection unavailable.") }
        started = true; admissionDeadline?.cancel(); admissionDeadline = nil
        lastControl = .now
        controlWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, !self.closed else { return }
                // The native playout device can supply silence after a peer is
                // lost. Audio callbacks alone cannot prove a phone is alive.
                if self.lastControl.duration(to: .now) > .seconds(5) { self.close(reason: "control_timeout"); return }
            }
        }
    }

    func didDial() { admitted = true }

    private func receive(_ data: Data) throws {
        guard !closed, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GemmaError(message: "Invalid call control.")
        }
        if object["end"] as? Bool == true { close(reason: "peer_end"); return }
        guard started else { return }
        controlMessages += 1
        if controlMessages == 1 { AudioTrace.latency.mark("rtc.first_control") }
        guard let raw = object["epoch"] as? String, let epoch = UUID(uuidString: raw),
              let acknowledged = object["acknowledged"] as? [Int] else { throw GemmaError(message: "Invalid playback acknowledgement.") }
        lastControl = .now
        let result = try transport.acknowledgePlayback(acknowledged, epoch: epoch)
        for message in try output.messages(result) { try session?.send(message) }
    }

    func recordBrowserFailure(detail: String, cause: Int) throws {
        guard detail.range(of: "^[a-z-]{1,48}$", options: .regularExpression) != nil,
              (-1...65535).contains(cause) else { throw GemmaError(message: "Invalid peer diagnostic.") }
        guard !browserFailureRecorded else { return }
        browserFailureRecorded = true
        AudioTrace.latency.mark("rtc.browser_failure." + detail,
            counts: ["sctp_cause": cause, "audio_frames": sequence, "control_messages": controlMessages])
        AudioTrace.latency.flush("rtc_browser_failure")
    }

    func close(reason: String = "requested") {
        guard !closed else { return }
        AudioTrace.latency.mark("rtc.close." + reason, counts: ["audio_frames": sequence, "control_messages": controlMessages])
        AudioTrace.latency.flush("rtc_closed")
        closed = true
        admissionDeadline?.cancel(); admissionDeadline = nil
        controlWatchdog?.cancel(); controlWatchdog = nil
        session?.close(); session = nil; transport.close()
        let callback = onClose; onClose = nil; callback?()
    }
}
/// Preserve a bounded playout lead without putting multiple PCM frames in one
/// oversized data-channel message. Heartbeats do not resend queued audio.
struct CompanionRTCOutput {
    private var epoch = ""
    private var sent = -1

    mutating func messages(_ snapshot: [String: Any]) throws -> [Data] {
        guard let nextEpoch = snapshot["epoch"] as? String,
              let packets = snapshot["packets"] as? [[String: Any]], packets.count <= 8 else {
            throw GemmaError(message: "Invalid playback snapshot.")
        }
        var nextSent = nextEpoch == epoch ? sent : -1
        var result: [Data] = []
        for packet in packets {
            guard let sequence = packet["sequence"] as? Int else { throw GemmaError(message: "Invalid playback sequence.") }
            if sequence <= nextSent { continue }
            var message = snapshot; message["packets"] = [packet]
            let data = try JSONSerialization.data(withJSONObject: message)
            guard data.count <= 65_536 else { throw GemmaError(message: "Playback packet too large.") }
            result.append(data); nextSent = sequence
        }
        if result.isEmpty {
            var message = snapshot; message["packets"] = []
            result.append(try JSONSerialization.data(withJSONObject: message))
        }
        epoch = nextEpoch; sent = nextSent
        return result
    }
}
#endif
