import AVFoundation
import XCTest
@testable import CallGemma

final class VoiceNoteTests: XCTestCase {
    @MainActor
    func testCancelledPrewarmDoesNotConstructOrStartHardware() async throws {
        let audio = CallAudio()
        let request = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await audio.prewarm()
                return false
            } catch is CancellationError { return true }
            catch { XCTFail("Unexpected prewarm failure: \(error)"); return false }
        }
        let cancelled = await request.value
        XCTAssertTrue(cancelled)
        let state = await audio.hardwareSnapshot()
        XCTAssertEqual(state["builds"], 0)
        XCTAssertEqual(state["running"], 0)
        XCTAssertEqual(state["callbacks"], 0)
    }

    @MainActor
    func testRapidPlaybackResetDoesNotDeliverPreviousResponse() async throws {
        let audio = CallAudio()
        try await audio.startNotePlayback()
        do {
            let pcm = [Float](repeating: 0, count: 1920)
            for _ in 0..<12 {
                let response = UUID(), segment = UUID()
                audio.beginPlaybackResponse(response)
                try audio.beginPlaybackSegment(segment, text: "Discarded continuation.")
                for _ in 0..<8 { try await audio.play(pcm, segment: segment) }
                let start = ContinuousClock.now
                audio.interruptPlayback()
                XCTAssertLessThan(start.duration(to: .now), .milliseconds(50))
                let stopped = try XCTUnwrap(audio.interruptedPlayback)
                XCTAssertEqual(stopped.response, response)
                XCTAssertLessThan(stopped.deliveredFrames, stopped.scheduledFrames)

                let next = UUID(), nextSegment = UUID()
                audio.beginPlaybackResponse(next)
                try audio.beginPlaybackSegment(nextSegment, text: "Next reply.")
                try await audio.play(pcm, segment: nextSegment)
                try audio.finishPlaybackSegment(nextSegment)
                try await audio.drainPlayback()
                XCTAssertEqual(audio.playbackPosition(), 1920)
                audio.interruptPlayback()
                let receipt = try XCTUnwrap(audio.interruptedPlayback)
                XCTAssertEqual(receipt.response, next)
                XCTAssertEqual(receipt.completedText, ["Next reply."])
                XCTAssertEqual(receipt.scheduledFrames, 1920)
            }
            // Teardown must also wait for a pending reset before graph reuse.
            audio.beginPlaybackResponse(UUID())
            try await audio.play(pcm)
            audio.stop()
            try await audio.startNotePlayback()
            audio.beginPlaybackResponse(UUID())
            try await audio.play(pcm)
            try await audio.drainPlayback()
        } catch {
            await audio.shutdownAudio()
            throw error
        }
        await audio.shutdownAudio()
    }

    @MainActor
    func testAudioRequestAndTextOnlyReplySurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MessagingModel(directory: directory)
        let person = Persona(name: "Ada", prompt: "Answer briefly")
        let thread = ChatThread(title: "Ada", participants: [person.id])
        try await model.store.save(person)
        try await model.store.save(thread)
        let source = MessageAttachment(id: UUID(), name: "Recording.wav", kind: .audio, file: "qualification.wav")
        let inference = VoiceNoteInference()
        let admitted = await model.send("", threadID: thread.id, mentions: [], attachments: [source], controller: inference)
        XCTAssertTrue(admitted)
        let failed = try await model.store.snapshot()
        XCTAssertEqual(failed.messages.count, 1)
        XCTAssertEqual(failed.messages[0].attachments, [source])
        XCTAssertEqual(failed.messages[0].text, "")
        XCTAssertTrue(try failed.messages[0].inputJSON().contains("qualification.wav"))
        try await model.store.close()
        let restored = MessagingModel(directory: directory)
        inference.failReply = false
        await restored.retry(thread: thread.id, controller: inference)
        XCTAssertNil(restored.error)
        let complete = try await restored.store.snapshot()
        XCTAssertEqual(complete.messages.count, 2)
        XCTAssertEqual(complete.messages[1].text, "Marigold remembered.")
        XCTAssertEqual(complete.messages[1].voiceNote, true)
        XCTAssertTrue(complete.messages[1].attachments.isEmpty, "Generated voice notes store text, not pre-rendered audio")
        XCTAssertEqual(complete.attempts[0].status, .completed)
        await restored.resumePending(controller: inference)
        XCTAssertEqual(inference.requests, 2)
        try await restored.store.close()
    }

    @MainActor
    func testRecordedPlaybackPauseSeekAndCancelWithoutMicrophone() async throws {
        let recording = VoiceNoteRecording()
        for _ in 0..<100 { try await recording.append(Array(repeating: Float(0), count: 1600)) }
        let source = try await recording.finish()
        let file = try await AttachmentLibrary().importFile(source)
        defer { try? FileManager.default.removeItem(at: file.url) }
        await recording.cancel()
        let audio = CallAudio()
        let controller = CallController(audio: audio)
        let message = ChatMessage(thread: UUID(), text: "", attachments: [file], voiceNote: true)
        controller.toggleVoiceNote(message)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.voiceNotePosition == 0, controller.playingVoiceNote != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.voiceNoteDuration, 10, accuracy: 0.01)
        XCTAssertGreaterThan(controller.voiceNotePosition, 0)
        controller.toggleVoiceNote(message)
        XCTAssertTrue(controller.voiceNotePaused)
        controller.seekVoiceNote(to: 0.7)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.voiceNotePosition, 7, accuracy: 0.1)
        controller.toggleVoiceNote(message)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(controller.voiceNotePosition, 7)
        let stopped = ContinuousClock.now
        await controller.stopVoiceNotePlayback()
        XCTAssertLessThan(stopped.duration(to: .now), .milliseconds(230))
        XCTAssertNil(controller.playingVoiceNote)
        let hardware = await audio.hardwareSnapshot()
        XCTAssertEqual(hardware["running"], 0)
        XCTAssertEqual(hardware["callbacks"], 0)
        await audio.shutdownAudio()
    }
    func testMessageDeletionAndRecoverySurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "messages.sqlite")
        let store = MessageStore(url: url)
        let person = Persona(name: "Test", prompt: "Test")
        let thread = ChatThread(title: "Original", participants: [person.id])
        try await store.save(person); try await store.save(thread)
        let message = ChatMessage(thread: thread.id, text: "Recover me")
        try await store.append(message)
        try await store.setMessageDeleted(message.id, deleted: true)
        try await store.close()
        let restored = MessageStore(url: url)
        let hidden = try await restored.snapshot()
        XCTAssertTrue(hidden.messages.isEmpty)
        try await restored.restoreMessages(in: thread.id)
        let recovered = try await restored.snapshot()
        XCTAssertEqual(recovered.messages, [message])
        var renamed = thread; renamed.title = "Renamed"; renamed.deleted = true
        try await restored.save(renamed); try await restored.close()
        let reopened = MessageStore(url: url)
        let state = try await reopened.snapshot()
        XCTAssertEqual(state.threads.first?.title, "Renamed")
        XCTAssertEqual(state.threads.first?.deleted, true)
        try await reopened.close()
    }

    func testRecordingPreservesSharedCaptureRateAndFrames() async throws {
        let recording = VoiceNoteRecording()
        let frame = (0..<256).map { Float($0) / 512 }
        for _ in 0..<10 { try await recording.append(frame) }
        let elapsed = await recording.elapsed()
        XCTAssertEqual(elapsed, 0.16, accuracy: 0.00001)
        let url = try await recording.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.length, 2560)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2560))
        try file.read(into: buffer)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 256)), frame)
        await recording.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
private final class VoiceNoteInference: MessageInference {
    var acceptsTextWork = true
    var failReply = true
    var requests = 0
    func replyToMessage(_ json: String, contact: Persona, thread: UUID, history: ConversationHistory) async throws -> String {
        requests += 1
        XCTAssertTrue(json.contains("qualification.wav"))
        if failReply { throw GemmaError(message: "Injected reply failure") }
        return "Marigold remembered."
    }
    func persistTextReply(history: ConversationHistory) async throws {}
    func abandonTextReply() {}
}
