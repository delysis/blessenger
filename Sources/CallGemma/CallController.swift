import Combine
@preconcurrency import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#endif

enum PromptChoice: String, CaseIterable, Identifiable {
    case everyday = "Everyday", concise = "Concise", brainstorm = "Brainstorm", custom = "Custom"
    var id: String { rawValue }
    var text: String {
        let speech = "You are Gemma, speaking with the user in a voice call. Reply in natural spoken English sentences. Avoid markdown, lists, and stage directions."
        switch self {
        case .custom: return speech
        case .everyday: return speech + " Be helpful and conversational. Usually answer in two or three sentences."
        case .concise: return speech + " Give a direct answer in one or two short sentences unless asked for more detail."
        case .brainstorm: return speech + " Help the user develop ideas. Offer one useful idea at a time, explain it briefly, and ask a focused question when needed."
        }
    }
}

@MainActor
final class CallAudioDiagnostics: ObservableObject {
    @Published var text = "Microphone has not started."
}

@MainActor
final class CallController: ObservableObject, MessageInference {
    @Published private(set) var ready = false
    @Published private(set) var inCall = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Ready"
    @Published private(set) var callConnectedAt: Date?
    @Published private(set) var microphoneMuted = false
    func toggleMicrophoneMute() {
        guard inCall else { return }
        microphoneMuted.toggle()
        audio.microphoneMuted = microphoneMuted
    }
    @Published private(set) var dialing = false
    private let ringback = CallRingback()
    private var pendingGreeting = false
    @Published private(set) var notice: String?
    let callDiagnostics = CallAudioDiagnostics()
    private(set) var audioDiagnostics: String {
        get { callDiagnostics.text }
        set { callDiagnostics.text = newValue }
    }
    @Published private(set) var voiceName = "Default"
    @Published private(set) var voiceImporting = false
    @Published private(set) var voiceError: String?
    @Published var prompt = PromptChoice(rawValue: UserDefaults.standard.string(forKey: "prompt") ?? "") ?? .everyday
    @Published private(set) var customPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
    var systemPrompt: String { profilePrompt ?? (prompt == .custom ? customPrompt : prompt.text) }
    let models = ModelStore()
    private let audio: CallAudio
    private let runtime = GemmaRuntime()
    private var journal: HeardTurnJournal?
    private let spokenRecovery = SpokenTextRecovery()
    private let directory: URL
    private var profileDirectory: URL?
    private var profilePrompt: String?
    private var textSession: String?
    @Published private var textBusy = false
    @Published private var noteRecording: VoiceNoteRecording?
    private var noteCaptureTask: Task<Void, Error>?
    @Published private(set) var playingVoiceNote: UUID?
    private var notePlaybackTask: Task<Void, Never>?
    @Published private(set) var voiceNotePosition = 0.0
    @Published private(set) var voiceNoteDuration = 0.0
    @Published private(set) var voiceNotePaused = false
    private var recordedNotePlayer: AVAudioPlayer?
    private var notePCM: [Float] = []
    private var noteCursor = 0
    private var noteSeek: Int?
    private var noteProduced = false
    private var textTranscript: TranscriptFiles?
    private var textHistory: ConversationHistory?
    private var conversationDirectory: URL { profileDirectory ?? directory }
    private lazy var speech = SpeechOutput(audio: audio, cacheDirectory: directory.appending(path: "Speech"))
    private var preparedModel: PreparedModel?
    private var runtimeSHA = ""
    private var setupTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var configurationID = UUID()
    private var callTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var savingResponse = false
    private var needsRecovery = false
    private var interruptionTask: Task<Void, Never>?
    private struct PendingCallUtterance {
        let samples: [Float]
        let endpointNS: UInt64
        let gate: SpeculativeEndpoint?
        let prefill: StreamingAudioInput?
        let handoff: Task<Void, Error>?
        var participant: UUID? = nil
        var manualSelection = false
    }
    private var pendingUtterances: [PendingCallUtterance] = []
    private var speculativeEndpoint: SpeculativeEndpoint?
    private var responseEndpoint: SpeculativeEndpoint?
    private var activeInput: (id: UUID, stream: StreamingAudioInput?, handoff: Task<Void, Error>?, participant: UUID?, manualSelection: Bool)?
    private var responseInput: StreamingAudioInput?
    private var callRoster: CallRoster?
    private var sharedCallHistory: SharedCallHistory?
    private var requestedCallParticipant: UUID?
    private let wakePhonetics = WakePhonetics()
    private var callWakeModel: WakeNameModel?
    private var wakeTasks: [UUID: Task<UUID?, Error>] = [:]
    private var participantTasks: [UUID: Task<Void, Error>] = [:]
    @Published private(set) var activeCallParticipant: UUID?
    var callParticipants: [Persona] { callRoster?.participants ?? [] }

    /// Select by stable roster identity; admission occurs at the next input boundary.
    @discardableResult
    func requestCallParticipant(_ id: UUID) -> Bool {
        guard inCall, callRoster?.participants.contains(where: { $0.id == id }) == true else { return false }
        requestedCallParticipant = id
        return true
    }

    private func activateCallParticipant(_ id: UUID, call: UUID) async throws {
        try Task.checkCancellation()
        guard inCall, callID == call, let model = preparedModel,
              let contact = callRoster?.participants.first(where: { $0.id == id }) else {
            throw CancellationError()
        }
        // The input barrier has drained the outgoing response/recovery first.
        try await recoverHeardTurn()
        try Task.checkCancellation()
        guard inCall, callID == call else { throw CancellationError() }
        profileDirectory = directory.appending(path: "Contacts/" + contact.id.uuidString + "/Calls")
        profilePrompt = contact.prompt
        textSession = nil
        try await openJournal(model: model)
        if let shared = sharedCallHistory, let outgoing = activeCallParticipant {
            let result = try await Task.detached(priority: .userInitiated) {
                var updated = shared
                try updated.handoff(from: outgoing, to: id)
                return updated
            }.value
            guard inCall, callID == call else { throw CancellationError() }
            sharedCallHistory = result
        }
        notice = try await runtime.prepare(model: model, systemPrompt: systemPrompt,
            directory: conversationDirectory, runtimeSHA256: runtimeSHA, compiledCacheRoot: directory.appending(path: "Compiled"))
        try Task.checkCancellation()
        guard inCall, callID == call else { throw CancellationError() }
        let voice = contact.voice.flatMap { name in
            name.hasPrefix("/") ? URL(fileURLWithPath: name) : BlessengerResources.voiceURL(name)
        }
        try await speech.setVoice(referenceAudio: voice)
        try Task.checkCancellation()
        guard inCall, callID == call else { throw CancellationError() }
        callMemoryContact = id
        activeCallParticipant = id
    }
    private var callMemoryStore: MessageStore?
    private var callMemoryContact: UUID?
    private var registeredMemoryCall: UUID?
    private var callChatContext = "[]"
    private var callID = UUID()
    private var responseID = UUID()
    private var isShuttingDown = false
    init(audio: CallAudio = CallAudio(), directory: URL = URL.applicationSupportDirectory.appending(path: "CallGemma", directoryHint: .isDirectory)) {
        self.audio = audio
        self.directory = directory
    }

    #if os(iOS)
    private var suspended = false
    private var lifecycleID = UUID()
    private var suspensionTask: Task<Void, Never>?
    private var backgroundLease: UIBackgroundTaskIdentifier = .invalid

    func suspendForBackground() {
        guard !suspended else { return }
        suspended = true
        lifecycleID = UUID()
        audio.stop()
        guard suspensionTask == nil else { return }
        backgroundLease = UIApplication.shared.beginBackgroundTask(withName: "Close call") { [weak self] in
            Task { @MainActor in self?.finishBackgroundLease() }
        }
        suspensionTask = Task {
            _ = await shutdown()
            ready = false
            finishBackgroundLease()
        }
    }

    func resumeFromBackground() {
        guard suspended else { return }
        suspended = false
        let id = UUID()
        lifecycleID = id
        let pending = suspensionTask
        Task {
            await pending?.value
            guard !suspended, lifecycleID == id else { return }
            suspensionTask = nil
            isShuttingDown = false
            prepare(allowAvailableModel: true)
        }
    }

    private func finishBackgroundLease() {
        guard backgroundLease != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundLease)
        backgroundLease = .invalid
    }
    #endif

    var statusLabel: String {
        if dialing { return "Calling" }
        switch status {
        case "Listening", "Generating", "Speaking", "Ready", "Importing": return status
        case "Opening microphone…": return "Ringing"
        case "Saving conversation…": return "Saving"
        case "Interrupting…": return "Resuming"
        case "Preparing PocketTTS…": return ""
        case "Loading Gemma…", "Opening conversation…": return ""
        case "Call ended": return "Ended"
        case "Setup cancelled": return "Cancelled"
        case "Setup failed", "Save failed", "Could not open the conversation": return "Failed"
        default: return busy || status.hasPrefix("Preparing") ? "" : "Ended"
        }
    }

    func applySystemPrompt(_ text: String) async {
        guard !isShuttingDown, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text != systemPrompt else { return }
        if inCall { toggleCall() }
        customPrompt = text
        UserDefaults.standard.set(text, forKey: "customSystemPrompt")
        prompt = PromptChoice.allCases.first { $0 != .custom && $0.text == text } ?? .custom
        changePrompt()
    }

    private func enqueueConfiguration(_ operation: @escaping @MainActor () async -> Void) {
        let previous = configurationTask
        let setup = setupTask
        let closing = callTask
        let id = UUID()
        configurationID = id
        busy = true
        configurationTask = Task {
            await setup?.value
            await previous?.value
            await closing?.value
            guard !isShuttingDown else { return }
            await operation()
            if configurationID == id { configurationTask = nil; busy = false }
        }
    }

    func prepare(allowAvailableModel: Bool? = nil, suppliedModel: PreparedModel? = nil) {
        guard setupTask == nil, !isShuttingDown else { return }
        if allowAvailableModel == true { UserDefaults.standard.set(true, forKey: "allowAvailableLiteRT") }
        let allowed = allowAvailableModel ?? UserDefaults.standard.bool(forKey: "allowAvailableLiteRT")
        busy = true
        ready = false
        setupTask = Task {
            defer { setupTask = nil; busy = false }
            do {
                async let audioWarmup: Void = audio.prewarm()
                runtimeSHA = try RuntimeIdentity.load()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                status = "Ready"
                let modelStart = LatencyTrace.now()
                let model: PreparedModel
                if let suppliedModel { model = suppliedModel }
                else { model = try await models.prepare(allowUnverifiedQAT: allowed) }
                AudioTrace.latency.duration("startup.model_obtain_verify", since: modelStart)
                try Task.checkCancellation()
                if allowed { UserDefaults.standard.set(true, forKey: "allowAvailableLiteRT") }
                status = "Ready"
                let speechStart = LatencyTrace.now()
                try await speech.prepare()
                AudioTrace.latency.duration("startup.tts_prepare", since: speechStart)
                let vadStart = LatencyTrace.now()
                try await audio.prepare()
                try await audioWarmup
                AudioTrace.latency.duration("startup.vad_prepare", since: vadStart)
                // Account for speech allocations before committing the LM budget.
                let cap = try ModelPolicy.contextTokens(for: models.selectedArtifact, memory: SystemMemory.sample())
                let adjusted = PreparedModel(modelURL: model.modelURL, modelID: model.modelID,
                    revision: model.revision, contextTokens: min(cap, model.contextTokens),
                    artifactSHA256: model.artifactSHA256, supportsAudio: model.supportsAudio,
                    enableMTP: model.enableMTP, provenance: model.provenance)
                preparedModel = adjusted
                try await openJournal(model: adjusted)
                status = "Ready"
                notice = try await runtime.prepare(model: adjusted, systemPrompt: systemPrompt,
                                                  directory: conversationDirectory, runtimeSHA256: runtimeSHA, compiledCacheRoot: directory.appending(path: "Compiled"))
                try Task.checkCancellation()
                let voice = directory.appending(path: "voice.sample")
                if FileManager.default.fileExists(atPath: voice.path) {
                    do { try await speech.setVoice(referenceAudio: voice); voiceName = UserDefaults.standard.string(forKey: "voiceSampleName") ?? "Custom" }
                    catch { notice = "Saved voice could not be loaded. \(error.localizedDescription)" }
                }
                try Task.checkCancellation()
                ready = true
                status = "Ready"
                AudioTrace.latency.flush("startup_ready")
            } catch ModelStoreError.requiredQATUnavailable {
                status = "No verified QAT audio/MTP bundle is configured."
            } catch is CancellationError {
                await runtime.close()
                status = "Setup cancelled"
            } catch {
                status = "Setup failed"
                notice = error.localizedDescription
                await runtime.close()
            }
        }
    }

    var qualificationPendingTurns: Int { pendingUtterances.count }
    var qualificationRemainingFrames: Int { audio.qualificationRemainingFrames }
    var qualificationParticipantHandoffs: Int { participantTasks.count }
    var qualificationCallWakeFingerprint: String { callWakeModel?.fingerprint ?? "" }
    var qualificationCallID: String { inCall ? callID.uuidString : "" }
    var qualificationResponding: Bool { responseTask != nil }
    var qualificationRecovering: Bool { interruptionTask != nil }
    private(set) var qualificationCompletedTurns = 0
    var qualificationModelID: String { preparedModel?.modelID ?? "" }
    func qualificationInject(_ samples: [Float], referenceEnd: Int? = nil) throws {
        guard AppQualificationEnvironment.root != nil else { throw CocoaError(.featureUnsupported) }
        try audio.qualificationInject(samples, referenceEnd: referenceEnd)
    }

    func cancelSetup() { models.cancel(); setupTask?.cancel() }

    func selectPrompt(_ choice: PromptChoice) {
        guard choice != prompt, !isShuttingDown else { return }
        if inCall { toggleCall() }
        prompt = choice
        changePrompt()
    }

    func changePrompt() {
        UserDefaults.standard.set(prompt.rawValue, forKey: "prompt")
        enqueueConfiguration { [self] in
            guard let preparedModel else { return }
            do {
                try await openJournal(model: preparedModel)
                notice = try await runtime.prepare(model: preparedModel, systemPrompt: systemPrompt,
                                                  directory: conversationDirectory, runtimeSHA256: runtimeSHA, compiledCacheRoot: directory.appending(path: "Compiled"))
                ready = true
                if !inCall { status = "Ready" }
            } catch {
                ready = false
                status = "Could not open the conversation"
                notice = error.localizedDescription
            }
        }
    }

    func dialRemote(participants: [Persona], transport: RemoteCallTransport, memoryStore: MessageStore) async throws {
        guard acceptsTextWork, !busy, ready, let first = participants.first else {
            throw GemmaError(message: "The Mac is busy. Try again when its current task finishes.")
        }
        await callTask?.value
        guard acceptsTextWork, !busy else { throw GemmaError(message: "Audio is busy.") }
        try audio.useRemote(transport)
        dial(participants: participants, initialSpeaker: first.id, memoryStore: memoryStore)
    }

    /// Dial intent is applied synchronously; profile work is awaited by toggleCall.
    func dial(contact: Persona, memoryStore: MessageStore? = nil) {
        dial(participants: [contact], initialSpeaker: contact.id, memoryStore: memoryStore)
    }

    func dial(participants: [Persona], initialSpeaker: UUID, memoryStore: MessageStore? = nil) {
        guard acceptsTextWork else { return }
        let roster: CallRoster
        do { roster = try CallRoster(participants: participants, initialSpeaker: initialSpeaker) }
        catch { notice = error.localizedDescription; return }
        let contact = roster.initialContact
        callRoster = roster
        requestedCallParticipant = nil
        activeCallParticipant = contact.id
        if setupTask == nil, !ready { prepare(allowAvailableModel: true) }
        enqueueConfiguration { [self] in
            guard let model = preparedModel else { return }
            callRoster = roster
            callMemoryStore = memoryStore
            callMemoryContact = contact.id
            do {
                try await configureCallContact(contact, model: model)
            } catch { ready = false; notice = error.localizedDescription }
        }
        toggleCall()
    }

    /// Prepare the same canonical call profile used by dial, without starting
    /// capture, ringback, generation, or playback. Install/qualification workflows
    /// can rebuild an incompatible checkpoint before inviting a live call.
    func prepareCall(contact: Persona) async throws {
        guard acceptsTextWork, !busy, ready else {
            throw GemmaError(message: "The app is not idle for call preparation.")
        }
        var preparationError: Error?
        enqueueConfiguration { [self] in
            do {
                guard let model = preparedModel else { throw CheckpointError.invalidMetadata }
                try await configureCallContact(contact, model: model)
            } catch {
                ready = false
                notice = error.localizedDescription
                preparationError = error
            }
        }
        await configurationTask?.value
        if let preparationError { throw preparationError }
    }

    private func configureCallContact(_ contact: Persona, model: PreparedModel) async throws {
        await WakeNameEnrollment.shared.pause(reason: "configuration")
        defer { WakeNameEnrollment.shared.resume(reason: "configuration") }
        profileDirectory = directory.appending(path: "Contacts/" + contact.id.uuidString + "/Calls")
        profilePrompt = contact.prompt
        textSession = nil
        try await openJournal(model: model)
        notice = try await runtime.prepare(model: model, systemPrompt: systemPrompt,
            directory: conversationDirectory, runtimeSHA256: runtimeSHA, compiledCacheRoot: directory.appending(path: "Compiled"))
        let voice = contact.voice.flatMap { name in
            name.hasPrefix("/") ? URL(fileURLWithPath: name) : BlessengerResources.voiceURL(name)
        }
        try await speech.setVoice(referenceAudio: voice)
        ready = true
    }

    var wakeTrainingShouldPause: Bool { busy || inCall || textBusy || noteRecording != nil || playingVoiceNote != nil || isShuttingDown }
    var acceptsTextWork: Bool { !inCall && !textBusy && !isShuttingDown && noteRecording == nil && playingVoiceNote == nil }

    func startVoiceNoteRecording() async throws {
        guard acceptsTextWork else { throw GemmaError(message: "Audio is already in use.") }
        let recording = VoiceNoteRecording()
        noteRecording = recording
        await WakeNameEnrollment.shared.pause(reason: "recording")
        do {
            let events = try await audio.start(recording: recording)
            noteCaptureTask = Task { for try await _ in events {} }
        } catch {
            await cancelVoiceNoteRecording()
            throw error
        }
    }

    func voiceNoteLevels() async -> [Float] { await noteRecording?.levels() ?? [] }

    func voiceNoteElapsed() async -> Double { await noteRecording?.elapsed() ?? 0 }

    func finishVoiceNoteRecording() async throws -> URL {
        guard let recording = noteRecording else { throw CallAudioError.invalidVoice }
        await audio.finishRecordingCapture()
        do {
            try await noteCaptureTask?.value
            let file = try await recording.finish()
            noteRecording = nil
            WakeNameEnrollment.shared.resume(reason: "recording")
            noteCaptureTask = nil
            return file
        } catch { await cancelVoiceNoteRecording(); throw error }
    }

    func cancelVoiceNoteRecording() async {
        guard let recording = noteRecording else { return }
        audio.stop()
        await audio.settleAudio()
        noteCaptureTask?.cancel()
        _ = try? await noteCaptureTask?.value
        await recording.cancel()
        noteCaptureTask = nil
        noteRecording = nil
        WakeNameEnrollment.shared.resume(reason: "recording")
    }

    func toggleVoiceNote(_ message: ChatMessage, contact: Persona? = nil) {
        if playingVoiceNote == message.id {
            voiceNotePaused.toggle()
            if let recordedNotePlayer {
                if voiceNotePaused { recordedNotePlayer.pause() } else { recordedNotePlayer.play() }
            } else {
                noteSeek = Int(voiceNotePosition * 24_000)
                audio.interruptPlayback()
            }
            return
        }
        if playingVoiceNote != nil {
            Task { await stopVoiceNotePlayback(); toggleVoiceNote(message, contact: contact) }
            return
        }
        guard acceptsTextWork else { return }
        playingVoiceNote = message.id
        voiceNotePosition = 0; voiceNoteDuration = 0; voiceNotePaused = false
        notePCM = []; noteCursor = 0; noteSeek = nil; noteProduced = false
        notePlaybackTask = Task {
            await WakeNameEnrollment.shared.pause(reason: "playback")
            defer { WakeNameEnrollment.shared.resume(reason: "playback") }
            var producer: Task<Void, Error>?
            do {
                if let attachment = message.attachments.first(where: { $0.kind == .audio }) {
                    let data = try await Task.detached { try Data(contentsOf: attachment.url) }.value
                    try Task.checkCancellation()
                    let player = try AVAudioPlayer(data: data)
                    player.volume = AutomatedAudioOutput.volume
                    recordedNotePlayer = player
                    voiceNoteDuration = player.duration
                    if !player.play() {
                        // Core Audio can still be releasing the preceding output graph.
                        try await Task.sleep(for: .milliseconds(100))
                        guard player.play() else { throw CallAudioError.unavailable("Audio playback could not start.") }
                    }
                    repeat {
                        try await Task.sleep(for: .milliseconds(30))
                        voiceNotePosition = player.currentTime
                    } while player.isPlaying || voiceNotePaused
                } else if let contact, message.voiceNote == true {
                    let voice = contact.voice.flatMap { name in
                        name.hasPrefix("/") ? URL(fileURLWithPath: name) : BlessengerResources.voiceURL(name)
                    }
                    try await speech.setVoice(referenceAudio: voice)
                    try Task.checkCancellation()
                    try await audio.startNotePlayback()
                    producer = Task {
                        defer { noteProduced = true }
                        try await speech.streamVoiceNote(message.text) { [weak self] samples in
                            try await self?.appendNotePCM(samples)
                        }
                    }
                    var base = 0
                    var segment = UUID()
                    audio.beginPlaybackResponse(UUID())
                    try audio.beginPlaybackSegment(segment, text: message.text)
                    while true {
                        try Task.checkCancellation()
                        if let seek = noteSeek {
                            noteSeek = nil; noteCursor = seek; base = seek
                            audio.interruptPlayback()
                            audio.beginPlaybackResponse(UUID())
                            segment = UUID()
                            try audio.beginPlaybackSegment(segment, text: message.text)
                        }
                        voiceNotePosition = Double(base + Int(audio.playbackPosition())) / 24_000
                        if voiceNotePaused { try await Task.sleep(for: .milliseconds(30)); continue }
                        if noteCursor < notePCM.count {
                            let end = min(noteCursor + 1_920, notePCM.count)
                            let frame = Array(notePCM[noteCursor..<end])
                            do {
                                try await audio.play(frame, segment: segment)
                                if noteSeek == nil { noteCursor = end }
                            } catch is CancellationError {
                                if Task.isCancelled { throw CancellationError() }
                                // Seeking invalidates scheduled buffers, not synthesis.
                                continue
                            }
                        } else if noteProduced {
                            try await producer?.value
                            do { try await audio.drainPlayback() }
                            catch is CancellationError { if noteSeek != nil { continue }; throw CancellationError() }
                            voiceNotePosition = voiceNoteDuration
                            break
                        } else { try await Task.sleep(for: .milliseconds(10)) }
                    }
                }
            } catch is CancellationError {} catch { notice = error.localizedDescription }
            producer?.cancel()
            _ = try? await producer?.value
            recordedNotePlayer?.stop(); recordedNotePlayer = nil
            audio.stop(); await audio.settleAudio()
            notePCM = []; voiceNotePaused = false
            playingVoiceNote = nil; notePlaybackTask = nil
        }
    }
    private func appendNotePCM(_ samples: [Float]) throws {
        try Task.checkCancellation()
        guard notePCM.count + samples.count <= 24_000 * 120 else {
            throw GemmaError(message: "This voice note exceeds the two-minute playback limit.")
        }
        notePCM.append(contentsOf: samples)
        voiceNoteDuration = Double(notePCM.count) / 24_000
    }
    func seekVoiceNote(to fraction: Double) {
        let seconds = min(1, max(0, fraction)) * voiceNoteDuration
        voiceNotePosition = seconds
        if let recordedNotePlayer { recordedNotePlayer.currentTime = seconds }
        else { noteSeek = min(notePCM.count, Int(seconds * 24_000)); audio.interruptPlayback() }
    }
    func stopVoiceNotePlayback() async {
        guard notePlaybackTask != nil else { return }
        notePlaybackTask?.cancel()
        recordedNotePlayer?.stop()
        audio.interruptPlayback()
        await notePlaybackTask?.value
    }

    func replyToMessage(_ json: String, contact: Persona, thread: UUID, history: ConversationHistory) async throws -> String {
        guard acceptsTextWork else {
            throw GemmaError(message: "Finish the active call or reply first.")
        }
        textBusy = true
        await WakeNameEnrollment.shared.pause(reason: "text")
        if setupTask == nil, !ready { prepare(allowAvailableModel: true) }
        await setupTask?.value
        await configurationTask?.value
        guard let model = preparedModel, ready else { throw GemmaError(message: notice ?? "The model is unavailable.") }
        let identity = contact.id.uuidString + "/" + thread.uuidString + "/" + digest(Data(contact.prompt.utf8))
        if textSession != identity || textHistory != history {
            let folder = directory.appending(path: "Contacts/" + contact.id.uuidString + "/Chats/" + thread.uuidString)
            let files = TranscriptFiles(directory: GemmaRuntime.conversationDirectory(model: model, prompt: contact.prompt, directory: folder))
            try await Task.detached(priority: .userInitiated) { try files.commit(history: history, turn: nil) }.value
            textTranscript = files
            _ = try await runtime.prepare(model: model, systemPrompt: contact.prompt, directory: folder,
                runtimeSHA256: runtimeSHA, compiledCacheRoot: directory.appending(path: "Compiled"))
            textSession = identity
            textHistory = history
        }
        _ = try await runtime.beginTurn()
        var answer = ""
        do {
            for try await chunk in runtime.respond(audioFile: directory, messageJSON: json) { answer += chunk }
            guard !answer.isEmpty else { throw GemmaError(message: "The model returned an empty response.") }
            return answer
        } catch { textSession = nil; throw error }
    }

    func persistTextReply(history: ConversationHistory) async throws {
        defer { textBusy = false; WakeNameEnrollment.shared.resume(reason: "text") }
        guard let files = textTranscript else { throw GemmaError(message: "No text conversation is active.") }
        do {
            let nativeJSON = try await runtime.history()
            let matches = try await Task.detached(priority: .userInitiated) {
                try ConversationHistory(json: nativeJSON) == history
            }.value
            try await Task.detached(priority: .userInitiated) { try files.commit(history: history, turn: nil) }.value
            // A deletion may arrive while generation is running. Never publish
            // the obsolete native continuation as the canonical chat cache.
            if !matches { _ = try await runtime.recover() }
            try await runtime.save()
            textHistory = history
        } catch { textSession = nil; textHistory = nil; throw error }
    }

    func abandonTextReply() { textSession = nil; textHistory = nil; textBusy = false; WakeNameEnrollment.shared.resume(reason: "text") }



    /// A remote hang-up response is a release barrier for the next admission.
    /// Sound and call intent stop synchronously; model/audio teardown completes
    /// in callTask. Never join a newly active call from an old close request.
    func waitForCallTeardown() async {
        guard !inCall else { return }
        let stopping = callTask
        await stopping?.value
    }

    func toggleCall() {
        guard !isShuttingDown, !textBusy, noteRecording == nil, playingVoiceNote == nil else { return }
        let previous = callTask
        if inCall {
            // User intent and sound change before any asynchronous cleanup.
            inCall = false
            dialing = false
            callID = UUID()
            status = "Ready"
            ringback.stop()
            audio.stop()
            previous?.cancel()
            responseTask?.cancel()
            runtime.cancelResponse()
            callTask = Task {
                await previous?.value
                await endCall(preserveRequest: true)
                if !inCall { callTask = nil }
            }
            return
        }
        let id = UUID()
        callID = id
        callConnectedAt = nil
        microphoneMuted = false
        audio.microphoneMuted = false
        inCall = true
        dialing = true
        status = "Calling"
        AudioTrace.latency.mark("call.button")
        if !audio.isRemote { ringback.start() }
        let pendingConfiguration = configurationTask
        callTask = Task {
            await WakeNameEnrollment.shared.pause()
            await previous?.value
            guard inCall, callID == id, !Task.isCancelled else { return }
            if !ready, setupTask == nil { prepare(allowAvailableModel: true) }
            await setupTask?.value
            guard inCall, callID == id, !Task.isCancelled else { return }
            await pendingConfiguration?.value
            guard inCall, callID == id, !Task.isCancelled else { return }
            guard ready else {
                inCall = false; dialing = false; ringback.stop(); callTask = nil
                WakeNameEnrollment.shared.resume()
                if audio.isRemote { audio.stop() }
                return
            }
            await startCall(id: id)
            if callID == id { callTask = nil }
        }
    }

    private func startCall(id: UUID) async {
        callWakeModel = WakeNameEnrollment.shared.model
        audio.awaitPickup()
        audio.onFirstSpeech = { [weak self] in
            guard let self, self.inCall, self.callID == id else { return }
            self.ringback.stop()
            self.dialing = false
            self.callConnectedAt = Date()
            self.status = "Speaking"
            AudioTrace.latency.mark("call.pickup")
        }
        audioDiagnostics = "Waiting for microphone frames."
        do {
            callChatContext = "[]"
            sharedCallHistory = nil
            if let roster = callRoster, roster.participants.count > 1, let model = preparedModel {
                let participants = roster.memoryParticipants(model: model, directory: directory)
                sharedCallHistory = try await Task.detached(priority: .userInitiated) {
                    try SharedCallHistory(call: id, participants: participants)
                }.value
                guard inCall, callID == id else { throw CancellationError() }
            }
            if let store = callMemoryStore, let contact = callMemoryContact, let model = preparedModel {
                guard let roster = callRoster else { throw CheckpointError.invalidMetadata }
                try await store.registerCall(id: id, participants: roster.memoryParticipants(model: model, directory: directory))
                registeredMemoryCall = id
                callChatContext = try await store.chatContextForCall(contact: contact)
                guard inCall, callID == id, !Task.isCancelled else { return }
            }
            if let shared = sharedCallHistory, let participant = activeCallParticipant {
                let previous = try JSONSerialization.jsonObject(with: Data(callChatContext.utf8)) as? [[String: Any]] ?? []
                callChatContext = String(decoding: try JSONSerialization.data(withJSONObject:
                    shared.context(for: participant) + previous, options: [.sortedKeys]), as: UTF8.self)
            }
            let events = try await audio.start()
            try Task.checkCancellation()
            guard !isShuttingDown, callID == id else { audio.stop(); return }
            inCall = true
            status = "Calling"
            eventTask = Task {
                defer { AudioTrace.latency.mark("capture.event_consumer_exit"); AudioTrace.latency.flush("capture_event_consumer_exit") }
                do {
                    for try await event in events {
                        guard inCall, callID == id else { return }
                        if dialing { continue }
                        switch event {
                        case .diagnostics(let value): audioDiagnostics = value
                        case .notice(let value): notice = value
                        case .input(let inputID, let samples, let begin):
                            if begin {
                                // A prior endpoint is still waiting for recovery. Retain
                                // this utterance, but do not open a competing native input.
                                if !pendingUtterances.isEmpty {
                                    activeInput = (inputID, nil, nil, requestedCallParticipant, requestedCallParticipant != nil)
                                    requestedCallParticipant = nil
                                    continue
                                }
                                let interruption = interruptionTask
                                let response = responseTask
                                let selected = requestedCallParticipant
                                requestedCallParticipant = nil
                                let handoff: Task<Void, Error>?
                                if let selected, selected != activeCallParticipant {
                                    let handoffID = UUID()
                                    handoff = Task {
                                        defer { self.participantTasks.removeValue(forKey: handoffID) }
                                        await interruption?.value
                                        await response?.value
                                        try Task.checkCancellation()
                                        try await self.activateCallParticipant(selected, call: id)
                                    }
                                    participantTasks[handoffID] = handoff
                                } else { handoff = nil }
                                let stream = StreamingAudioInput(runtime: runtime) {
                                    await interruption?.value
                                    await response?.value
                                    try await handoff?.value
                                }
                                activeInput = (inputID, stream, handoff, nil, selected != nil)
                                needsRecovery = true
                            }
                            guard activeInput?.id == inputID else { throw CheckpointError.invalidMetadata }
                            guard let stream = activeInput?.stream else { continue }
                            let appendStart = LatencyTrace.now()
                            if begin { AudioTrace.latency.mark("capture.input_append_begin", turn: inputID) }
                            try await stream.append(samples)
                            AudioTrace.latency.duration("capture.input_append_wait", since: appendStart)
                            if begin { AudioTrace.latency.mark("capture.input_append_admitted", turn: inputID) }
                        case .speechStarted:
                            AudioTrace.latency.mark("capture.speech_event_received")
                            if responseTask != nil && !savingResponse { interruptResponse() }
                        case .candidate(let candidate, let samples, let endpointNS):
                            let gate = SpeculativeEndpoint(id: candidate)
                            speculativeEndpoint = gate
                            try enqueueUtterance(PendingCallUtterance(samples: samples, endpointNS: endpointNS, gate: gate,
                                prefill: activeInput?.id == candidate ? activeInput?.stream : nil,
                                handoff: activeInput?.id == candidate ? activeInput?.handoff : nil,
                                participant: activeInput?.id == candidate ? activeInput?.participant : nil,
                                manualSelection: activeInput?.id == candidate && activeInput?.manualSelection == true))
                            if responseTask != nil && !savingResponse { interruptResponse() }
                            launchPendingResponse()
                        case .confirmed(let candidate):
                            if speculativeEndpoint?.id == candidate { try await speculativeEndpoint?.confirm() }
                        case .resumed(let candidate):
                            if speculativeEndpoint?.id == candidate { speculativeEndpoint?.revoke() }
                            if let index = pendingUtterances.firstIndex(where: { $0.gate?.id == candidate }) {
                                let abandoned = pendingUtterances.remove(at: index)
                                abandoned.gate?.revoke()
                                Task { await abandoned.prefill?.cancel() }
                            }
                            if responseEndpoint?.id == candidate { interruptResponse() }
                        case .utterance(let samples, let endpointNS):
                            AudioTrace.signposter.emitEvent("Utterance complete")
                            try enqueueUtterance(PendingCallUtterance(samples: samples, endpointNS: endpointNS, gate: nil,
                                prefill: activeInput?.stream, handoff: activeInput?.handoff, participant: activeInput?.participant,
                                manualSelection: activeInput?.manualSelection == true))
                            if responseTask != nil && !savingResponse { interruptResponse() }
                            launchPendingResponse()
                        }
                    }
                } catch is CancellationError {
                } catch {
                    AudioTrace.logger.error("Call capture failed: \(error.localizedDescription, privacy: .public)")
                    notice = error.localizedDescription
                    stopCallAfterError()
                }
            }
            pendingGreeting = true
            launchPendingResponse()
        } catch is CancellationError {
            audio.stop()
            if callID == id { inCall = false; dialing = false; ringback.stop(); status = "Ready" }
        } catch {
            audio.stop()
            if callID == id {
                inCall = false; dialing = false; ringback.stop()
                status = "Could not start the call"
                notice = error.localizedDescription
            }
        }
    }

    private func stopCallAfterError() {
        guard callTask == nil, !isShuttingDown else { return }
        busy = true
        callTask = Task {
            defer { callTask = nil; busy = false }
            await endCall()
        }
    }

    private func enqueueUtterance(_ utterance: PendingCallUtterance) throws {
        guard pendingUtterances.count < 16,
              pendingUtterances.reduce(utterance.samples.count, { $0 + $1.samples.count }) <= 480_000 else {
            throw GemmaError(message: "The call has reached its pending speech limit.")
        }
        pendingUtterances.append(utterance)
        AudioTrace.latency.mark("capture.utterance_enqueued", turn: utterance.gate?.id)
    }

    private func launchPendingResponse() {
        guard inCall, responseTask == nil, interruptionTask == nil,
              pendingGreeting || !pendingUtterances.isEmpty else { return }
        let greeting = pendingGreeting
        let utterance = greeting
            ? PendingCallUtterance(samples: [], endpointNS: LatencyTrace.now(), gate: nil, prefill: nil, handoff: nil)
            : pendingUtterances.removeFirst()
        pendingGreeting = false
        responseEndpoint = utterance.gate
        responseInput = utterance.prefill
        // Correlate detector thresholds with this speculative attempt even
        // when recovery delays admission to the runtime.
        let id = utterance.gate?.id ?? UUID()
        responseID = id
        savingResponse = false
        let currentCall = callID
        responseTask = Task {
            defer {
                if responseID == id {
                    responseTask = nil
                    responseEndpoint = nil
                    savingResponse = false
                    launchPendingResponse()
                }
            }
            var failureStage = "journal admission"
            var prefill = utterance.prefill
            do {
                AudioTrace.latency.mark(greeting ? "call.greeting" : "speech.endpoint_estimate", turn: id, at: utterance.endpointNS)
                AudioTrace.latency.mark("turn.start", turn: id)
                status = "Generating"
                AudioTrace.logger.notice("Gemma response starting")
                if let participant = utterance.participant {
                    try await activateCallParticipant(participant, call: currentCall)
                }
                try await utterance.handoff?.value
                if !greeting, !utterance.manualSelection, callParticipants.count > 1, utterance.participant == nil,
                   utterance.handoff == nil {
                    let started = LatencyTrace.now()
                    let wakeID = UUID()
                    let decoder = wakePhonetics
                    let wakeNames = callParticipants.map { WakeNameModel.Name(id: $0.id, name: $0.wakeName) }
                    let classifier = callWakeModel?.classifier
                    let selection = Task { try await decoder.recipient(utterance.samples,
                        names: wakeNames, classifier: classifier, diagnosticID: id) }
                    wakeTasks[wakeID] = selection
                    let recipient = try? await selection.value
                    wakeTasks.removeValue(forKey: wakeID)
                    // A later speech start cancels the reply, not already
                    // confirmed user input. Hang-up separately cancels this task.
                    if utterance.gate?.inputConfirmed == false { try Task.checkCancellation() }
                    guard inCall, callID == currentCall else { throw CancellationError() }
                    if let recipient,
                       recipient != activeCallParticipant {
                        // Stop and join the old speculative input before replacing
                        // its context. The retained complete PCM is admitted once to
                        // the addressed participant; it is never lost or fed twice.
                        await prefill?.cancel()
                        prefill = nil
                        let handoffID = UUID()
                        let handoff = Task {
                            defer { self.participantTasks.removeValue(forKey: handoffID) }
                            try await self.activateCallParticipant(recipient, call: currentCall)
                        }
                        participantTasks[handoffID] = handoff
                        try await handoff.value
                        AudioTrace.latency.mark("wake.handoff", turn: id)
                    }
                    AudioTrace.latency.duration("wake.selection", since: started)
                }
                // A confirmed user input must reach the journal even if a new
                // utterance has already cancelled its proposed response.
                if greeting || utterance.gate?.inputConfirmed == false { try Task.checkCancellation() }
                guard inCall, callID == currentCall else { throw CancellationError() }
                needsRecovery = true
                guard let journal else { throw CheckpointError.invalidMetadata }
                let waveStart = LatencyTrace.now()
                let turn = try await greeting ? journal.stageGreeting(contextJSON: callChatContext) : journal.stage(samples: utterance.samples)
                AudioTrace.latency.duration("turn.audio_stage", since: waveStart)
                AudioTrace.latency.mark("gemma.submit", turn: id)
                // A speculative journal is discardable on cancellation or crash.
                // LM and TTS run ahead; only device playback waits for silence.
                let admission = LatencyTrace.now()
                try await journal.admit(turn, speculative: utterance.gate != nil)
                if let gate = utterance.gate {
                    try await gate.bindInputAdmission { try await journal.confirm(turn: turn.id) }
                }
                AudioTrace.latency.duration("turn.journal_admission", since: admission)
                try Task.checkCancellation()
                let endpointGate = utterance.gate
                failureStage = "speech admission"
                try await speech.beginResponse(traceTurn: id, journal: journal, turn: turn.id,
                    playbackAdmission: {
                        try await endpointGate?.wait()
                        try Task.checkCancellation()
                        try await journal.confirm(turn: turn.id)
                    })
                failureStage = "runtime turn admission"
                let beginStart = LatencyTrace.now()
                if let prefill {
                    try await prefill.finish(expectedSamples: utterance.samples.count)
                } else if let message = try await runtime.beginTurn() { notice = message }
                try Task.checkCancellation()
                AudioTrace.latency.duration("runtime.begin_turn", since: beginStart)
                let stream = runtime.respond(audioFile: turn.audioURL, messageJSON: turn.messageJSON, traceTurn: id)
                var firstText = true
                failureStage = "model stream"
                for try await delta in stream {
                    try Task.checkCancellation()
                    if firstText {
                        AudioTrace.signposter.emitEvent("First Gemma text")
                        firstText = false
                        AudioTrace.latency.mark("gemma.first_text", turn: id)
                        AudioTrace.logger.notice("First Gemma text received")
                    }
                    if !dialing { status = "Speaking" }
                    failureStage = "speech append"
                    try await speech.append(delta)
                    failureStage = "model stream"
                }
                failureStage = "speech completion"
                AudioTrace.latency.mark("gemma.stream_end", turn: id)
                try await speech.finishResponse()
                AudioTrace.latency.mark("playback.drained", turn: id)
                AudioTrace.logger.notice("Speech playback drained")
                try Task.checkCancellation()
                savingResponse = true
                status = "Saving conversation…"
                let saveStart = LatencyTrace.now()
                try await speech.freezeHeardProgress()
                let nativeHistory = try await runtime.history()
                let history = try ConversationHistory(json: nativeHistory)
                guard let last = history.messages.last else { throw CheckpointError.invalidMetadata }
                let heard = try GeneratedText.decode(String(decoding: last, as: UTF8.self))
                try await journal.commit(heardText: heard, nativeHistory: nativeHistory)
                try await runtime.save(turn: id)
                needsRecovery = false
                AudioTrace.latency.duration("checkpoint.save", since: saveStart)
                qualificationCompletedTurns += 1
                AudioTrace.latency.mark("turn.captured", turn: id)
                AudioTrace.latency.flush("turn_complete")
                guard inCall, callID == currentCall, responseID == id else { return }
                status = "Listening"
            } catch is CancellationError {
                AudioTrace.latency.mark("turn.cancelled", turn: id)
                AudioTrace.latency.flush("turn_cancelled")
            } catch {
                // Barge-in can clear playback while an awaited audio operation
                // returns its own error. The interruption task owns recovery;
                // do not report a failed turn or start a second recovery here.
                if Task.isCancelled {
                    AudioTrace.latency.mark("turn.cancelled", turn: id)
                    AudioTrace.latency.flush("turn_cancelled")
                    return
                }
                AudioTrace.logger.error("Call response failed during \(failureStage, privacy: .public): \(error.localizedDescription, privacy: .public)")
                AudioTrace.latency.mark("turn.failed", turn: id)
                AudioTrace.latency.flush("turn_failed")
                guard inCall, responseID == id else { return }
                notice = error.localizedDescription
                if greeting { ringback.stop(); dialing = false }
                audio.interruptPlayback()
                await speech.cancel()
                do { try await recoverHeardTurn(); _ = try await runtime.recover(); needsRecovery = false; status = "Listening" }
                catch { notice = error.localizedDescription; ready = false; audio.stop(); inCall = false; status = "Call ended" }
            }
        }
    }

    private func interruptResponse() {
        guard interruptionTask == nil, let responseTask else { return }
        audio.interruptPlayback()
        responseEndpoint?.revoke()
        responseID = UUID()
        responseTask.cancel()
        runtime.cancelResponse()
        status = "Interrupting…"
        let input = responseInput
        interruptionTask = Task {
            await input?.cancel()
            await speech.cancel()
            await responseTask.value
            self.responseTask = nil
            do {
                try await recoverHeardTurn()
                let message = try await runtime.recover()
                needsRecovery = false
                if let message, message != "Conversation restored." { notice = message }
            } catch {
                notice = error.localizedDescription
                ready = false
                audio.stop()
                inCall = false
            }
            interruptionTask = nil
            if inCall { status = "Listening"; launchPendingResponse() }
        }
    }

    func endCall(preserveRequest: Bool = false) async {
        if !preserveRequest {
            inCall = false
            dialing = false
            ringback.stop()
            status = "Ready"
            callID = UUID()
        }
        busy = true
        requestedCallParticipant = nil
        callWakeModel = nil
        let selections = Array(wakeTasks.values)
        for selection in selections { selection.cancel() }
        wakeTasks.removeAll()
        let handoffs = Array(participantTasks.values)
        for handoff in handoffs { handoff.cancel() }
        pendingGreeting = false
        let pendingInputs = pendingUtterances
        pendingUtterances.removeAll()
        for pending in pendingInputs { pending.gate?.revoke() }
        responseEndpoint?.revoke()
        speculativeEndpoint = nil
        audio.stop()
        eventTask?.cancel()
        eventTask = nil
        responseTask?.cancel()
        runtime.cancelResponse()
        let hadOpenInput = await activeInput?.stream?.cancel() ?? false
        await responseInput?.cancel()
        for pending in pendingInputs { await pending.prefill?.cancel() }
        activeInput = nil
        responseInput = nil
        for selection in selections { _ = await selection.result }
        for handoff in handoffs { _ = await handoff.result }
        participantTasks.removeAll()
        activeCallParticipant = nil
        await speech.cancel()
        await responseTask?.value
        responseTask = nil
        await interruptionTask?.value
        interruptionTask = nil
        needsRecovery = needsRecovery || hadOpenInput
        do {
            if needsRecovery {
                try await recoverHeardTurn()
                _ = try await runtime.recover()
                needsRecovery = false
            }
            if let id = registeredMemoryCall, let store = callMemoryStore {
                try await store.finishCall(id: id)
                registeredMemoryCall = nil
            }
            if !inCall { status = "Ready" }
        } catch { ready = false; if !inCall { status = "Call ended" }; notice = error.localizedDescription }
        busy = false
        if !isShuttingDown, !inCall { WakeNameEnrollment.shared.resume() }
    }

    private func openJournal(model: PreparedModel) async throws {
        let folder = GemmaRuntime.conversationDirectory(model: model, prompt: systemPrompt, directory: conversationDirectory)
        journal = HeardTurnJournal(directory: folder)
        try await recoverHeardTurn(freeze: false)
    }

    private func recoverHeardTurn(freeze: Bool = true) async throws {
        guard let journal else { return }
        if freeze { try await speech.freezeHeardProgress() }
        try await journal.discardSpeculation()
        guard try await journal.loadPending() != nil else { return }
        let speech = self.speech
        let text = try await spokenRecovery.text(journal: journal, modelDirectory: AudioModelPins.alignerDirectory) {
            segment, prompt in try await speech.renderReference(segment, prompt: prompt)
        }
        try await journal.commit(heardText: text)
    }

    func reportVoiceError(_ error: Error) {
        voiceError = error.localizedDescription
        notice = "Voice import failed. \(error.localizedDescription)"
        AudioTrace.logger.error("Voice import failed: \(error.localizedDescription, privacy: .public)")
    }

    func clearVoiceError() { voiceError = nil }

    func importVoice(_ source: URL, name: String? = nil, removeSource: Bool = false) {
        guard !isShuttingDown else { return }
        if inCall { toggleCall() }
        voiceImporting = true
        voiceError = nil
        enqueueConfiguration { [self] in
            defer { voiceImporting = false; if !inCall { status = "Ready" } }
            status = "Importing"
            defer { if removeSource { try? FileManager.default.removeItem(at: source) } }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let temporary = directory.appending(path: "voice-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try VoiceSample.export(from: source, start: 0, duration: 10, to: temporary)
                }.value
                try Task.checkCancellation()
                let destination = directory.appending(path: "voice.sample")
                try await speech.setVoice(referenceAudio: temporary, commit: {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                    } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                })
                voiceName = name ?? source.deletingPathExtension().lastPathComponent
                UserDefaults.standard.set(voiceName, forKey: "voiceSampleName")
                AudioTrace.logger.notice("Voice sample imported")
            } catch is CancellationError {
            } catch { reportVoiceError(error) }
        }
    }

    func resetVoice() {
        guard !isShuttingDown else { return }
        if inCall { toggleCall() }
        enqueueConfiguration { [self] in
            do {
                let file = directory.appending(path: "voice.sample")
                try await speech.setVoice(referenceAudio: nil, commit: {
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                })
                voiceName = "Default"
                UserDefaults.standard.removeObject(forKey: "voiceSampleName")
            } catch is CancellationError {
            } catch { notice = error.localizedDescription }
        }
    }

    func shutdown() async -> Bool {
        isShuttingDown = true
        await stopVoiceNotePlayback()
        await cancelVoiceNoteRecording()
        callID = UUID()
        callTask?.cancel()
        audio.stop()
        cancelSetup()
        await setupTask?.value
        await configurationTask?.value
        await callTask?.value
        await endCall()
        await speech.cancel()
        do { try await runtime.flushPersistence() }
        catch {
            notice = "Conversation could not be saved. \(error.localizedDescription)"
            status = "Save failed"
            isShuttingDown = false
            return false
        }
        await runtime.close()
        await audio.shutdownAudio()
        return true
    }
}
