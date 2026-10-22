import CLiteRTLM
import Darwin
import Foundation

private func checked(_ status: LiteRtLmStatusCode) throws {
    guard status == kLiteRtLmStatusOk else {
        // The C error is thread-local. Copy it before leaving this thread.
        throw GemmaError(message: litert_lm_get_last_error_message().map(String.init(cString:))
                         ?? "LiteRT-LM failed with status \(status.rawValue).")
    }
}

/// Every handle operation runs on one dedicated queue. Waiting for a native
/// stream never blocks the UI or Swift's cooperative executor.
final class GemmaRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CallGemma.LiteRT", qos: .userInitiated)
    private let streamLock = NSLock()
    private let checkpointWriter = CheckpointWriter()
    private let checkpointReadAhead = CheckpointReadAhead()
    private var activeStream: NativeStream?
    private var engine: OpaquePointer?
    private var conversation: OpaquePointer?
    private var model: PreparedModel?
    private var configuration: RuntimeConfiguration?
    private var checkpoint: CheckpointStore?
    private var captureDirectory: URL?
    // Set only at a completed restore/capture boundary, and invalidated before
    // any native mutation. History equality alone cannot detect open audio or
    // a speculative KV tail that has not entered public history yet.
    private var residentHistory: ConversationHistory?
    private var lastCapture: OwnedCacheSnapshot?
    private var compiledCache: URL?
    private var maximumTurnReserve: Int?

    static func conversationDirectory(model: PreparedModel, prompt: String, directory: URL) -> URL {
        directory.appending(path: "Conversations-v3")
            .appending(path: digest(Data((model.artifactSHA256 + prompt).utf8)))
    }

    func prepare(model: PreparedModel, systemPrompt: String, directory: URL,
                 runtimeSHA256: String, compiledCacheRoot: URL? = nil) async throws -> String? {
        try await checkpointWriter.retryAndFlush()
        let restored = try await perform {
            let start = LatencyTrace.now()
            guard model.supportsAudio else { throw GemmaError(message: "This model has no audio encoder.") }
            let store = CheckpointStore(directory: Self.conversationDirectory(model: model, prompt: systemPrompt,
                                                                             directory: directory))
            var config = RuntimeConfiguration(
                modelSHA256: model.artifactSHA256, modelRevision: model.revision,
                runtimeSHA256: runtimeSHA256, systemPrompt: systemPrompt,
                contextTokens: model.contextTokens, enableMTP: model.enableMTP)
            if let previous = try? store.currentRecord(),
               previous.configuration.matchesIgnoringCapacity(config),
               previous.configuration.contextTokens >= ModelPolicy.minimumContextTokens,
               previous.configuration.contextTokens <= config.contextTokens,
               previous.configuration.contextTokens % 4 == 0 {
                // Available RAM changes between launches. Keep a safe previously
                // allocated capacity so harmless fluctuations do not miss cache.
                config.contextTokens = previous.configuration.contextTokens
            }
            if self.engine != nil, self.conversation != nil,
               self.configuration == config,
               self.checkpoint?.directory.standardizedFileURL.path == store.directory.standardizedFileURL.path,
               let resident = self.residentHistory,
               let canonical = try TranscriptFiles(directory: store.directory).load(),
               try ConversationHistory(json: canonical.historyJSON) == resident {
                AudioTrace.latency.duration("runtime.reuse_conversation", since: start)
                return Restoration(notice: "Conversation restored.", replayed: false)
            }
            self.residentHistory = nil
            // A prompt selects conversation state, not model weights. Keep the
            // executor when its allocation and runtime identity are unchanged.
            let reusable = self.engine != nil && self.configuration.map { previous in
                RuntimeConfiguration(modelSHA256: previous.modelSHA256,
                    modelRevision: previous.modelRevision, runtimeSHA256: previous.runtimeSHA256,
                    systemPrompt: systemPrompt, contextTokens: previous.contextTokens,
                    enableMTP: previous.enableMTP) == config
            } == true
            if reusable {
                if let conversation = self.conversation { litert_lm_conversation_delete(conversation) }
                self.conversation = nil
            } else { self.destroy() }
            self.model = model
            self.configuration = config
            self.maximumTurnReserve = nil
            self.checkpoint = store
            self.captureDirectory = directory.appending(path: "Capture", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: self.captureDirectory!, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            self.lastCapture = nil
            // Compiled weights belong to the model/runtime, never to a persona or chat.
            // Standalone qualification callers may keep an isolated default root.
            self.compiledCache = (compiledCacheRoot ?? directory.appending(path: "Compiled"))
                .appending(path: runtimeSHA256).appending(path: model.artifactSHA256)
            try FileManager.default.createDirectory(at: self.compiledCache!, withIntermediateDirectories: true)
            if !reusable {
                try self.createEngine()
                if ProcessInfo.processInfo.environment["CALL_GEMMA_QUALIFY_DECODE_WARMUP"] != "0" {
                    try self.warmDecoder()
                }
            }
            let notice = try self.restoreConversation()
            AudioTrace.latency.duration(reusable ? "runtime.switch_conversation" : "runtime.load_engine", since: start)
            return notice
        }
        try await preserveRestoredPrefix(restored)
        return restored.notice
    }

    func beginAudioInput() async throws {
        _ = try await beginTurn()
        try await perform {
            let start = LatencyTrace.now()
            defer { AudioTrace.latency.duration("prefill.begin", since: start) }
            guard let conversation = self.conversation, let directory = self.captureDirectory else {
                throw GemmaError(message: "The conversation is not ready.")
            }
            let prototype = directory.appending(path: "stream-prototype.wav")
            if !FileManager.default.fileExists(atPath: prototype.path) {
                try WaveFile.encode(samples: Array(repeating: 0, count: 400)).write(to: prototype, options: .atomic)
            }
            self.residentHistory = nil
            try checked(litert_lm_conversation_begin_audio_input(conversation, try audioMessage(prototype)))
        }
    }

    func appendAudioInput(_ samples: [Float]) async throws {
        let submitted = LatencyTrace.now()
        try await perform {
            let start = LatencyTrace.now()
            AudioTrace.latency.duration("prefill.queue_wait", since: submitted)
            defer { AudioTrace.latency.duration("prefill.append", since: start) }
            guard let conversation = self.conversation else { throw GemmaError(message: "The conversation is not ready.") }
            // Match the canonical WAV path exactly, including Int16 quantization.
            let pcm = samples.map { Float(Int16((min(1, max(-1, $0)) * 32_767).rounded())) / 32_768 }
            AudioTrace.latency.duration("prefill.quantize", since: start)
            let nativeStart = LatencyTrace.now()
            defer { AudioTrace.latency.duration("prefill.native_append", since: nativeStart) }
            self.residentHistory = nil
            try pcm.withUnsafeBufferPointer {
                try checked(litert_lm_conversation_append_audio_input(conversation, $0.baseAddress, $0.count))
            }
        }
    }

    func finishAudioInput() async throws {
        try await perform {
            let start = LatencyTrace.now()
            defer { AudioTrace.latency.duration("prefill.finish", since: start) }
            guard let conversation = self.conversation else { throw GemmaError(message: "The conversation is not ready.") }
            self.residentHistory = nil
            try checked(litert_lm_conversation_finish_audio_input(conversation))
        }
    }

    func respond(audioFile: URL, messageJSON: String? = nil, traceTurn: UUID? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let stream = NativeStream(continuation: continuation, traceTurn: traceTurn)
            let admissionStart = LatencyTrace.now()
            let accepted = self.streamLock.withLock {
                guard self.activeStream == nil else { return false }
                self.activeStream = stream
                return true
            }
            if traceTurn != nil { AudioTrace.latency.duration("gemma.admission_lock", since: admissionStart) }
            guard accepted else {
                continuation.finish(throwing: GemmaError(message: "A Gemma response is already running."))
                return
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { stream.requestCancellation() }
            }
            let queuedAt = LatencyTrace.now()
            self.queue.async {
                if traceTurn != nil { AudioTrace.latency.duration("gemma.runtime_queue", since: queuedAt) }
                defer {
                    self.streamLock.withLock {
                        if self.activeStream === stream { self.activeStream = nil }
                    }
                }
                do {
                    try stream.checkCancellation()
                    guard let conversation = self.conversation else {
                        throw GemmaError(message: "The conversation is not ready.")
                    }
                    let json = try messageJSON ?? audioMessage(audioFile)
                    stream.conversation = conversation
                    let opaque = Unmanaged.passUnretained(stream).toOpaque()
                    if let traceTurn { AudioTrace.latency.mark("gemma.native_submit", turn: traceTurn) }
                    self.residentHistory = nil
                    let started = litert_lm_conversation_send_message_stream(
                        conversation, json, nil, nil, { context, chunk in
                            guard let context, let chunk else { return }
                            Unmanaged<NativeStream>.fromOpaque(context).takeUnretainedValue().receive(chunk)
                        }, opaque)
                    if let traceTurn { AudioTrace.latency.mark("gemma.native_admitted", turn: traceTurn) }
                    var startError: Error?
                    do { try checked(started) } catch { startError = error }
                    // A final callback alone is not a resource-lifetime barrier.
                    // The pinned threaded manager returns Ok or DeadlineExceeded
                    // while its engine is alive. Retain everything and retry its
                    // fixed timeout; deletion is not a substitute for draining.
                    var drained = litert_lm_conversation_wait_until_done(conversation)
                    while drained == kLiteRtLmStatusDeadlineExceeded {
                        drained = litert_lm_conversation_wait_until_done(conversation)
                    }
                    try checked(drained)
                    if let startError { throw startError }
                    try stream.result()
                    self.streamLock.withLock { self.activeStream = nil }
                    continuation.finish()
                } catch {
                    // Queued work has drained before any submitted stream gets
                    // here. Cancelled or failed handles are never reused.
                    if let conversation = self.conversation {
                        litert_lm_conversation_delete(conversation)
                        self.conversation = nil
                    }
                    self.streamLock.withLock { self.activeStream = nil }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Cancellation is issued from the next nonfinal native callback, the only
    /// overlap explicitly allowed by the pinned C API threading contract.
    func cancelResponse() {
        streamLock.withLock { activeStream?.requestCancellation() }
    }

    func beginTurn() async throws -> String? {
        try await checkpointWriter.check()
        let full = try await perform {
            guard let conversation = self.conversation, let config = self.configuration,
                  let reserve = self.maximumTurnReserve else { return false }
            var count: Int32 = 0
            try checked(litert_lm_conversation_get_token_count(conversation, &count))
            return Int(count) > config.contextTokens - reserve
        }
        // Retirement must not race a writer publishing the previous conversation.
        if full { try await checkpointWriter.flush() }
        return try await perform {
            guard let conversation = self.conversation, let config = self.configuration,
                  let reserve = self.maximumTurnReserve else {
                throw GemmaError(message: "The conversation is not ready.")
            }
            var count: Int32 = 0
            try checked(litert_lm_conversation_get_token_count(conversation, &count))
            guard count >= 0 else { throw GemmaError(message: "Gemma returned an invalid context position.") }
            if Int(count) <= config.contextTokens - reserve { return nil }
            throw GemmaError(message: "This conversation has reached the model's context capacity. Its transcript and cache have been preserved.")
        }
    }

    func history() async throws -> String {
        try await perform {
            guard let conversation = self.conversation else { throw GemmaError(message: "The conversation is not ready.") }
            var response: OpaquePointer?
            try checked(litert_lm_conversation_get_history(conversation, &response))
            defer { litert_lm_json_response_delete(response) }
            var json: UnsafePointer<CChar>?
            try checked(litert_lm_json_response_get_string(response, &json))
            guard let json else { throw CheckpointError.invalidMetadata }
            return String(cString: json)
        }
    }

    func recover() async throws -> String? {
        let flushStart = LatencyTrace.now()
        try await checkpointWriter.flush()
        AudioTrace.latency.duration("checkpoint.recovery_writer_wait", since: flushStart)
        let restored = try await perform {
            let disposeStart = LatencyTrace.now()
            if let conversation = self.conversation {
                litert_lm_conversation_delete(conversation)
                self.conversation = nil
            }
            AudioTrace.latency.duration("checkpoint.recovery_dispose", since: disposeStart)
            return try self.restoreConversation()
        }
        try await preserveRestoredPrefix(restored)
        return restored.notice
    }

    private struct Restoration: Sendable {
        let notice: String?
        let replayed: Bool
    }

    private func preserveRestoredPrefix(_ restored: Restoration) async throws {
        guard restored.replayed else { return }
        let answered = try await perform { self.residentHistory?.endsWithAssistant == true }
        guard answered else { return } // Unanswered user input stays durable in TRANSCRIPT.
        // Replayed canonical history is already committed, independent of the
        // next response's delivery. Capture it before admitting that response so
        // interruption cannot repeatedly discard and replay this same prefix.
        // save() owns an immutable snapshot; serialization remains off-thread.
        try await save()
        AudioTrace.latency.mark("checkpoint.restored_prefix_captured")
    }

    /// Returns after immutable capture and admission to the bounded writer, not
    /// after durability. Shutdown/recovery explicitly flush the writer.
    func save(turn: UUID? = nil) async throws {
        try await checkpointWriter.check()
        let start = LatencyTrace.now()
        let write: CheckpointWriter.Write? = try await perform {
            guard let conversation = self.conversation, let config = self.configuration,
                  let checkpoint = self.checkpoint else { return nil }
            var response: OpaquePointer?
            try checked(litert_lm_conversation_get_history(conversation, &response))
            defer { litert_lm_json_response_delete(response) }
            var history: UnsafePointer<CChar>?
            try checked(litert_lm_json_response_get_string(response, &history))
            guard let history else { throw GemmaError(message: "The conversation history is missing.") }
            let json = String(cString: history)
            guard try ConversationHistory(json: json).endsWithAssistant else { return nil }
            let captureStart = LatencyTrace.now()
            var handle: OpaquePointer?
            guard let captureDirectory = self.captureDirectory else {
                throw GemmaError(message: "The capture directory is unavailable.")
            }
            errno = 0
            let captureStatus = litert_lm_conversation_capture_cache_bounded(
                conversation, captureDirectory.path, self.lastCapture?.handle, &handle)
            let captureErrno = errno
            if captureStatus != kLiteRtLmStatusOk {
                // Read on the native caller thread. This is diagnostic evidence,
                // not a substitute for the runtime's original error status.
                AudioTrace.latency.mark("checkpoint.capture_failed", counts: ["posix_errno": Int(captureErrno)])
            }
            try checked(captureStatus)
            guard let handle else { throw GemmaError(message: "Missing cache snapshot.") }
            let snapshot = OwnedCacheSnapshot(handle)
            self.lastCapture = snapshot
            self.residentHistory = try ConversationHistory(json: json)
            AudioTrace.latency.duration("checkpoint.capture_pause", since: captureStart)
            let readAhead = self.checkpointReadAhead
            return {
                let writeStart = LatencyTrace.now()
                let stateURL = try checkpoint.save(configuration: config, historyJSON: json) { url, key in
                    try snapshot.write(to: url.path, key: key, previous: nil)
                }
                AudioTrace.latency.duration("checkpoint.background_durable_write", since: writeStart)
                AudioTrace.latency.mark("checkpoint.durable", turn: turn)
                AudioTrace.latency.flush("checkpoint_durable")
                readAhead.schedule(stateURL)
            }
        }
        if let write { try await checkpointWriter.submit(write) }
        // Includes history extraction, runtime queue admission, capture, and
        // writer admission: the actual interval the controller waits for.
        AudioTrace.latency.duration("checkpoint.turn_barrier", since: start)
    }

    func flushPersistence() async throws { try await checkpointWriter.retryAndFlush() }

    func close() async {
        cancelResponse()
        do { try await checkpointWriter.flush() }
        catch { AudioTrace.logger.error("Checkpoint flush failed: \(error.localizedDescription)") }
        checkpointReadAhead.cancel()
        _ = try? await perform { self.destroy() }
    }

    private func createEngine() throws {
        let start = LatencyTrace.now()
        defer { AudioTrace.latency.duration("runtime.engine_create", since: start) }
        guard let model, let config = configuration, let compiledCache else {
            throw GemmaError(message: "Runtime configuration is missing.")
        }
        var major: Int32 = 0, minor: Int32 = 0, patch: Int32 = 0
        try checked(litert_lm_get_api_version(&major, &minor, &patch))
        guard major == LITERT_LM_C_API_VERSION_MAJOR else {
            throw GemmaError(message: "The LiteRT-LM binary and headers are incompatible.")
        }
        var settings: OpaquePointer?
        try checked(litert_lm_engine_settings_create(model.modelURL.path, "gpu", nil, "cpu", &settings))
        defer { litert_lm_engine_settings_delete(settings) }
        try checked(litert_lm_engine_settings_set_max_num_tokens(settings, Int32(config.contextTokens)))
        try checked(litert_lm_engine_settings_set_audio_num_threads(settings, Int32(config.audioThreads)))
        try checked(litert_lm_engine_settings_set_enable_speculative_decoding(settings, config.enableMTP))
        try checked(litert_lm_engine_settings_set_cache_dir(settings, compiledCache.path))
        try checked(litert_lm_engine_create(settings, &engine))
    }

    /// A disposable conversation warms lazy decoding work before restoring any
    /// user state. It never enters the transcript or persistence writer.
    private func warmDecoder() throws {
        let start = LatencyTrace.now()
        defer { AudioTrace.latency.duration("runtime.warm_decoder", since: start) }
        defer {
            if let conversation { litert_lm_conversation_delete(conversation) }
            conversation = nil
        }
        try createConversation(maximumOutputTokens: 1, measureReserve: false)
        var response: OpaquePointer?
        defer { if let response { litert_lm_json_response_delete(response) } }
        try checked(litert_lm_conversation_send_message(
            conversation, #"{"role":"user","content":[{"type":"text","text":"Hello."}]}"#,
            nil, nil, &response))
    }

    private func createConversation(maximumOutputTokens: Int? = nil, measureReserve: Bool = true) throws {
        guard let engine, let config = configuration else { throw GemmaError(message: "Gemma is not loaded.") }
        var session: OpaquePointer?
        try checked(litert_lm_session_config_create(&session))
        defer { litert_lm_session_config_delete(session) }
        try checked(litert_lm_session_config_set_max_output_tokens(session, Int32(maximumOutputTokens ?? config.maximumOutputTokens)))
        // Conversation owns the model template; Session must not apply it twice.
        try checked(litert_lm_session_config_set_apply_prompt_template(session, false))
        try checked(litert_lm_session_config_set_enable_speculative_decoding(session, config.enableMTP))
        var sampler: OpaquePointer?
        try checked(litert_lm_sampler_params_create(kLiteRtLmSamplerTypeTopP, &sampler))
        defer { litert_lm_sampler_params_delete(sampler) }
        try checked(litert_lm_sampler_params_set_top_k(sampler, 64))
        try checked(litert_lm_sampler_params_set_top_p(sampler, 0.95))
        try checked(litert_lm_sampler_params_set_temperature(sampler, RuntimeConfiguration.samplingTemperature))
        try checked(litert_lm_sampler_params_set_seed(sampler, 0))
        try checked(litert_lm_session_config_set_sampler_params(session, sampler))
        var options: OpaquePointer?
        try checked(litert_lm_conversation_config_create(&options))
        defer { litert_lm_conversation_config_delete(options) }
        try checked(litert_lm_conversation_config_set_session_config(options, session))
        let promptJSON = try JSONEncoder().encode(config.systemPrompt)
        try checked(litert_lm_conversation_config_set_system_message(
            options, String(decoding: promptJSON, as: UTF8.self)))
        try checked(litert_lm_conversation_config_set_filter_channel_content_from_kv_cache(options, false))
        var thinking: OpaquePointer?
        try checked(litert_lm_thinking_config_create(&thinking))
        defer { litert_lm_thinking_config_delete(thinking) }
        try checked(litert_lm_thinking_config_set_enable_thinking(thinking, false))
        try checked(litert_lm_conversation_config_set_thinking_config(options, thinking))
        try checked(litert_lm_conversation_create(engine, options, &conversation))
        if measureReserve && maximumTurnReserve == nil { try measureTurnReserve() }
    }

    private func measureTurnReserve() throws {
        guard let conversation, let config = configuration else {
            throw GemmaError(message: "The conversation is not ready.")
        }
        let probe = FileManager.default.temporaryDirectory.appending(path: "CallGemma-budget-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: probe) }
        try WaveFile.encode(samples: Array(repeating: 0, count: 30 * 16_000)).write(to: probe, options: .atomic)
        var tokens: Int32 = 0
        try checked(litert_lm_conversation_count_tokens(conversation, try audioMessage(probe), nil, nil, &tokens))
        // Both pinned audio preprocessors derive token count from frame count,
        // not signal content. Count once with the longest permitted utterance
        // and the actual preface; no repeated FFT or inference in beginTurn().
        // 256 covers prefill_128 padding, BOS and the four-step MTP verifier.
        let reserve = Int(tokens) + config.maximumOutputTokens + 256
        guard tokens > 0, reserve < config.contextTokens else {
            throw GemmaError(message: "This context cannot fit the bounded audio input and reply. More available memory is required.")
        }
        maximumTurnReserve = reserve
    }

    private func restoreConversation() throws -> Restoration {
        residentHistory = nil
        let start = LatencyTrace.now()
        defer { AudioTrace.latency.duration("checkpoint.restore", since: start) }
        let createStart = LatencyTrace.now()
        try createConversation()
        AudioTrace.latency.duration("checkpoint.restore_create", since: createStart)
        do {
            guard let config = configuration, let checkpoint else { return Restoration(notice: nil, replayed: false) }
            let lookupStart = LatencyTrace.now()
            let files = TranscriptFiles(directory: checkpoint.directory)
            let canonical = try files.load().map { try ConversationHistory(json: $0.historyJSON) }
            let snapshot: CheckpointStore.Snapshot?
            if let canonical {
                snapshot = try checkpoint.longestPrefix(configuration: config, canonical: canonical)
            } else {
                snapshot = try checkpoint.load(configuration: config)
            }
            if snapshot == nil, canonical == nil, try checkpoint.currentRecord() != nil {
                throw GemmaError(message: "The saved conversation configuration does not match this runtime.")
            }
            AudioTrace.latency.duration("checkpoint.restore_lookup", since: lookupStart)
            let cached = try ConversationHistory(json: snapshot?.historyJSON ?? "[]")
            lastCapture = nil
            let suffix = try canonical?.suffix(after: cached) ?? "[]"
            AudioTrace.latency.mark("checkpoint.prefix_selected", counts: [
                "cached_messages": cached.messages.count,
                "canonical_messages": canonical?.messages.count ?? cached.messages.count
            ])
            if let snapshot {
                let loadStart = LatencyTrace.now()
                try checked(litert_lm_conversation_load_cache(
                    conversation, snapshot.stateURL.path, snapshot.key, snapshot.historyJSON))
                AudioTrace.latency.duration("checkpoint.restore_native_load", since: loadStart)
                AudioTrace.latency.mark("checkpoint.prefix_hit")
            } else { AudioTrace.latency.mark("checkpoint.prefix_miss") }
            if suffix != "[]" {
                let replayStart = LatencyTrace.now()
                defer { AudioTrace.latency.duration("checkpoint.restore_suffix_replay", since: replayStart) }
                AudioTrace.latency.mark("checkpoint.suffix_replay")
                typealias Replay = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> LiteRtLmStatusCode
                guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                         "litert_lm_conversation_prefill_history_suffix") else {
                    throw GemmaError(message: "This runtime cannot restore corrected spoken turns. The conversation has been preserved.")
                }
                let replay = unsafeBitCast(address, to: Replay.self)
                try suffix.withCString { try checked(replay(conversation, $0)) }
            }
            residentHistory = canonical ?? cached
            return Restoration(notice: snapshot != nil || canonical != nil ? "Conversation restored." : nil,
                               replayed: suffix != "[]")
        } catch {
            // A failed load may have touched device state. Never expose that
            // handle or silently replace the user's conversation with an empty
            // one. Keep the durable generation available for recovery.
            destroy()
            throw GemmaError(message: "Saved conversation could not be restored. Its files have been preserved. \(error.localizedDescription)")
        }
    }

    private func destroy() {
        residentHistory = nil
        lastCapture = nil
        if let conversation { litert_lm_conversation_delete(conversation) }
        conversation = nil
        if let engine { litert_lm_engine_delete(engine) }
        engine = nil
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private final class NativeStream: @unchecked Sendable {
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    var conversation: OpaquePointer? // Assigned before entering the C call.
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationIssued = false
    private var finalSeen = false
    private var firstText = true
    private let traceTurn: UUID?
    private var failure: Error?

    init(continuation: AsyncThrowingStream<String, Error>.Continuation, traceTurn: UUID?) {
        self.continuation = continuation
        self.traceTurn = traceTurn
    }

    func requestCancellation() { lock.withLock { cancelled = true } }

    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    func receive(_ chunk: OpaquePointer) {
        var final = false
        var errorText: UnsafePointer<CChar>?
        var text: UnsafePointer<CChar>?
        do {
            try checked(litert_lm_stream_chunk_is_final(chunk, &final))
            try checked(litert_lm_stream_chunk_get_error(chunk, &errorText))
            if let errorText { throw GemmaError(message: String(cString: errorText)) }
            if final {
                lock.withLock { finalSeen = true }
                return
            }
            try checkCancellation()
            try checked(litert_lm_stream_chunk_get_text(chunk, &text))
            if let text {
                let delta = try GeneratedText.decode(String(cString: text))
                if !delta.isEmpty, let traceTurn {
                    let first = lock.withLock {
                        let first = firstText
                        firstText = false
                        return first
                    }
                    if first { AudioTrace.latency.mark("gemma.native_first_text", turn: traceTurn) }
                }
                if !delta.isEmpty, case .dropped = continuation.yield(delta) {
                    throw GemmaError(message: "Speech could not keep up with Gemma's bounded response buffer.")
                }
            }
        } catch {
            lock.withLock { if failure == nil { failure = error }; cancelled = true }
        }
        let shouldCancel = lock.withLock {
            guard cancelled, !final, !cancellationIssued else { return false }
            cancellationIssued = true
            return true
        }
        if shouldCancel { litert_lm_conversation_cancel_process(conversation) }
    }

    func result() throws {
        try lock.withLock {
            if let failure { throw failure }
            if cancelled { throw CancellationError() }
            guard finalSeen else { throw GemmaError(message: "Gemma ended without a final response marker.") }
        }
    }
}

/// Immutable file-backed native snapshot. The runtime retains its latest base
/// while background writers own their snapshots; no live executor views escape.
private final class OwnedCacheSnapshot: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { litert_lm_cache_snapshot_delete(handle) }
    func write(to path: String, key: String, previous: String?) throws {
        var written = 0
        try checked(litert_lm_cache_snapshot_write(handle, path, key, previous, &written))
        AudioTrace.logger.notice("Checkpoint wrote \(written) bytes")
    }
}
