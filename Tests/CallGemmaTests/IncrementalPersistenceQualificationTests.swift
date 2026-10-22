import Foundation
import XCTest
@testable import CallGemma

/// Opt-in real-model qualification. Ordinary test runs skip this; the supplied
/// directory must contain model.litertlm, question.wav, and runtime-id.txt.
final class IncrementalPersistenceQualificationTests: XCTestCase {
    /// Uses the real 12B runtime; a public-history match must not retain an
    /// unfinished audio prefill or an uncommitted generated response.
    func testResidentConversationRequiresCanonicalCompletedState() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CALL_GEMMA_RESIDENT_QUALIFICATION"] else {
            throw XCTSkip("Set CALL_GEMMA_RESIDENT_QUALIFICATION for real 12B qualification")
        }
        let root = URL(fileURLWithPath: folder)
        let artifact = ModelArtifact.gemma12B
        let model = PreparedModel(modelURL: root.appending(path: "model-12b.litertlm"),
            modelID: artifact.repository, revision: artifact.revision, contextTokens: 8192,
            artifactSHA256: artifact.sha256, supportsAudio: true, enableMTP: true,
            provenance: artifact.provenance)
        let runtime = GemmaRuntime()
        let directory = root.appending(path: "resident-" + UUID().uuidString)
        let prompt = "Answer briefly."
        let identity = try RuntimeIdentity.load()
        let files = TranscriptFiles(directory: GemmaRuntime.conversationDirectory(
            model: model, prompt: prompt, directory: directory))
        do {
            _ = try await runtime.prepare(model: model, systemPrompt: prompt,
                directory: directory, runtimeSHA256: identity)
            for try await _ in runtime.respond(audioFile: root,
                messageJSON: #"{"role":"user","content":[{"type":"text","text":"Say hello."}]}"#) {}
            let canonical = try ConversationHistory(json: await runtime.history())
            try files.commit(history: canonical, turn: nil)
            try await runtime.save()
            try await runtime.flushPersistence()
            for _ in 0..<2 {
                _ = try await runtime.prepare(model: model, systemPrompt: prompt,
                    directory: directory, runtimeSHA256: identity)
                let actual = try ConversationHistory(json: await runtime.history())
                XCTAssertEqual(actual, canonical)
            }
            try await runtime.beginAudioInput()
            try await runtime.appendAudioInput(Array(repeating: 0, count: 1600))
            _ = try await runtime.prepare(model: model, systemPrompt: prompt,
                directory: directory, runtimeSHA256: identity)
            let afterInput = try ConversationHistory(json: await runtime.history())
            XCTAssertEqual(afterInput, canonical)
            // A completed but uncommitted reply must also be discarded.
            for try await _ in runtime.respond(audioFile: root,
                messageJSON: #"{"role":"user","content":[{"type":"text","text":"Say goodbye."}]}"#) {}
            _ = try await runtime.prepare(model: model, systemPrompt: prompt,
                directory: directory, runtimeSHA256: identity)
            let afterGeneration = try ConversationHistory(json: await runtime.history())
            XCTAssertEqual(afterGeneration, canonical)
            // Editing canonical history invalidates even a restored snapshot.
            let empty = try ConversationHistory(json: "[]")
            try files.commit(history: empty, turn: nil)
            _ = try await runtime.prepare(model: model, systemPrompt: prompt,
                directory: directory, runtimeSHA256: identity)
            let afterEdit = try ConversationHistory(json: await runtime.history())
            XCTAssertEqual(afterEdit, empty)
            await runtime.close()
        } catch {
            await runtime.close()
            throw error
        }
    }

    func testUnansweredUserSurvivesNativeRecoveryAndRestart() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CALL_GEMMA_RESIDENT_QUALIFICATION"] else {
            throw XCTSkip("Set CALL_GEMMA_RESIDENT_QUALIFICATION for real 12B qualification")
        }
        let root = URL(fileURLWithPath: folder)
        let artifact = ModelArtifact.gemma12B
        let model = PreparedModel(modelURL: root.appending(path: "model-12b.litertlm"),
            modelID: artifact.repository, revision: artifact.revision, contextTokens: 8192,
            artifactSHA256: artifact.sha256, supportsAudio: true, enableMTP: true,
            provenance: artifact.provenance)
        let directory = root.appending(path: "unanswered-" + UUID().uuidString)
        let prompt = "Answer briefly."
        let identity = try RuntimeIdentity.load()
        let files = TranscriptFiles(directory: GemmaRuntime.conversationDirectory(
            model: model, prompt: prompt, directory: directory))
        let pending = try ConversationHistory(json: #"[{"role":"user","content":[{"type":"text","text":"Remember the word marigold."}]}]"#)
        try files.commit(history: pending, turn: UUID())
        let runtime = GemmaRuntime()
        do {
            _ = try await runtime.prepare(model: model, systemPrompt: prompt,
                directory: directory, runtimeSHA256: identity)
            let restored = try ConversationHistory(json: await runtime.history())
            XCTAssertEqual(restored, pending)
            try await runtime.beginAudioInput()
            try await runtime.appendAudioInput(Array(repeating: 0, count: 1600))
            _ = try await runtime.recover()
            let recovered = try ConversationHistory(json: await runtime.history())
            XCTAssertEqual(recovered, pending)
            for try await _ in runtime.respond(audioFile: root,
                messageJSON: #"{"role":"user","content":[{"type":"text","text":"What word did I ask you to remember?"}]}"#) {}
            let answered = try ConversationHistory(json: await runtime.history())
            XCTAssertEqual(answered.messages.count, 3)
            XCTAssertEqual(answered.messages.first, pending.messages.first)
            XCTAssertTrue(answered.endsWithAssistant)
            try files.commit(history: answered, turn: UUID())
            try await runtime.save()
            try await runtime.flushPersistence()
            await runtime.close()
            _ = try await runtime.prepare(model: model, systemPrompt: prompt,
                directory: directory, runtimeSHA256: identity)
            let reopened = try ConversationHistory(json: await runtime.history())
            XCTAssertEqual(reopened, answered)
            await runtime.close()
        } catch {
            await runtime.close()
            throw error
        }
    }

    @MainActor func testVoiceImportWithRealEncoder() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CALL_GEMMA_CACHE_QUALIFICATION"] else {
            throw XCTSkip("Set CALL_GEMMA_CACHE_QUALIFICATION for real-model qualification")
        }
        let root = URL(fileURLWithPath: folder)
        let speech = SpeechOutput(audio: CallAudio(), cacheDirectory: root)
        let start = DispatchTime.now().uptimeNanoseconds
        try await speech.setVoice(referenceAudio: root.appending(path: "question.wav"))
        print("VOICE real_encoder_import_ms=\(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)")
        let firstCount = await speech.voiceCloneCount
        XCTAssertGreaterThan(firstCount, 0)
        try await speech.setVoice(referenceAudio: root.appending(path: "question.wav"))
        let repeatCount = await speech.voiceCloneCount
        XCTAssertEqual(repeatCount, firstCount, "Unchanged audio must not run the encoder again")
        try await speech.setVoice(referenceAudio: nil)
        try await speech.setVoice(referenceAudio: root.appending(path: "question.wav"))
        let restoredCount = await speech.voiceCloneCount
        XCTAssertEqual(restoredCount, firstCount, "Switching voices must retain conditioning")
        // A different file URL containing the same decoded PCM is the same voice.
        let copy = root.appending(path: "voice-copy-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: root.appending(path: "question.wav"), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        try await speech.setVoice(referenceAudio: copy)
        let copiedCount = await speech.voiceCloneCount
        XCTAssertEqual(copiedCount, firstCount)
        // Replacing the content at that URL must not reuse the previous prompt.
        let other = root.appending(path: "france.wav")
        try FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: other, to: copy)
        try await speech.setVoice(referenceAudio: copy)
        let changedCount = await speech.voiceCloneCount
        XCTAssertEqual(changedCount, firstCount + 1)
        try await speech.setVoice(referenceAudio: root.appending(path: "question.wav"))
        let finalCount = await speech.voiceCloneCount
        XCTAssertEqual(finalCount, changedCount, "Changing one voice must not evict another")
    }

    func testActualRuntimeBarrierAndGracefulRestart() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CALL_GEMMA_CACHE_QUALIFICATION"] else {
            throw XCTSkip("Set CALL_GEMMA_CACHE_QUALIFICATION for real-model qualification")
        }
        let root = URL(fileURLWithPath: folder)
        let artifact = ModelArtifact.gemmaE4B
        let model = PreparedModel(modelURL: root.appending(path: "model.litertlm"),
            modelID: artifact.repository, revision: artifact.revision, contextTokens: 32_000,
            artifactSHA256: artifact.sha256, supportsAudio: true, enableMTP: false,
            provenance: artifact.provenance)
        let runtimeID = try String(contentsOf: root.appending(path: "runtime-id.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let runtime = GemmaRuntime()
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        _ = try await runtime.prepare(model: model, systemPrompt: "Answer briefly.", directory: directory,
                                      runtimeSHA256: runtimeID)
        let memory = PeakMemoryRecorder()
        var pauses: [Double] = []
        for _ in 0..<4 {
            _ = try await runtime.beginTurn()
            var text = ""
            for try await delta in runtime.respond(audioFile: root.appending(path: "question.wav")) {
                text += delta
            }
            XCTAssertFalse(text.isEmpty)
            let start = DispatchTime.now().uptimeNanoseconds
            try await runtime.save()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            pauses.append(ms)
            XCTAssertLessThan(ms, 1_000, "Actual save admission blocked the next turn for a second")
        }
        try await runtime.flushPersistence()
        let peakMemory = memory.stop()
        let switchStart = DispatchTime.now().uptimeNanoseconds
        _ = try await runtime.prepare(model: model, systemPrompt: "Answer in one sentence.", directory: directory,
                                      runtimeSHA256: runtimeID)
        let switchMS = Double(DispatchTime.now().uptimeNanoseconds - switchStart) / 1_000_000
        let restoreStart = DispatchTime.now().uptimeNanoseconds
        let restored = try await runtime.prepare(model: model, systemPrompt: "Answer briefly.", directory: directory,
                                                runtimeSHA256: runtimeID)
        let restoreMS = Double(DispatchTime.now().uptimeNanoseconds - restoreStart) / 1_000_000
        XCTAssertEqual(restored, "Conversation restored.")
        print("PROMPT switch_ms=\(switchMS) restored_switch_ms=\(restoreMS)")
        await runtime.close() // Must flush the latest admitted snapshot.
        let restarted = GemmaRuntime()
        let notice = try await restarted.prepare(model: model, systemPrompt: "Answer briefly.", directory: directory,
                                                runtimeSHA256: runtimeID)
        XCTAssertEqual(notice, "Conversation restored.")
        await restarted.close()
        let data = try JSONSerialization.data(withJSONObject: ["actual_turn_barrier_ms": pauses, "peak_memory": peakMemory,
            "prompt_switch_ms": switchMS, "prompt_restore_switch_ms": restoreMS,
            "context_capacity": 32_000, "graceful_restart": "passed"], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appending(path: "app-barrier.json"), options: .atomic)
    }
}
