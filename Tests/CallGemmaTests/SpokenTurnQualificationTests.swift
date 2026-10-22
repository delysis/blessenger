import Foundation
import XCTest
@testable import CallGemma

/// Opt-in: uses the real LM, speech models, microphone engine and speakers.
/// Playback callbacks are software evidence, not an acoustic latency measurement.
final class SpokenTurnQualificationTests: XCTestCase {
    @MainActor func testSpeculativeSynthesisCannotPlayBeforeConfirmation() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CALL_GEMMA_SPOKEN_QUALIFICATION"] else {
            throw XCTSkip("Set CALL_GEMMA_SPOKEN_QUALIFICATION for the device playback gate test")
        }
        await AudioModelPins.configure()
        let directory = URL(fileURLWithPath: folder).appending(path: "speculative-" + UUID().uuidString)
        let journal = HeardTurnJournal(directory: directory)
        let input = try await journal.stage(samples: [0.1, 0.2])
        try await journal.admit(input, speculative: true)
        let audio = CallAudio()
        let speech = SpeechOutput(audio: audio, cacheDirectory: URL(fileURLWithPath: folder))
        try await speech.prepare()
        try await audio.prepare()
        let events = try await audio.start()
        let pump = Task { for try await _ in events {} }
        let gate = SpeculativeEndpoint(id: UUID())
        try await speech.beginResponse(journal: journal, turn: input.id, playbackAdmission: {
            try await gate.wait()
            try Task.checkCancellation()
            try await journal.confirm(turn: input.id)
        })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(audio.playbackPosition(), 0, "No speech may play before generated text arrives")
        let beforeText = try await journal.loadPending()
        XCTAssertTrue(beforeText?.segments.isEmpty == true, "Turn admission must not manufacture speech")
        try await speech.append("This speculative sentence must never be heard. ")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var generated = 0
        while generated == 0, ContinuousClock.now < deadline {
            generated = try await journal.loadPending()?.segments.reduce(0) { $0 + $1.generatedFrames } ?? 0
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(generated, 0, "TTS must run before the playback gate opens")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(audio.playbackPosition(), 0, "Speculative audio escaped the endpoint gate")
        let start = LatencyTrace.now()
        gate.revoke()
        await speech.cancel()
        try await speech.freezeHeardProgress()
        try await journal.discardSpeculation()
        XCTAssertEqual(audio.playbackPosition(), 0)
        let restored = try await HeardTurnJournal(directory: directory).loadPending()
        XCTAssertNil(restored)
        XCTAssertNil(try TranscriptFiles(directory: directory).load())
        print("SPECULATIVE_TTS_REVOKED_MS \(Double(LatencyTrace.now() - start) / 1e6)")
        audio.stop()
        await audio.settleAudio()
        pump.cancel()
        _ = try? await pump.value
    }

    @MainActor func testInterruptedTurnAndRestart() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CALL_GEMMA_SPOKEN_QUALIFICATION"] else {
            throw XCTSkip("Set CALL_GEMMA_SPOKEN_QUALIFICATION for the audible integration test")
        }
        await AudioModelPins.configure()
        let root = URL(fileURLWithPath: folder)
        let twelve = ProcessInfo.processInfo.environment["CALL_GEMMA_SPOKEN_MODEL"] == "12B"
        let artifact = twelve ? ModelArtifact.gemma12B : ModelArtifact.gemmaE4B
        let model = PreparedModel(modelURL: root.appending(path: twelve ? "model-12b.litertlm" : "model.litertlm"),
            modelID: artifact.repository, revision: artifact.revision, contextTokens: 4_096,
            artifactSHA256: artifact.sha256, supportsAudio: true, enableMTP: twelve,
            provenance: artifact.provenance)
        let prompt = "Answer in two complete sentences of natural spoken English."
        let directory = root.appending(path: "spoken-" + UUID().uuidString)
        if let compiled = ProcessInfo.processInfo.environment["CALL_GEMMA_SPOKEN_COMPILED"] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: directory.appending(path: "Compiled"),
                                                       withDestinationURL: URL(fileURLWithPath: compiled))
        }
        let journalDirectory = GemmaRuntime.conversationDirectory(model: model, prompt: prompt, directory: directory)
        let runtime = GemmaRuntime()
        let audio = CallAudio()
        let speech = SpeechOutput(audio: audio, cacheDirectory: root)
        try await speech.prepare()
        if ProcessInfo.processInfo.environment["CALL_GEMMA_SPOKEN_CLONE"] == "1" {
            try await speech.setVoice(referenceAudio: root.appending(path: "question.wav"))
        }
        try await audio.prepare()
        _ = try await runtime.prepare(model: model, systemPrompt: prompt, directory: directory,
                                      runtimeSHA256: RuntimeIdentity.load())
        let journal = HeardTurnJournal(directory: journalDirectory)
        // Use the exact production WAV quantization, preserving the user audio.
        let wav = try Data(contentsOf: root.appending(path: "question.wav"))
        let samples: [Float] = wav.dropFirst(44).withUnsafeBytes { bytes in
            (0..<bytes.count / 2).map { Float(bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) / 32_768 }
        }
        let turn = try await journal.begin(samples: samples)
        let events = try await audio.start()
        let pump = Task { for try await _ in events {} }
        let response = Task {
            try await speech.beginResponse(journal: journal, turn: turn.id)
            for try await delta in runtime.respond(audioFile: turn.audioURL) { try await speech.append(delta) }
            try await speech.finishResponse()
        }
        let requestedCut = Int(ProcessInfo.processInfo.environment["CALL_GEMMA_SPOKEN_CUT_FRAMES"] ?? "12000") ?? 12_000
        guard (1...240_000).contains(requestedCut) else { throw CheckpointError.invalidMetadata }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while audio.playbackPosition() < requestedCut, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cut = audio.playbackPosition()
        XCTAssertGreaterThan(cut, 0, "No reply reached playback")
        let beforeRecoveryMemory = PeakMemoryRecorder().stop()
        let recoveryMemory = PeakMemoryRecorder()
        try FileHandle.standardError.write(contentsOf: Data("SPOKEN_CANCEL_REQUEST pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        let stopStart = LatencyTrace.now()
        audio.interruptPlayback()
        let directlyStopped = LatencyTrace.now()
        response.cancel()
        let taskCancelled = LatencyTrace.now()
        runtime.cancelResponse()
        let nativeCancelled = LatencyTrace.now()
        await speech.cancel()
        let speechStopped = LatencyTrace.now()
        let cancellationStages = await speech.lastCancellationTimings
        _ = try? await response.value
        let modelJoined = LatencyTrace.now()
        try await speech.freezeHeardProgress()
        let progressFlushed = LatencyTrace.now()
        let stopMS = Double(progressFlushed - stopStart) / 1e6
        audio.stop()
        pump.cancel()
        _ = try? await pump.value
        let pendingValue = try await journal.loadPending()
        let pending = try XCTUnwrap(pendingValue)
        try JSONEncoder().encode(pending).write(to: directory.appending(path: "pending-at-cut.json"),
                                               options: .withoutOverwriting)
        XCTAssertTrue(pending.segments.contains { $0.playedFrames > 0 && (!$0.complete || $0.playedFrames < $0.generatedFrames) })
        for segment in pending.segments where segment.playedFrames > 0 &&
            (!segment.complete || segment.playedFrames < segment.generatedFrames) {
            XCTAssertNotNil(segment.alignment, "Live cancellation must preserve its alignment reference without regeneration.")
            let voice = try await journal.voicePrompt(segment.voice)
            let regenerated = try await speech.renderReference(segment, prompt: voice)
            let regeneratedHash = regenerated.prefix(segment.generatedFrames).withUnsafeBytes { digest(Data($0)) }
            XCTAssertEqual(regeneratedHash, segment.generatedSHA256,
                           "Restart regeneration must reproduce the same silence-trimmed PCM")
        }
        // A newly constructed journal reopens only durable files. No in-memory
        // receipt or previous TTS session is available to the recovery path.
        let reopened = HeardTurnJournal(directory: journalDirectory)
        let recoveryStart = LatencyTrace.now()
        let recovery = SpokenTextRecovery()
        let text = try await recovery.text(journal: reopened, modelDirectory: AudioModelPins.alignerDirectory) {
            segment, prompt in try await speech.renderReference(segment, prompt: prompt)
        }
        try await reopened.commit(heardText: text)
        let recoveryMS = Double(LatencyTrace.now() - recoveryStart) / 1e6
        let peakRecoveryMemory = recoveryMemory.stop()
        await runtime.close()
        let canonical = try XCTUnwrap(TranscriptFiles(directory: journalDirectory).load())
        let restarted = GemmaRuntime()
        _ = try await restarted.prepare(model: model, systemPrompt: prompt, directory: directory,
                                        runtimeSHA256: RuntimeIdentity.load())
        let replayed = try await restarted.history()
        XCTAssertEqual(try ConversationHistory(json: replayed), try ConversationHistory(json: canonical.historyJSON))
        var reply = ""
        for try await delta in restarted.respond(audioFile: root.appending(path: "question.wav")) { reply += delta }
        XCTAssertFalse(reply.isEmpty)
        await restarted.close()
        let receipt: [String: Any] = ["directory": directory.path, "requested_cut_frames": requestedCut, "confirmed_frames_at_cut": cut,
            "cancel_and_durable_progress_ms": stopMS, "text_recovery_ms": recoveryMS,
            "speech_cancel_ms": Double(speechStopped - stopStart) / 1e6,
            "direct_audio_stop_ms": Double(directlyStopped - stopStart) / 1e6,
            "response_task_cancel_ms": Double(taskCancelled - directlyStopped) / 1e6,
            "native_cancel_request_ms": Double(nativeCancelled - taskCancelled) / 1e6,
            "speech_cancel_call_ms": Double(speechStopped - nativeCancelled) / 1e6,
            "native_response_join_ms": Double(modelJoined - speechStopped) / 1e6,
            "progress_flush_ms": Double(progressFlushed - modelJoined) / 1e6,
            "cancellation_stages": cancellationStages,
            "heard_text": text, "following_reply": reply, "restored_history_equal": true,
            "before_recovery_memory": beforeRecoveryMemory, "recovery_memory": peakRecoveryMemory]
        print("SPOKEN_PENDING_FRAMES \(pending.segments.map { $0.playedFrames })")
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appending(path: "spoken-receipt.json"), options: .withoutOverwriting)
        print("SPOKEN_RECOVERY \(String(decoding: try JSONSerialization.data(withJSONObject: receipt), as: UTF8.self))")
    }
}
