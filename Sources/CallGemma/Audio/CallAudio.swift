@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os
import Synchronization

/// Silence only hosted automation, at the final mixer. Rendering, scheduling,
/// completion callbacks, and inference still run. Acoustic tests opt in explicitly.
enum AutomatedAudioOutput {
    static let volume: Float = {
        let environment = ProcessInfo.processInfo.environment
        return (environment["CALL_GEMMA_TEST_HOST"] == "1" || AppQualificationEnvironment.root != nil)
            && environment["CALL_GEMMA_TEST_AUDIBLE"] != "1" ? 0 : 1
    }()
}

/// The tap owns a deep copy; only the single resampler consumer subsequently reads it.
final class CapturedBuffer: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
    let arrivalNS: UInt64
    let hostTime: UInt64?
    private let release: (@Sendable () -> Void)?
    init(pcm: AVAudioPCMBuffer, arrivalNS: UInt64 = LatencyTrace.now(),
         hostTime: UInt64? = nil, release: (@Sendable () -> Void)? = nil) {
        self.pcm = pcm; self.arrivalNS = arrivalNS; self.hostTime = hostTime; self.release = release
    }
    deinit { release?() }
}

/// Preallocate outside the render callback. A lease returns the buffer only
/// after the resampler (or a cancelled stream) releases its last reference.
final class CaptureBufferPool: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let leased = Atomic<Bool>(false)
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
    private let slots: [Slot]

    init(format: AVAudioFormat) throws {
        var slots: [Slot] = []
        for _ in 0..<32 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw CallAudioError.unavailable("Cannot allocate microphone buffers.")
            }
            slots.append(Slot(buffer))
        }
        self.slots = slots
    }
    func take() -> AVAudioPCMBuffer? {
        // Releasing another lease must not look like exhaustion. Each fixed
        // slot has independent ownership; no lock or allocation on capture.
        for slot in slots {
            if slot.leased.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged {
                return slot.buffer
            }
        }
        return nil
    }
    func recycle(_ buffer: AVAudioPCMBuffer) {
        guard let slot = slots.first(where: { $0.buffer === buffer }) else {
            preconditionFailure("A microphone buffer belongs to a different pool.")
        }
        slot.leased.store(false, ordering: .releasing)
    }
}

actor CaptureResampler {
    private var converter: AVAudioConverter?
    private var conversionBuffer: AVAudioPCMBuffer?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                      channels: 1, interleaved: false)!

    func process(_ captured: CapturedBuffer) throws -> [Float] {
        let processingStart = LatencyTrace.now()
        AudioTrace.latency.duration("capture.queue", since: captured.arrivalNS)
        defer { AudioTrace.latency.duration("capture.convert", since: processingStart) }
        let input = captured.pcm
        AudioTrace.latency.observe("capture.buffer_span", milliseconds: Double(input.frameLength) / input.format.sampleRate * 1000)
        if let hostTime = captured.hostTime {
            let age = Double(captured.arrivalNS) / 1e9 - AVAudioTime.seconds(forHostTime: hostTime)
            AudioTrace.latency.observe("capture.sample_age_at_delivery", milliseconds: age * 1000)
        }
        guard input.format.sampleRate.isFinite, input.format.sampleRate > 0 else {
            throw CallAudioError.unavailable("The microphone sample rate changed unexpectedly.")
        }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
            converter?.primeMethod = .none
            // VoiceProcessingIO exposes an aggregate channel layout on macOS.
            // Select its microphone channel explicitly; the converter's implicit
            // multichannel downmix can yield silence for this layout.
            converter?.channelMap = [0]
        }
        guard let converter else { throw CallAudioError.unavailable("Cannot convert microphone audio to 16 kHz.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 64
        if conversionBuffer == nil || conversionBuffer!.frameCapacity < capacity {
            conversionBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        }
        guard let output = conversionBuffer else {
            throw CallAudioError.unavailable("Cannot allocate the microphone conversion buffer.")
        }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var samples: [Float] = []
        samples.reserveCapacity(Int(capacity))
        for _ in 0..<16 {
            var error: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &error) { _, state in
                let alreadySupplied = supplied.withLock { value in
                    if value { return true }
                    value = true
                    return false
                }
                if alreadySupplied {
                    state.pointee = .noDataNow
                    return nil
                }
                state.pointee = .haveData
                return input
            }
            if let error { throw error }
            guard status != .error else { throw CallAudioError.unavailable("Microphone conversion failed.") }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status != .haveData { return samples }
        }
        throw CallAudioError.unavailable("The microphone converter did not finish its input buffer.")
    }
}

/// Prepared independently of the microphone and model so dialing can sound
/// immediately. It never enters the assistant transcript.
@MainActor
final class CallRingback {
    private var player: AVAudioPlayer?
    init() {
        let samples = (0..<48_000).map { index -> Float in
            guard index < 9_600 else { return 0 }
            let t = Double(index) / 16_000
            let envelope = min(1, min(Double(index), Double(9_599 - index)) / 160)
            return Float(0.035 * envelope * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t)))
        }
        if let data = try? WaveFile.encode(samples: samples) {
            player = try? AVAudioPlayer(data: data)
            player?.volume = AutomatedAudioOutput.volume
            player?.numberOfLoops = -1
            player?.prepareToPlay()
        }
    }
    func start() {
        if AppQualificationEnvironment.root != nil,
           ProcessInfo.processInfo.environment["BLESSENGER_QUALIFICATION_NO_RINGBACK"] == "1" { return }
        player?.currentTime = 0
        player?.play()
        AudioTrace.latency.mark("call.ring_requested")
    }
    func stop() { player?.stop() }
}

/// Hardware lifecycle is owned by PreparedAudioEngine. The main actor schedules
/// and interrupts player buffers; it never configures or starts the engine.
private struct ConfiguredCallEngine: @unchecked Sendable {
    let engine: AVAudioEngine
    let player: AVAudioPlayerNode
    let sink: AVAudioSinkNode
    let echoCancellation: Bool
    var idleInputFormat: AVAudioFormat
    var idleOutputFormat: AVAudioFormat

    var idleFormatsMatch: Bool {
        idleInputFormat.isEqual(engine.inputNode.outputFormat(forBus: 0)) &&
        (idleOutputFormat.sampleRate == 0 ||
         idleOutputFormat.isEqual(engine.outputNode.outputFormat(forBus: 0)))
    }
}

// The render callback has no per-call ownership. A stopped engine can be reused
// without retaining a finished stream or delivering samples to the next call.
private final class CaptureRelay: @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<CapturedBuffer, Error>.Continuation
    let callbacks = OSAllocatedUnfairLock(initialState: (count: 0, first: UInt64(0)))
    private let state = OSAllocatedUnfairLock<Continuation?>(initialState: nil)
    func bind(_ next: Continuation?) {
        if next != nil { callbacks.withLock { $0 = (0, 0) } }
        state.withLock { $0 = next }
    }
    func finish(throwing error: Error) { state.withLock { $0 }?.finish(throwing: error) }
    func yield(_ buffer: CapturedBuffer) -> Continuation.YieldResult {
        callbacks.withLock { if $0.count == 0 { $0.first = LatencyTrace.now() }; $0.count += 1 }
        return state.withLock { $0 }?.yield(buffer) ?? .terminated
    }
}

// All hardware lifecycle operations are serialized away from the main actor.
private actor PreparedAudioEngine {
    private var builds = 0
    private var configured: ConfiguredCallEngine?
    private let relay = CaptureRelay()
    private var observer: NSObjectProtocol?
    private let invalidated = OSAllocatedUnfairLock(initialState: false)

    func snapshot() -> [String: UInt64] {
        let counts = relay.callbacks.withLock { $0 }
        return ["builds": UInt64(builds), "running": configured?.engine.isRunning == true ? 1 : 0,
                "callbacks": UInt64(counts.count), "first_capture_ns": counts.first,
                "input_resources": configured?.engine.inputNode.auAudioUnit.renderResourcesAllocated == true ? 1 : 0,
                "output_resources": configured?.engine.outputNode.auAudioUnit.renderResourcesAllocated == true ? 1 : 0,
                "voice_processing": configured?.engine.inputNode.isVoiceProcessingEnabled == true ? 1 : 0]
    }
    func prepare() throws {
        try Task.checkCancellation()
        if invalidated.withLock({ value in let previous = value; value = false; return previous }),
           let configured {
            // Voice-mode switches also emit configuration notifications. The
            // attached graph only needs rebuilding if its I/O formats changed.
            // Inspect here, never tear down from Core Audio's notification queue.
            if !configured.idleFormatsMatch {
                release()
            } else {
                // The first disabled output unit may initially report 0 Hz.
                // Adopt its first valid format, then detect later route changes.
                let format = configured.engine.outputNode.outputFormat(forBus: 0)
                if format.sampleRate > 0 { self.configured?.idleOutputFormat = format }
            }
        }
        guard configured == nil else { return }
        let start = LatencyTrace.now()
        let prepared = try build()
        // Core Audio calls are synchronous and may return after cancellation.
        // Keep the late graph inactive rather than admitting it as ready.
        try Task.checkCancellation()
        configured = prepared
        builds += 1
        invalidated.withLock { $0 = false }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: configured!.engine, queue: nil) { [invalidated] _ in
            invalidated.withLock { $0 = true }
        }
        AudioTrace.latency.duration("call.engine_prewarm", since: start)
    }
    private func build() throws -> ConfiguredCallEngine {
        #if os(iOS)
        // Select the capture route before querying formats, without activating it.
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP])
        #endif
        let ttsFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                     channels: 1, interleaved: false)!
        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            audioEngine.stop()
            throw CallAudioError.unavailable("No usable microphone is connected.")
        }
        // Use one voice channel on both sides of VoiceProcessingIO. Its
        // nine-channel hardware aggregate also contains reference channels;
        // it is not the client voice stream format.
        guard let voiceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 1, interleaved: false) else {
            throw CallAudioError.unavailable("Cannot configure the voice stream.")
        }
        let node = AVAudioPlayerNode()
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: ttsFormat)
        audioEngine.mainMixerNode.outputVolume = AutomatedAudioOutput.volume
        // VoiceProcessingIO requires matching capture/playback client formats.
        // Keep PocketTTS at 24 kHz on the player's bus; the mixer resamples to
        // the microphone format instead of propagating 24 kHz to VoiceProcessingIO.
        audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: voiceFormat)
        guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
              let monoCaptureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: voiceFormat.sampleRate, channels: 1, interleaved: false) else {
            throw CallAudioError.unavailable("The microphone must supply noninterleaved Float32 audio.")
        }
        let pool = try CaptureBufferPool(format: monoCaptureFormat)
        let captureSink = AVAudioSinkNode { @Sendable [relay] timestamp, frameCount, audioBufferList in
            let arrival = LatencyTrace.now()
            guard let copy = pool.take() else {
                relay.finish(throwing: CallAudioError.capturePoolExhausted)
                return noErr
            }
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            guard frameCount <= copy.frameCapacity, let first = source.first,
                  let from = first.mData, let to = copy.floatChannelData?[0],
                  first.mDataByteSize >= frameCount * 4 else {
                pool.recycle(copy)
                relay.finish(throwing: CallAudioError.captureBufferMismatch)
                return noErr
            }
            copy.frameLength = frameCount
            memcpy(to, from, Int(frameCount) * 4)
            let owned = CapturedBuffer(pcm: copy, arrivalNS: arrival,
                hostTime: timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : nil) { pool.recycle(copy) }
            if case .dropped = relay.yield(owned) {
                relay.finish(throwing: CallAudioError.captureQueueOverflow)
            }
            return noErr
        }
        audioEngine.attach(captureSink)
        audioEngine.connect(input, to: captureSink, format: voiceFormat)
        // Construct connections and buffers without activating VoiceProcessingIO.
        // Merely enabling that unit ducks other apps, even before engine.start().
        // Actual hardware preparation belongs to an admitted capture session.
        AudioTrace.logger.notice("Idle voice graph resources: input=\(input.auAudioUnit.renderResourcesAllocated), output=\(audioEngine.outputNode.auAudioUnit.renderResourcesAllocated)")
        return ConfiguredCallEngine(engine: audioEngine, player: node,
                                    sink: captureSink, echoCancellation: true,
                                    idleInputFormat: input.outputFormat(forBus: 0),
                                    idleOutputFormat: audioEngine.outputNode.outputFormat(forBus: 0))
    }
    func start(_ continuation: CaptureRelay.Continuation) throws -> ConfiguredCallEngine {
        try prepare()
        try Task.checkCancellation()
        let current = configured!
        relay.bind(continuation)
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if current.echoCancellation {
                let processingStart = LatencyTrace.now()
                try current.engine.inputNode.setVoiceProcessingEnabled(true)
                AudioTrace.latency.duration("call.voice_processing_activate", since: processingStart)
                guard current.engine.inputNode.isVoiceProcessingEnabled,
                      current.engine.outputNode.isVoiceProcessingEnabled else {
                    throw CallAudioError.unavailable("Echo cancellation could not be enabled.")
                }
                if AppQualificationEnvironment.root != nil,
                   ProcessInfo.processInfo.environment["BLESSENGER_QUALIFICATION_DISABLE_AGC"] == "1" {
                    current.engine.inputNode.isVoiceProcessingAGCEnabled = false
                }
            }
            try Task.checkCancellation()
            let start = LatencyTrace.now()
            try current.engine.start()
            AudioTrace.latency.duration("call.hardware_start", since: start)
            try Task.checkCancellation()
            let playerStart = LatencyTrace.now()
            current.player.play()
            AudioTrace.latency.duration("call.player_start", since: playerStart)
            return current
        } catch { relay.bind(nil); release(); throw error }
    }
    func stopWhenIdle() {
        relay.bind(nil)
        // Stopping render resources alone does not remove system ducking.
        configured?.engine.stop()
        do {
            try configured?.engine.inputNode.setVoiceProcessingEnabled(false)
            if let current = configured {
                configured?.idleInputFormat = current.engine.inputNode.outputFormat(forBus: 0)
                configured?.idleOutputFormat = current.engine.outputNode.outputFormat(forBus: 0)
            }
        } catch {
            AudioTrace.logger.error("Could not disable idle voice processing: \(error.localizedDescription)")
            release()
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    func release() {
        relay.bind(nil)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        configured?.engine.stop()
        configured = nil
    }
}

private struct PlaybackGraph: @unchecked Sendable {
    let engine: AVAudioEngine
    let player: AVAudioPlayerNode
}

/// An output-only graph keeps playback from requesting microphone access.
/// Scheduling, backpressure, cancellation and TTS remain shared with calls.
private actor PreparedNotePlayback {
    private var graph: PlaybackGraph?
    func start() throws -> PlaybackGraph {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        if graph == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode,
                           format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
            engine.mainMixerNode.outputVolume = AutomatedAudioOutput.volume
            engine.prepare()
            graph = PlaybackGraph(engine: engine, player: player)
        }
        guard let graph else { throw CallAudioError.unavailable("The playback audio graph is missing.") }
        try graph.engine.start()
        graph.player.play()
        return graph
    }
    func pause() { graph?.player.stop(); graph?.engine.pause() }
    func release() { graph?.engine.stop(); graph = nil }
}

/// Stop takes an AVAudioEngine render lock. Keep it off the main actor and
/// serialize it with the next scheduling epoch through CallAudio's reset task.
private actor PlaybackResetter {
    func reset(_ graph: PlaybackGraph) {
        let start = LatencyTrace.now()
        graph.player.stop()
        if graph.engine.isRunning { graph.player.play() }
        graph.player.volume = 1
        AudioTrace.latency.duration("playback.player_stop", since: start)
    }
}

@MainActor
final class CallAudio {
    private let hardware = PreparedAudioEngine()
    private let notePlayback = PreparedNotePlayback()
    private var teardown: Task<Void, Never>?
    private let playbackResetter = PlaybackResetter()
    private var playbackReset: Task<Void, Never>?

    private var remote: RemoteCallTransport?
    var isRemote: Bool { remote != nil }
    // Keep the device clock and AEC running while muted. Silence goes through
    // the ordinary endpoint path, so an open input is completed rather than
    // abandoned and unmuting cannot replay buffered microphone speech.
    var microphoneMuted = false
    func useRemote(_ transport: RemoteCallTransport) throws {
        guard engine == nil, !starting, events == nil, remote == nil else {
            throw CallAudioError.unavailable("Audio is already in use.")
        }
        remote = transport
    }

    func prewarm() async throws { try await hardware.prepare() }
    func hardwareSnapshot() async -> [String: UInt64] { await hardware.snapshot() }
    func settleAudio() async { await teardown?.value }
    func shutdownAudio() async {
        stop()
        await teardown?.value
        await hardware.release()
        await notePlayback.release()
    }

    // A supplied recording exercises the production detector/controller path
    // on the device clock in integration tests; normal calls use microphone PCM.
    var onFirstSpeech: (() -> Void)?
    private(set) var awaitingPickup = false
    func awaitPickup() { awaitingPickup = true }
    private func pickup() {
        guard awaitingPickup else { return }
        if acousticSession != nil {
            AudioTrace.latency.mark("acoustic.pickup", counts: ["microphone_samples": acousticInput.count])
        }
        awaitingPickup = false
        resetUtterance()
        onFirstSpeech?()
    }
    // Opt-in, bounded acoustic evidence. Never record diagnostics in normal use.
    private var acousticInput: [Float] = []
    private var acousticOutput: [Float] = []
    private var acousticSession: UUID?
    private struct AcousticInputTiming: Codable {
        let offset: Int
        let count: Int
        let deviceHostTime: UInt64?
        let arrivalNS: UInt64
        let sourceFrames: UInt32
        let sourceRate: Double
    }
    private struct AcousticOutputTiming: Codable {
        let offset: Int
        let count: Int
        let scheduledNS: UInt64
        let bufferFrames: Int
        let response: UUID
        let segment: UUID?
        var completedNS: UInt64?
    }
    private var acousticInputTiming: [AcousticInputTiming] = []
    private var acousticOutputTiming: [AcousticOutputTiming] = []
    private var captureOverride: [Float]?
    private var replayOffset = 0
    private var captureSpeechEnds: [Int]
    private var signalOnsetScheduled = false

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var sink: AVAudioSinkNode?
    private var captureTask: Task<Void, Never>?
    private var captureContinuation: AsyncThrowingStream<CapturedBuffer, Error>.Continuation?
    private var events: AsyncThrowingStream<CallAudioEvent, Error>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    private var starting = false
    private var captureID = UUID()
    private var playbackID = UUID()
    private var playbackLedger: PlaybackLedger?
    // Update on the completion callback itself, not a later MainActor task.
    private var confirmedPlayback = OSAllocatedUnfairLock(initialState: Int64(0))
    private var playbackProgress: (@Sendable (Int64) -> Void)?
    private(set) var interruptedPlayback: PlaybackLedger.Receipt?
    private var vad: StreamingVAD?
    // Both threshold crossings are measured at inference completion.
    private static let acousticTailSamples = 1_600
    // Calibration can require real captured tail before freezing model input.
    // Zero preserves immediate speculation at the loose-threshold crossing.
    private static let candidateTailSamples = 16 * max(0, min(100,
        Int(ProcessInfo.processInfo.environment["CALL_GEMMA_AUDIO_TAIL_MS"] ?? "100") ?? 100))
    private static let confirmationSamples = max(candidateTailSamples,
        256 * max(1, min(12, Int(ProcessInfo.processInfo.environment["CALL_GEMMA_CONFIRMATION_FRAMES"] ?? "1") ?? 1)))
    private static let endpointThreshold = Float(ProcessInfo.processInfo.environment["CALL_GEMMA_ENDPOINT_THRESHOLD"] ?? "0.3") ?? 0.3
    private static let speculationThreshold = Float(ProcessInfo.processInfo.environment["CALL_GEMMA_SPECULATION_THRESHOLD"] ?? "0.5") ?? 0.5
    static var qualificationEndpointSettings: [String: Double] {
        ["onset": 0.65, "speculation": Double(speculationThreshold), "strict": Double(endpointThreshold),
         "tailMS": Double(candidateTailSamples) / 16, "confirmationMS": Double(confirmationSamples) / 16]
    }
    private var vadState = SpeechEndpoint(silenceSamples: CallAudio.confirmationSamples,
        speechThreshold: 0.65, silenceThreshold: CallAudio.endpointThreshold,
        speculationThreshold: CallAudio.speculationThreshold, candidateTailSamples: CallAudio.candidateTailSamples)
    private var vadEpoch = UUID()
    private var utterance = UtteranceBuffer()
    private var candidateID: UUID?
    private var inputID: UUID?
    private var inputSamplesSent = 0
    private var pendingInput: [Float] = []
    private var queuedBuffers = 0
    private var previousDrainNS: UInt64?
    private var playbackTurn: UUID?
    private var capturedSamples = 0
    private var speechStarts = 0
    private var completedUtterances = 0
    private var peakLevel: Float = 0
    private var peakProbability: Float = 0
    private var nextReport = 16_000
    private var playbackWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var drainWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var echoTailUntil = Date.distantPast
    private(set) var echoCancellationEnabled = false
    private let ttsFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                         channels: 1, interleaved: false)!

    init(captureOverride: [Float]? = nil, captureSpeechEnds: [Int] = []) {
        self.captureSpeechEnds = captureSpeechEnds
        self.captureOverride = captureOverride
        AudioModelPins.configure()
    }

    func prepare() async throws {
        if vad == nil {
            // Earshot uses a small CPU state, independently of PocketTTS and the LM.
            vad = try StreamingVAD()
        }
    }

    func qualificationInject(_ samples: [Float], referenceEnd: Int? = nil) throws {
        guard AppQualificationEnvironment.usesSyntheticInput, engine != nil,
              replayOffset >= (captureOverride?.count ?? 0), samples.count <= 480_000,
              samples.allSatisfy(\.isFinite) else { throw CallAudioError.captureOverrun }
        if let referenceEnd, !(0..<samples.count).contains(referenceEnd) { throw CallAudioError.invalidVoice }
        captureSpeechEnds = referenceEnd.map { [$0] } ?? []
        captureOverride = samples
        replayOffset = 0
        AudioTrace.latency.mark("fixture.injected")
    }

    func start(recording: VoiceNoteRecording? = nil) async throws -> AsyncThrowingStream<CallAudioEvent, Error> {
        guard engine == nil, !starting else { throw CallAudioError.unavailable("The audio engine is already running.") }
        let setupStart = LatencyTrace.now()
        defer { AudioTrace.latency.duration("call.microphone_setup", since: setupStart) }
        let id = UUID()
        captureID = id
        starting = true
        defer { if captureID == id { starting = false } }
        if let remote {
            guard recording == nil else { throw CallAudioError.invalidVoice }
            try await prepare()
            resetUtterance()
            capturedSamples = 0; speechStarts = 0; completedUtterances = 0
            peakLevel = 0; peakProbability = 0; nextReport = 16_000
            // getUserMedia requests echo cancellation at the phone capture device.
            echoCancellationEnabled = remote.echoCancellation
            let output = AsyncThrowingStream<CallAudioEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
            events = output.continuation
            remote.input = { [weak self] samples in
                try await self?.consume(samples, id: id, endNS: LatencyTrace.now())
            }
            remote.failure = { [weak self] error in self?.events?.finish(throwing: error) }
            remote.start()
            output.continuation.onTermination = { [weak self] _ in
                Task { @MainActor in if self?.captureID == id { self?.stop() } }
            }
            return output.stream
        }
        let permissionStart = LatencyTrace.now()
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CallAudioError.microphoneDenied }
        AudioTrace.latency.duration("call.microphone_permission", since: permissionStart)
        guard captureID == id else { throw CancellationError() }
        if recording == nil { try await prepare() }
        try Task.checkCancellation()
        guard captureID == id else { throw CancellationError() }
        resetUtterance()
        if AppQualificationEnvironment.root != nil && !AppQualificationEnvironment.usesSyntheticInput {
            acousticSession = UUID()
            acousticInputTiming = []; acousticOutputTiming = []
            acousticInput = []; acousticInput.reserveCapacity(16_000 * 60)
            acousticOutput = []; acousticOutput.reserveCapacity(24_000 * 60)
        }
        // CLI-injected audio belongs to one capture session. Rewinding an old
        // injection here replays a prior user's utterance on the next call.
        // Static constructor fixtures retain their explicit replay semantics.
        if AppQualificationEnvironment.usesSyntheticInput { captureOverride = [] }
        replayOffset = 0
        capturedSamples = 0; speechStarts = 0; completedUtterances = 0
        peakLevel = 0; peakProbability = 0; nextReport = 16_000
        let output = AsyncThrowingStream<CallAudioEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        events = output.continuation
        let capture = AsyncThrowingStream<CapturedBuffer, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        captureContinuation = capture.continuation
        await teardown?.value
        guard captureID == id, !Task.isCancelled else { throw CancellationError() }
        let configured = try await hardware.start(capture.continuation)
        guard captureID == id, !Task.isCancelled else {
            await hardware.stopWhenIdle()
            throw CancellationError()
        }
        let audioEngine = configured.engine
        engine = audioEngine
        player = configured.player
        sink = configured.sink
        echoCancellationEnabled = configured.echoCancellation
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.captureID == id else { return }
                self.events?.finish(throwing: CallAudioError.unavailable("The audio device changed. Please restart the call."))
                self.stop()
            }
        }
        let resampler = CaptureResampler()
        captureTask = Task { [weak self] in
            do {
                for try await buffer in capture.stream {
                    try Task.checkCancellation()
                    // Separate main-actor stream admission from the resampler
                    // actor hop; capture.queue alone includes both waits.
                    AudioTrace.latency.duration("capture.dequeue_wait", since: buffer.arrivalNS)
                    let resampleStart = LatencyTrace.now()
                    var samples = try await resampler.process(buffer)
                    AudioTrace.latency.duration("capture.resampler_roundtrip", since: resampleStart)
                    let postprocessStart = LatencyTrace.now()
                    if let self, let fixture = self.captureOverride, recording != nil || !self.awaitingPickup {
                        let count = samples.count
                        samples = Array(repeating: 0, count: count)
                        let available = max(0, min(count, fixture.count - self.replayOffset))
                        if available > 0 {
                            samples.replaceSubrange(0..<available, with: fixture[self.replayOffset..<(self.replayOffset + available)])
                        }
                        self.replayOffset += count
                    }
                    if let self, self.acousticSession != nil, self.acousticInput.count < 16_000 * 60 {
                        let count = min(samples.count, 16_000 * 60 - self.acousticInput.count)
                        self.acousticInputTiming.append(AcousticInputTiming(
                            offset: self.acousticInput.count, count: count,
                            deviceHostTime: buffer.hostTime, arrivalNS: buffer.arrivalNS,
                            sourceFrames: buffer.pcm.frameLength, sourceRate: buffer.pcm.format.sampleRate))
                        self.acousticInput.append(contentsOf: samples.prefix(count))
                    }
                    if let recording {
                        try await recording.append(samples)
                        continue
                    }
                    // Anchor the resampled stream to the device clock, not actor delivery.
                    let begin = buffer.hostTime.map { AVAudioTime.seconds(forHostTime: $0) }
                        ?? (Double(buffer.arrivalNS) / 1e9 - Double(buffer.pcm.frameLength) / buffer.pcm.format.sampleRate)
                    let endNS = UInt64(max(0, (begin + Double(buffer.pcm.frameLength) / buffer.pcm.format.sampleRate) * 1e9))
                    if let self, !self.awaitingPickup, !self.captureSpeechEnds.isEmpty {
                        let offset = self.replayOffset - samples.count
                        for endpoint in self.captureSpeechEnds where endpoint >= offset && endpoint < self.replayOffset {
                            let time = UInt64(max(0, (begin + Double(endpoint - offset) / 16_000) * 1e9))
                            AudioTrace.latency.mark("fixture.speech_signal_end", at: time)
                        }
                    }
                    AudioTrace.latency.duration("capture.postprocess", since: postprocessStart)
                    try await self?.consume(samples, id: id, endNS: endNS)
                }
            } catch {
                guard let self, self.captureID == id, !Task.isCancelled else { return }
                self.events?.finish(throwing: error)
                self.stop()
            }
        }
        output.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                if self?.captureID == id { self?.stop() }
            }
        }
        if !echoCancellationEnabled {
            notice("Echo cancellation is unavailable; listening pauses during playback.")
        }
        return output.stream
    }

    func finishRecordingCapture() async {
        captureContinuation?.finish()
        await captureTask?.value
        stop()
        await settleAudio()
    }

    func startNotePlayback() async throws {
        guard engine == nil, !starting else { throw CallAudioError.unavailable("Audio is already running.") }
        starting = true
        let id = UUID()
        captureID = id
        defer { if captureID == id { starting = false } }
        await teardown?.value
        try Task.checkCancellation()
        let graph = try await notePlayback.start()
        guard captureID == id, !Task.isCancelled else { await notePlayback.pause(); throw CancellationError() }
        engine = graph.engine
        player = graph.player
    }

    func stop() {
        microphoneMuted = false
        if let session = acousticSession, let root = AppQualificationEnvironment.root {
            acousticSession = nil
            let input = acousticInput, output = acousticOutput
            let inputTiming = acousticInputTiming, outputTiming = acousticOutputTiming
            acousticInputTiming = []; acousticOutputTiming = []
            acousticInput = []; acousticOutput = []
            Task.detached(priority: .utility) {
                do {
                    let folder = root.appending(path: "Acoustics/" + session.uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    try input.withUnsafeBytes { try Data($0).write(to: folder.appending(path: "processed-microphone-16000.f32")) }
                    try output.withUnsafeBytes { try Data($0).write(to: folder.appending(path: "scheduled-output-24000.f32")) }
                    try JSONEncoder().encode(inputTiming).write(to: folder.appending(path: "input-timing.json"))
                    // Completion times are device-delivery estimates. Missing completion
                    // means cancelled/unconfirmed, never proof that PCM was audible.
                    try JSONEncoder().encode(outputTiming).write(to: folder.appending(path: "output-timing.json"))
                } catch { AudioTrace.logger.error("Acoustic evidence export failed: \(error.localizedDescription)") }
            }
        }
        AudioTrace.latency.mark("capture.stop")
        AudioTrace.latency.flush("call_stop")
        captureID = UUID()
        starting = false
        captureContinuation?.finish()
        captureContinuation = nil
        captureTask?.cancel()
        captureTask = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        clearPlayback()
        let previous = teardown
        let reset = playbackReset
        teardown = Task { [hardware, notePlayback] in
            await previous?.value
            await reset?.value
            await hardware.stopWhenIdle()
            await notePlayback.pause()
        }
        remote?.close(); remote = nil
        engine = nil
        player = nil
        sink = nil
        events?.finish()
        events = nil
        resetUtterance()
    }

    /// Backpressure limits scheduled audio to eight PocketTTS frames (640 ms).
    func beginPlaybackResponse(_ response: UUID, progress: (@Sendable (Int64) -> Void)? = nil) {
        AudioTrace.latency.mark("playback.response_begin", turn: response)
        signalOnsetScheduled = false
        playbackLedger = PlaybackLedger(response: response)
        interruptedPlayback = nil
        confirmedPlayback = OSAllocatedUnfairLock(initialState: Int64(0))
        playbackProgress = progress
    }

    func beginPlaybackSegment(_ segment: UUID, text: String) throws {
        guard playbackLedger != nil else { throw CallAudioError.unavailable("The playback response ledger is missing.") }
        try playbackLedger?.beginSegment(segment, text: text)
    }

    func finishPlaybackSegment(_ segment: UUID) throws {
        synchronizePlaybackLedger()
        try playbackLedger?.seal(segment)
    }

    private func synchronizePlaybackLedger() {
        guard let response = playbackLedger?.response else { return }
        playbackLedger?.delivered(through: confirmedPlayback.withLock { $0 }, response: response)
        if let playbackLedger { playbackProgress?(playbackLedger.deliveredFrames) }
    }

    func playbackPosition() -> Int64 {
        synchronizePlaybackLedger()
        return playbackLedger?.deliveredFrames ?? interruptedPlayback?.deliveredFrames ?? 0
    }

    func play(_ samples: [Float], firstFrameOfSentence: Bool = false, turn: UUID? = nil,
              segment: UUID? = nil) async throws {
        guard !samples.isEmpty, samples.count <= 1_920, samples.allSatisfy(\.isFinite) else {
            throw CallAudioError.unavailable("PocketTTS returned an invalid audio frame.")
        }
        let id = playbackID
        // No buffer from a new response may race the previous player's stop.
        // The await yields the UI thread while AVAudioEngine takes its locks.
        await playbackReset?.value
        try Task.checkCancellation()
        guard id == playbackID else { throw CancellationError() }
        while queuedBuffers >= 8 {
            try await waitForPlaybackChange(draining: false)
        }
        try Task.checkCancellation()
        guard id == playbackID else { throw CancellationError() }
        if let remote {
            let scheduledThrough = try segment.flatMap { try playbackLedger?.schedule(samples, segment: $0) }
            if segment != nil, scheduledThrough == nil { throw CallAudioError.unavailable("Playback ledger missing.") }
            let confirmation = confirmedPlayback
            try remote.enqueue(samples) { [weak self] in
                guard let self, self.playbackID == id else { return }
                if let scheduledThrough { confirmation.withLock { $0 = max($0, scheduledThrough) } }
                self.synchronizePlaybackLedger()
                self.queuedBuffers -= 1
                let waiters = Array(self.playbackWaiters.values)
                self.playbackWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                if self.queuedBuffers == 0 {
                    let drains = Array(self.drainWaiters.values)
                    self.drainWaiters.removeAll()
                    for waiter in drains { waiter.resume() }
                }
            }
            queuedBuffers += 1
            playbackTurn = turn
            if segment != nil { pickup() }
            return
        }
        guard let player, engine?.isRunning == true else {
            throw CallAudioError.unavailable("The audio engine is not running.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: ttsFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw CallAudioError.unavailable("Cannot allocate speech playback audio.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let scheduledThrough: Int64?
        if let segment {
            guard playbackLedger != nil else { throw CallAudioError.unavailable("The playback response ledger is missing.") }
            scheduledThrough = try playbackLedger?.schedule(samples, segment: segment)
            if firstFrameOfSentence {
                AudioTrace.latency.mark("playback.segment_begin", turn: segment,
                    counts: ["queued_buffers": queuedBuffers])
            }
        } else {
            scheduledThrough = nil // Ringing has no assistant transcript.
        }
        // Report the first non-silent PCM sample as well as buffer onset. This
        // remains a device-clock estimate, not an acoustic microphone measurement.
        let signalOffset = signalOnsetScheduled ? nil : samples.firstIndex { abs($0) >= 0.01 }
        if signalOffset != nil { signalOnsetScheduled = true }
        let confirmation = confirmedPlayback
        let scheduledAt = LatencyTrace.now()
        if queuedBuffers == 0, playbackTurn == turn, let drained = previousDrainNS, scheduledAt >= drained {
            AudioTrace.latency.observe("playback.queue_gap", milliseconds: Double(scheduledAt - drained) / 1e6)
            AudioTrace.latency.mark("playback.queue_gap", turn: turn)
        }
        playbackTurn = turn
        queuedBuffers += 1
        if firstFrameOfSentence { AudioTrace.latency.mark("playback.first_buffer_scheduled", turn: turn) }
        if segment != nil { pickup() }
        let evidenceSession = acousticSession
        let evidenceIndex: Int?
        if evidenceSession != nil, acousticOutput.count < 24_000 * 60 {
            let count = min(samples.count, 24_000 * 60 - acousticOutput.count)
            evidenceIndex = acousticOutputTiming.count
            acousticOutputTiming.append(AcousticOutputTiming(offset: acousticOutput.count,
                count: count, scheduledNS: scheduledAt, bufferFrames: samples.count, response: id, segment: segment))
            acousticOutput.append(contentsOf: samples.prefix(count))
        } else { evidenceIndex = nil }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            let completedAt = LatencyTrace.now()
            // Each response installs its own confirmation object below; stale
            // callbacks cannot advance a subsequent response's cursor.
            if let scheduledThrough { confirmation.withLock { $0 = max($0, scheduledThrough) } }
            Task { @MainActor in
                guard let self, self.playbackID == id else { return }
                if let evidenceIndex, self.acousticSession == evidenceSession,
                   self.acousticOutputTiming.indices.contains(evidenceIndex) {
                    self.acousticOutputTiming[evidenceIndex].completedNS = completedAt
                }
                self.synchronizePlaybackLedger()
                if let signalOffset {
                    let remainingNS = UInt64(samples.count - signalOffset) * 1_000_000_000 / 24_000
                    AudioTrace.latency.mark("playback.signal_onset_estimate", turn: turn,
                        at: completedAt > remainingNS ? completedAt - remainingNS : 0)
                }
                if firstFrameOfSentence {
                    AudioTrace.latency.observe("playback.first_buffer_to_played_back", milliseconds: Double(completedAt - scheduledAt) / 1e6)
                    AudioTrace.latency.mark("playback.first_buffer_played_back", turn: turn, at: completedAt)
                    let spanNS = UInt64(samples.count) * 1_000_000_000 / 24_000
                    AudioTrace.latency.mark("playback.onset_estimate", turn: turn, at: completedAt > spanNS ? completedAt - spanNS : 0)
                }
                self.queuedBuffers -= 1
                let waiters = Array(self.playbackWaiters.values)
                self.playbackWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                if self.queuedBuffers == 0 {
                    self.previousDrainNS = completedAt
                    self.echoTailUntil = Date().addingTimeInterval(0.3)
                    let drains = Array(self.drainWaiters.values)
                    self.drainWaiters.removeAll()
                    for waiter in drains { waiter.resume() }
                }
            }
        }
        if firstFrameOfSentence { AudioTrace.signposter.emitEvent("First playback buffer scheduled") }
    }

    func drainPlayback() async throws {
        while queuedBuffers > 0 { try await waitForPlaybackChange(draining: true) }
        try Task.checkCancellation()
    }

    func interruptPlayback() {
        guard playbackLedger != nil || queuedBuffers > 0 else { return }
        clearPlayback()
    }

    func notice(_ message: String) { emit(.notice(message)) }

    private func clearPlayback() {
        synchronizePlaybackLedger()
        if let ledger = playbackLedger {
            AudioTrace.latency.mark("playback.response_cancel", turn: ledger.response,
                counts: ["queued_buffers": queuedBuffers,
                         "scheduled_frames": Int(ledger.scheduledFrames),
                         "delivered_frames": Int(ledger.deliveredFrames)])
            interruptedPlayback = ledger.receipt()
            AudioTrace.latency.observe("playback.confirmed_ms_at_stop",
                milliseconds: Double(ledger.deliveredFrames) / 24)
            playbackLedger = nil
        }
        playbackID = UUID()
        remote?.cancelPlayback()
        playbackProgress = nil
        // With no scheduled buffers there is nothing to cancel. Avoid taking
        // the audio unit's synchronous stop lock on an already drained player.
        if queuedBuffers > 0, let engine, let player {
            // Silence immediately; the slower stop only discards queued PCM.
            // A new response waits for this reset before scheduling any audio.
            let muteStart = LatencyTrace.now()
            player.volume = 0
            AudioTrace.latency.duration("playback.mute", since: muteStart)
            let previous = playbackReset
            let graph = PlaybackGraph(engine: engine, player: player)
            playbackReset = Task { [playbackResetter] in
                await previous?.value
                await playbackResetter.reset(graph)
            }
        }
        // Clearing a completed response is bookkeeping, not acoustic output.
        // Inventing an echo tail here resets a pending speculative utterance on
        // non-AEC inputs, losing its confirmation and stranding reply playback.
        if queuedBuffers > 0 { echoTailUntil = Date().addingTimeInterval(0.3) }
        queuedBuffers = 0
        previousDrainNS = nil
        playbackTurn = nil
        let waiters = Array(playbackWaiters.values) + Array(drainWaiters.values)
        playbackWaiters.removeAll()
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    private func waitForPlaybackChange(draining: Bool) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if draining { drainWaiters[id] = continuation }
                else { playbackWaiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                let waiter = self?.playbackWaiters.removeValue(forKey: id) ?? self?.drainWaiters.removeValue(forKey: id)
                waiter?.resume(throwing: CancellationError())
            }
        }
    }

    private var suppressCapture: Bool {
        !echoCancellationEnabled && (queuedBuffers > 0 || Date() < echoTailUntil)
    }

    private func consume(_ samples: [Float], id: UUID, endNS: UInt64) async throws {
        guard captureID == id else { return }
        if suppressCapture || awaitingPickup { resetUtterance(); return }
        let consumeStart = LatencyTrace.now()
        defer { AudioTrace.latency.duration("capture.consume", since: consumeStart) }
        pendingInput.append(contentsOf: microphoneMuted ? [Float](repeating: 0, count: samples.count) : samples)
        while pendingInput.count >= StreamingVAD.chunkSize {
            let chunk = Array(pendingInput.prefix(StreamingVAD.chunkSize))
            pendingInput.removeFirst(StreamingVAD.chunkSize)
            guard let vad else { return }
            let vadStart = LatencyTrace.now()
            let probability = try await vad.process(chunk, epoch: vadEpoch)
            let inferenceEnd = LatencyTrace.now()
            AudioTrace.latency.duration("vad.inference", since: vadStart)
            guard captureID == id else { return }
            if suppressCapture { resetUtterance(); return }
            let result = vadState.process(probability: probability, frames: chunk.count)
            if result.speculationBegan {
                AudioTrace.latency.mark("vad.speculation_threshold_crossed", turn: candidateID ?? inputID, at: inferenceEnd)
            }
            if result.silenceBegan {
                AudioTrace.latency.mark("vad.playback_threshold_crossed", turn: candidateID ?? inputID, at: inferenceEnd)
            }
            let level = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            let start = result.start
            let end = result.end
            capturedSamples += chunk.count
            peakLevel = max(peakLevel, level)
            peakProbability = max(peakProbability, probability)
            if start != nil {
                AudioTrace.latency.mark("vad.speech_start")
                if queuedBuffers > 0 || Date() < echoTailUntil {
                    AudioTrace.latency.mark("vad.speech_start_during_output", turn: playbackTurn)
                    AudioTrace.latency.observe("vad.output_overlap_probability", milliseconds: Double(probability) * 1000)
                    AudioTrace.latency.observe("vad.output_overlap_rms", milliseconds: Double(level) * 1000)
                }
                speechStarts += 1
                emit(.speechStarted)
            }
            if result.resumed, let candidateID {
                emit(.resumed(candidateID))
                self.candidateID = nil
                inputID = nil; inputSamplesSent = 0
                AudioTrace.latency.mark("vad.speculation_revoked")
            }
            // Retain available captured tail, up to 100 ms past the strict
            // boundary. UtteranceBuffer never invents uncaptured samples.
            let completed = utterance.append(chunk, start: start, end: end.map { $0 + Self.acousticTailSamples })
            if candidateID == nil {
                if let inputID {
                    // The retained tail may end inside this VAD frame. Send
                    // exactly the PCM that the durable utterance will contain.
                    let count = completed.map { $0.samples.count - inputSamplesSent } ?? chunk.count
                    guard count >= 0, count <= chunk.count else { throw CallAudioError.invalidVoice }
                    if count > 0 {
                        emit(.input(inputID, count == chunk.count ? chunk : Array(chunk.prefix(count)), begin: false))
                        inputSamplesSent += count
                    }
                }
                else if let snapshot = utterance.snapshot() {
                    let input = UUID()
                    inputID = input
                    inputSamplesSent = snapshot.count
                    emit(.input(input, snapshot, begin: true))
                }
            }
            if let completed {
                completedUtterances += 1
                if let end {
                    AudioTrace.latency.observe("vad.endpoint_lookback", milliseconds: Double(result.processedSamples - end) / 16)
                }
                AudioTrace.latency.mark("vad.utterance_ready")
                AudioTrace.logger.notice("Utterance delivered: \(completed.samples.count) samples")
                // First low-probability frame, without speech padding. This still
                // has VAD error and 16 ms granularity; it is not acoustic ground truth.
                let lookback = pendingInput.count + max(0, result.processedSamples - (end ?? result.processedSamples))
                let lookbackNS = UInt64(lookback) * 1_000_000_000 / 16_000
                if let candidateID {
                    emit(.confirmed(candidateID))
                    self.candidateID = nil
                } else {
                    emit(.utterance(completed.samples, endpointNS: endNS > lookbackNS ? endNS - lookbackNS : 0))
                }
                inputID = nil; inputSamplesSent = 0
                if completed.reachedLimit {
                    notice("The microphone reached the 30-second limit for one utterance.")
                    resetUtterance()
                }
            }
            if let candidateEnd = result.candidate, candidateID == nil, let snapshot = utterance.snapshot() {
                let candidate = inputID ?? UUID()
                candidateID = candidate
                let lookback = pendingInput.count + result.processedSamples - candidateEnd
                let ns = UInt64(lookback) * 1_000_000_000 / 16_000
                AudioTrace.latency.mark("vad.speculative_trigger", turn: candidate)
                emit(.candidate(candidate, snapshot, endpointNS: endNS > ns ? endNS - ns : 0))
            }
            if capturedSamples >= nextReport {
                let report = String(format: "Microphone: %.1f s · peak RMS %.4f · speech probability %.3f\nSpeech starts: %d · utterances: %d", Double(capturedSamples) / 16_000, peakLevel, peakProbability, speechStarts, completedUtterances)
                emit(.diagnostics(report))
                AudioTrace.logger.notice("\(report, privacy: .public)")
                nextReport = capturedSamples + 5 * 16_000
                peakLevel = 0; peakProbability = 0
            }
        }
    }

    private func resetUtterance() {
        vadState = SpeechEndpoint(silenceSamples: CallAudio.confirmationSamples, speechThreshold: 0.65, silenceThreshold: CallAudio.endpointThreshold,
        speculationThreshold: CallAudio.speculationThreshold, candidateTailSamples: CallAudio.candidateTailSamples)
        vadEpoch = UUID()
        utterance = UtteranceBuffer()
        candidateID = nil
        inputID = nil; inputSamplesSent = 0
        pendingInput.removeAll(keepingCapacity: true)
    }

    private func emit(_ event: CallAudioEvent) {
        if let result = events?.yield(event), case .dropped = result {
            events?.finish(throwing: CallAudioError.eventOverrun)
            stop()
        }
    }
}
