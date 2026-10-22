import Foundation

/// One worker drains a bounded PCM FIFO; capture never waits for a model call.
/// Closing the input is a barrier over precisely the samples of the candidate.
actor StreamingAudioInput {
    private let runtime: GemmaRuntime
    private var chunks: [[Float]] = []
    private var total = 0
    private var closed = false
    private var cancelled = false
    private var worker: Task<Void, Error>?
    private var began = false
    private let barrier: @Sendable () async throws -> Void

    init(runtime: GemmaRuntime, barrier: @escaping @Sendable () async throws -> Void) {
        self.runtime = runtime
        self.barrier = barrier
    }

    func append(_ samples: [Float]) throws {
        guard !closed, !cancelled, !samples.isEmpty, samples.allSatisfy(\.isFinite),
              total + samples.count <= 480_000 else { throw CallAudioError.captureOverrun }
        total += samples.count
        chunks.append(samples)
        if worker == nil { worker = Task { try await self.drain() } }
    }

    private func drain() async throws {
        if !began {
            try await barrier()
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            try await runtime.beginAudioInput()
            began = true
        }
        while !chunks.isEmpty {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            let next = chunks.removeFirst()
            // The API cap is one second. A restarted utterance can supply a
            // larger retained prefix, so split it without padding or dropping.
            if next.count <= 16_000 {
                try await runtime.appendAudioInput(next)
                continue
            }
            for offset in stride(from: 0, to: next.count, by: 16_000) {
                try Task.checkCancellation()
                try await runtime.appendAudioInput(Array(next[offset..<min(next.count, offset + 16_000)]))
            }
        }
        worker = nil
    }

    func finish(expectedSamples: Int) async throws {
        guard !closed, !cancelled, total == expectedSamples else { throw CheckpointError.invalidMetadata }
        closed = true
        let start = LatencyTrace.now()
        try await worker?.value
        guard began else { throw CheckpointError.invalidMetadata }
        try await runtime.finishAudioInput()
        AudioTrace.latency.duration("prefill.endpoint_barrier", since: start)
    }

    @discardableResult
    func cancel() async -> Bool {
        cancelled = true
        chunks.removeAll()
        worker?.cancel()
        _ = try? await worker?.value
        worker = nil
        return began && !closed
    }
}
