import CoreML
import FluidAudio
import Foundation

actor SpeechOutput {
    private let audio: CallAudio
    private let cacheDirectory: URL
    private var manager: PocketTtsManager?
    private var voiceData: PocketTtsVoiceData?
    private struct VoiceKey: Hashable {
        let pcmDigest: String
        let cpuOnly: Bool
    }
    // Cloned prompts are immutable value data; sessions build their own state.
    // Bound retention while keeping the fourteen bundled contacts warm.
    private var voices: [VoiceKey: PocketTtsVoiceData] = [:]
    private var voiceOrder: [VoiceKey] = []
    private var voiceRequest = UUID()
    private(set) var voiceCloneCount = 0
    private var currentSession: PocketTtsSession?
    private var currentProducer: (segment: UUID, task: Task<Void, Error>)?
    private let liveAlignment = HeardTextAlignment()
    private var responseTask: Task<Void, Error>?
    private var queue: SentenceQueue?
    private var sentences = SentenceBuffer()
    private var responseID = UUID()
    private var traceTurn: UUID?
    private var journal: HeardTurnJournal?
    private var playbackAdmission: (@Sendable () async throws -> Void)?
    private var journalTurn: UUID?
    private var journalVoice: HeardTurnJournal.Voice?
    private var preparing = false
    private(set) var usesCPUFallback = false
    private(set) var lastCancellationTimings: [String: Double] = [:]

    init(audio: CallAudio, cacheDirectory: URL) {
        self.audio = audio
        self.cacheDirectory = AudioModelPins.pocketDirectory(in: cacheDirectory)
    }

    func prepare() async throws {
        if manager != nil {
            try await liveAlignment.prepare(modelDirectory: AudioModelPins.alignerDirectory)
            return
        }
        guard !preparing else { throw CallAudioError.unavailable("Speech models are still loading.") }
        preparing = true
        defer { preparing = false }
        do {
            manager = try await loadManager(cpuOnly: usesCPUFallback)
        } catch {
            guard !usesCPUFallback, Self.canRetryOnCPU(error) else { throw error }
            usesCPUFallback = true
            await audio.notice("PocketTTS reported a Neural Engine failure. Retrying on the CPU.")
            manager = try await loadManager(cpuOnly: true)
        }
        try await liveAlignment.prepare(modelDirectory: AudioModelPins.alignerDirectory)
    }

    /// Imports at most ten seconds and keeps the cloned conditioning in memory.
    /// Passing nil restores PocketTTS's built-in Alba voice.
    /// Commit persistent storage only after validation; a failure keeps the old voice.
    func setVoice(referenceAudio: URL?, commit: (@Sendable () throws -> Void)? = nil) async throws {
        let request = UUID()
        voiceRequest = request
        await cancel()
        try Task.checkCancellation()
        guard voiceRequest == request else { throw CancellationError() }
        guard let referenceAudio else {
            try commit?()
            voiceData = nil
            return
        }
        let access = referenceAudio.startAccessingSecurityScopedResource()
        defer { if access { referenceAudio.stopAccessingSecurityScopedResource() } }
        let samples = try VoiceSample.read(from: referenceAudio)
        let pcmDigest = samples.withUnsafeBytes { digest(Data($0)) }
        try await prepare()
        try Task.checkCancellation()
        guard voiceRequest == request else { throw CancellationError() }
        var key = VoiceKey(pcmDigest: pcmDigest, cpuOnly: usesCPUFallback)
        if let cached = voices[key] {
            try commit?()
            touchVoice(key)
            voiceData = cached
            return
        }
        try await AudioModelPins.prepareVoiceEncoder(at: cacheDirectory)
        try Task.checkCancellation()
        guard voiceRequest == request else { throw CancellationError() }
        let newVoice: PocketTtsVoiceData
        do {
            guard let manager else { throw CallAudioError.responseNotStarted }
            voiceCloneCount += 1
            newVoice = try await manager.cloneVoice(from: samples)
        } catch {
            try Task.checkCancellation()
            guard voiceRequest == request else { throw CancellationError() }
            guard !usesCPUFallback, Self.canRetryOnCPU(error) else { throw error }
            usesCPUFallback = true
            manager = nil
            await audio.notice("Voice conditioning reported a Neural Engine failure. Retrying on the CPU.")
            try await prepare()
            try Task.checkCancellation()
            guard voiceRequest == request else { throw CancellationError() }
            guard let manager else { throw CallAudioError.responseNotStarted }
            key = VoiceKey(pcmDigest: pcmDigest, cpuOnly: true)
            voiceCloneCount += 1
            newVoice = try await manager.cloneVoice(from: samples)
        }
        try Task.checkCancellation()
        guard voiceRequest == request else { throw CancellationError() }
        try commit?()
        voices[key] = newVoice
        touchVoice(key)
        voiceData = newVoice
    }

    private func touchVoice(_ key: VoiceKey) {
        voiceOrder.removeAll { $0 == key }
        voiceOrder.append(key)
        while voiceOrder.count > 16 {
            let evicted = voiceOrder.removeFirst()
            voices.removeValue(forKey: evicted)
        }
    }

    func beginResponse(traceTurn: UUID? = nil, journal: HeardTurnJournal? = nil,
                       turn: UUID? = nil, playbackAdmission: (@Sendable () async throws -> Void)? = nil) async throws {
        self.traceTurn = traceTurn
        await cancel()
        try await prepare()
        try Task.checkCancellation()
        guard (journal == nil) == (turn == nil) else { throw CheckpointError.invalidMetadata }
        self.playbackAdmission = playbackAdmission
        self.journal = journal
        journalTurn = turn
        journalVoice = try await journal?.voice(prompt: voiceData?.audioPrompt,
            tokens: voiceData?.promptLength ?? 0, cpuOnly: usesCPUFallback)
        let id = UUID()
        responseID = id
        if let journal, let turn {
            let audio = self.audio
            await audio.beginPlaybackResponse(id) { frame in
                Task {
                    do { try await journal.played(turn: turn, through: frame) }
                    catch { await audio.notice(error.localizedDescription) }
                }
            }
        } else { await audio.beginPlaybackResponse(id) }
        let pending = SentenceQueue()
        queue = pending
        sentences = SentenceBuffer()
        responseTask = Task { [weak self, audio] in
            do {
                while let sentence = try await pending.next() {
                    guard let self else { throw CancellationError() }
                    try await self.speak(sentence, id: id)
                }
                try await audio.drainPlayback()
            } catch {
                await pending.cancel(error)
                await self?.interruptIfCurrent(id)
                throw error
            }
        }

    }

    /// Await each call in token order. A full queue suspends the caller without dropping text.
    func append(_ delta: String) async throws {
        guard let queue else { throw CallAudioError.responseNotStarted }
        guard delta.utf8.count <= 65_536 else {
            throw CallAudioError.unavailable("A speech text chunk exceeded the supported size.")
        }
        let start = LatencyTrace.now()
        let ready = sentences.append(delta)
        AudioTrace.latency.duration("tts.text_buffer_scan", since: start)
        for sentence in ready {
            AudioTrace.latency.mark("tts.sentence_ready", turn: traceTurn)
            try await queue.send(sentence)
        }
    }

    /// Flushes the last partial sentence and waits until the last audio frame is audible.
    func finishResponse() async throws {
        guard let queue, let task = responseTask else { throw CallAudioError.responseNotStarted }
        let id = responseID
        if let tail = sentences.finish() {
            AudioTrace.latency.mark("tts.sentence_ready", turn: traceTurn)
            try await queue.send(tail)
        }
        await queue.finish()
        defer {
            if responseID == id {
                self.queue = nil
                responseTask = nil
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() async {
        let start = LatencyTrace.now()
        responseID = UUID()
        let task = responseTask
        let session = currentSession
        let producer = currentProducer
        let pending = queue
        responseTask = nil
        currentSession = nil
        currentProducer = nil
        queue = nil
        sentences = SentenceBuffer()
        let detached = LatencyTrace.now()
        task?.cancel()
        let taskCancelled = LatencyTrace.now()
        await audio.interruptPlayback()
        let stopped = LatencyTrace.now()
        await pending?.cancel()
        let unqueued = LatencyTrace.now()
        if let producer {
            let receipt = await audio.interruptedPlayback
            if journal == nil || receipt?.partialSegment != producer.segment {
                producer.task.cancel() // No heard fragment needs this reference.
                await session?.cancel()
            }
            _ = try? await producer.task.value
        }
        await session?.cancel()
        let sessionJoined = LatencyTrace.now()
        _ = try? await task?.value
        let joined = LatencyTrace.now()
        lastCancellationTimings = [
            "detach_ms": Double(detached - start) / 1e6,
            "task_cancel_ms": Double(taskCancelled - detached) / 1e6,
            "audio_stop_ms": Double(stopped - taskCancelled) / 1e6,
            "queue_cancel_ms": Double(unqueued - stopped) / 1e6,
            "tts_join_ms": Double(sessionJoined - unqueued) / 1e6,
            "speech_task_join_ms": Double(joined - sessionJoined) / 1e6
        ]
        for (name, value) in lastCancellationTimings {
            AudioTrace.latency.observe("cancellation." + name, milliseconds: value)
        }
    }

    func freezeHeardProgress() async throws {
        guard let journal, let journalTurn else { return }
        let frame = await audio.playbackPosition()
        try await journal.played(turn: journalTurn, through: frame, stop: true)
        try await journal.flush()
    }

    private func speak(_ text: String, id: UUID) async throws {
        var retried = false
        let segment = UUID()
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        if let journal, let journalTurn, let journalVoice {
            try await journal.beginSegment(turn: journalTurn, id: segment, text: text,
                                           seed: seed, voice: journalVoice, leadingSilencePolicy: 2)
        }
        while true {
            try Task.checkCancellation()
            guard responseID == id else { throw CancellationError() }
            try await prepare()
            // The public session API exposes delivery, not the private producer's compute interval.
            let interval = AudioTrace.signposter.beginInterval("Sentence synthesis stream",
                id: AudioTrace.signposter.makeSignpostID())
            defer { AudioTrace.signposter.endInterval("Sentence synthesis stream", interval) }
            var session: PocketTtsSession?
            var producer: Task<Void, Error>?
            var emittedAudio = false
            do {
                guard let manager else { throw CallAudioError.responseNotStarted }
                let sessionStart = LatencyTrace.now()
                AudioTrace.latency.mark("tts.session_start", turn: traceTurn)
                let created: PocketTtsSession
                if let voiceData { created = try await manager.makeSession(voiceData: voiceData, seed: seed) }
                else { created = try await manager.makeSession(seed: seed) }
                AudioTrace.latency.duration("tts.session_create", since: sessionStart)
                session = created
                guard responseID == id, !Task.isCancelled else {
                    await created.cancel()
                    throw CancellationError()
                }
                currentSession = created
                // Only one bounded sentence enters FluidAudio's unbounded session streams.
                AudioTrace.latency.mark("tts.enqueue", turn: traceTurn)
                created.enqueue(text)
                created.finish()
                let stream: AsyncThrowingStream<[Float], Error>
                if let journal, let journalTurn {
                    let reference = referenceStream(created, text: text, segment: segment, seed: seed,
                                                    journal: journal, turn: journalTurn)
                    producer = reference.task
                    currentProducer = (segment, reference.task)
                    stream = reference.stream
                } else {
                    let pair = AsyncThrowingStream<[Float], Error>.makeStream()
                    let forwarding = Task<Void, Error> {
                        do {
                            var gate = LeadingSilenceGate()
                            for try await frame in created.frames {
                                let samples = gate.process(frame.samples)
                                if !samples.isEmpty { pair.continuation.yield(samples) }
                            }
                            pair.continuation.finish()
                        } catch { pair.continuation.finish(throwing: error) }
                    }
                    producer = forwarding
                    currentProducer = (segment, forwarding)
                    stream = pair.stream
                }
                // Preserve segment/frame accounting while streaming synthesis to playback.
                try Task.checkCancellation()
                guard responseID == id else { throw CancellationError() }
                try await audio.beginPlaybackSegment(segment, text: text)
                for try await samples in stream {
                    try Task.checkCancellation()
                    guard responseID == id else { throw CancellationError() }
                    if !emittedAudio {
                        AudioTrace.latency.mark("tts.first_pcm", turn: traceTurn)
                        AudioTrace.signposter.emitEvent("First PCM frame received")
                    }
                    if let admission = playbackAdmission {
                        try await admission()
                        try Task.checkCancellation()
                        guard responseID == id else { throw CancellationError() }
                        playbackAdmission = nil
                        AudioTrace.latency.mark("playback.endpoint_admitted", turn: traceTurn)
                    }
                    try await audio.play(samples, firstFrameOfSentence: !emittedAudio,
                                         turn: traceTurn, segment: segment)
                    emittedAudio = true
                }
                // Cancellation can end AsyncThrowingStream normally. Preserve the
                // independent alignment producer for any audio already heard.
                try Task.checkCancellation()
                guard responseID == id else { throw CancellationError() }
                await created.cancel() // Join the producer, including its final Core ML call.
                guard responseID == id else { throw CancellationError() }
                try await audio.finishPlaybackSegment(segment)
                currentSession = nil
                currentProducer = nil
                return
            } catch {
                await audio.interruptPlayback()
                // A heard fragment needs a complete alignment reference. Its
                // independent producer can finish while playback is stopped.
                _ = try? await producer?.value
                await session?.cancel()
                if responseID == id { currentSession = nil }
                guard responseID == id, !usesCPUFallback, !retried, Self.canRetryOnCPU(error) else { throw error }
                usesCPUFallback = true
                manager = nil
                if emittedAudio {
                    // Retrying this sentence would repeat words the user already heard.
                    throw CallAudioError.aneFailedAfterAudio(error.localizedDescription)
                }
                // The recorded backend is part of reproducibility. A failed
                // journaled segment must be recovered before changing it.
                if journal != nil { throw error }
                retried = true
                await audio.notice("PocketTTS reported a Neural Engine failure. Retrying on the CPU.")
            }
        }
    }

    private func referenceStream(_ session: PocketTtsSession, text: String, segment: UUID, seed: UInt64,
                                 journal: HeardTurnJournal, turn: UUID)
        -> (stream: AsyncThrowingStream<[Float], Error>, task: Task<Void, Error>) {
        let pair = AsyncThrowingStream<[Float], Error>.makeStream()
        let aligner = liveAlignment
        let trace = traceTurn
        let task = Task.detached(priority: .userInitiated) {
            var reference: [Float] = []
            // Preserve the actual synthesized segment, including interrupted
            // fragments, separately from what was scheduled for playback.
            // Export after synthesis; no diagnostic disk I/O delays delivery.
            defer {
                if let root = AppQualificationEnvironment.root {
                    let captured = reference
                    Task.detached(priority: .utility) {
                        do {
                            let folder = root.appending(path: "Synthesis/" + turn.uuidString)
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
                            let base = folder.appending(path: segment.uuidString)
                            try captured.withUnsafeBytes {
                                try Data($0).write(to: base.appendingPathExtension("f32"), options: .atomic)
                            }
                            try Data(text.utf8).write(to: base.appendingPathExtension("txt"), options: .atomic)
                            let metadata = try JSONSerialization.data(withJSONObject: [
                                "seed": String(seed), "text": text,
                                "segment": segment.uuidString, "turn": turn.uuidString
                            ], options: [.sortedKeys])
                            try metadata.write(to: base.appendingPathExtension("json"), options: .atomic)
                        } catch {
                            AudioTrace.logger.error("Synthesis evidence export failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
            var gate = LeadingSilenceGate()
            var reportedTrim = false
            do {
                for try await frame in session.frames {
                    try Task.checkCancellation()
                    guard reference.count + frame.samples.count <= 24_000 * 60 else {
                        throw CheckpointError.invalidMetadata
                    }
                    let samples = gate.process(frame.samples)
                    guard !samples.isEmpty else { continue }
                    if !reportedTrim {
                        reportedTrim = true
                        AudioTrace.latency.mark("tts.first_pcm_ready", turn: trace)
                        AudioTrace.latency.observe("tts.leading_silence_removed", milliseconds: Double(gate.skippedFrames) / 24)
                    }
                    let admissionStart = LatencyTrace.now()
                    reference.append(contentsOf: samples)
                    try await journal.generated(turn: turn, segment: segment, samples: samples)
                    AudioTrace.latency.duration("tts.reference_admission", since: admissionStart)
                    pair.continuation.yield(samples)
                }
                try Task.checkCancellation()
                guard !reference.isEmpty else { throw CallAudioError.unavailable("Speech synthesis returned only silence.") }
                try await journal.generated(turn: turn, segment: segment, samples: [], complete: true)
                do {
                    let words = try await aligner.words(text: text, referencePCM: reference, sampleRate: 24_000,
                                                       modelDirectory: AudioModelPins.alignerDirectory)
                    let saved = words.map { word in
                        HeardTurnJournal.AlignedWord(endUTF8: text[..<word.textEnd].utf8.count,
                                                      endFrame: Int((word.endSeconds * 24_000).rounded()))
                    }
                    try await journal.aligned(turn: turn, segment: segment, words: saved)
                } catch {
                    // Fully played segments remain authoritative without word
                    // alignment. A partial recovery will surface this failure.
                    AudioTrace.logger.error("Live speech alignment unavailable: \(error.localizedDescription)")
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
                throw error
            }
        }
        return (pair.stream, task)
    }

    /// On-demand voice-note rendering uses the same voice, engine and clause
    /// boundaries as calls. PCM goes to the seekable note transport, not a file.
    func streamVoiceNote(_ text: String, receive: @Sendable ([Float]) async throws -> Void) async throws {
        try await prepare()
        guard let manager else { throw CallAudioError.responseNotStarted }
        var splitter = SentenceBuffer()
        var chunks = splitter.append(text)
        if let tail = splitter.finish() { chunks.append(tail) }
        for chunk in chunks {
            try Task.checkCancellation()
            let session: PocketTtsSession
            if let voiceData { session = try await manager.makeSession(voiceData: voiceData) }
            else { session = try await manager.makeSession() }
            session.enqueue(chunk); session.finish()
            var gate = LeadingSilenceGate()
            do {
                for try await frame in session.frames {
                    try Task.checkCancellation()
                    let samples = gate.process(frame.samples)
                    if !samples.isEmpty { try await receive(samples) }
                }
                await session.cancel()
            } catch { await session.cancel(); throw error }
        }
    }

    /// Rebuild a complete reference without routing any of it to playback.
    /// Use the original backend and conditioning; a caller verifies the PCM
    /// prefix hash before trusting alignment.
    func renderReference(_ segment: HeardTurnJournal.Segment, prompt: [Float]?) async throws -> [Float] {
        guard responseTask == nil else {
            throw GemmaError(message: "Speech recovery cannot run during a response.")
        }
        guard segment.voice.pocketRevision == AudioModelPins.pocket,
              segment.voice.conditionerIdentity == nil || segment.voice.conditionerIdentity == PocketSpeechAssets.identity
        else { throw CheckpointError.invalidMetadata }
        let referenceManager: PocketTtsManager
        if segment.voice.conditionerIdentity == nil {
            // Old records retain their original 256-wide conditioner. The
            // caller still verifies the regenerated PCM hash before alignment.
            referenceManager = try await loadManager(cpuOnly: segment.voice.cpuOnly,
                directoryOverride: AudioModelPins.legacyPocketDirectory)
        } else if segment.voice.cpuOnly == usesCPUFallback, let manager { referenceManager = manager }
        else { referenceManager = try await loadManager(cpuOnly: segment.voice.cpuOnly) }
        let session: PocketTtsSession
        if let prompt {
            let voice = PocketTtsVoiceData(audioPrompt: prompt, promptLength: segment.voice.promptTokens)
            session = try await referenceManager.makeSession(voiceData: voice, seed: segment.seed)
        } else { session = try await referenceManager.makeSession(seed: segment.seed) }
        session.enqueue(segment.text)
        session.finish()
        guard segment.leadingSilencePolicy == 2 else {
            await session.cancel()
            throw CheckpointError.invalidMetadata
        }
        var gate = LeadingSilenceGate()
        var samples: [Float] = []
        do {
            for try await frame in session.frames {
                try Task.checkCancellation()
                guard samples.count + frame.samples.count <= 24_000 * 60 else {
                    throw CheckpointError.invalidMetadata
                }
                samples.append(contentsOf: gate.process(frame.samples))
            }
            await session.cancel()
            return samples
        } catch {
            await session.cancel()
            throw error
        }
    }

    private func loadManager(cpuOnly: Bool, directoryOverride: URL? = nil) async throws -> PocketTtsManager {
        let modelDirectory = directoryOverride ?? cacheDirectory
        try await AudioModelPins.preparePocketCache(at: modelDirectory)
        // `.ane` chooses rank-4 assets. Overrides keep EVERY stage off the GPU.
        // Reuse these same assets on CPU fallback; no second model download is needed.
        let units = cpuOnly ? PocketTtsComputeUnits.uniform(.cpuOnly) : PocketTtsComputeUnits(
            conditioner: .cpuAndNeuralEngine, flowLM: .cpuAndNeuralEngine,
            flowDecoder: .cpuAndNeuralEngine, mimiDecoder: .cpuOnly,
            // This pinned encoder crashes during ANE compilation on the Mac.
            // Voice import is infrequent; CPU execution avoids that process crash.
            mimiEncoder: .cpuOnly)
        let candidate = PocketTtsManager(directory: modelDirectory, placement: .ane, computeUnits: units)
        try await candidate.initialize()
        try Task.checkCancellation()
        return candidate
    }

    private func interruptIfCurrent(_ id: UUID) async {
        if responseID == id { await audio.interruptPlayback() }
    }

    private static func canRetryOnCPU(_ error: Error) -> Bool {
        guard !Task.isCancelled, !(error is CancellationError) else { return false }
        if let pocketError = error as? PocketTTSError {
            switch pocketError {
            case .downloadFailed, .corruptedModel, .modelNotFound: return false
            case .processingFailed: break
            }
        }
        return NeuralEngineFailure.isExplicit(error)
    }
}
