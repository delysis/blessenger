import AVFoundation
import XCTest
@testable import CallGemma

final class VoiceNoteQualificationTests: XCTestCase {
    @MainActor
    func testSharedMicrophoneRecordingAndPreparedResourceReuse() async throws {
        guard ProcessInfo.processInfo.environment["BLESSENGER_RECORDING_QUALIFY"] == "1" else {
            throw XCTSkip("Opt-in real microphone recording")
        }
        let audio = CallAudio()
        let controller = CallController(audio: audio)
        try await audio.prewarm()
        let prepared = await audio.hardwareSnapshot()
        XCTAssertEqual(prepared["running"], 0)
        XCTAssertEqual(prepared["callbacks"], 0)
        XCTAssertEqual(prepared["input_resources"], 0, "Prewarming must release idle voice I/O")
        XCTAssertEqual(prepared["output_resources"], 0, "Prewarming must not retain system ducking")
        XCTAssertEqual(prepared["voice_processing"], 0, "An enabled but stopped voice unit still ducks other apps")
        for _ in 0..<2 {
            try await controller.startVoiceNoteRecording()
            let active = await audio.hardwareSnapshot()
            XCTAssertEqual(active["voice_processing"], 1, "Capture must retain echo cancellation")
            try await Task.sleep(for: .seconds(1))
            let file = try await controller.finishVoiceNoteRecording()
            let recording = try AVAudioFile(forReading: file)
            XCTAssertEqual(recording.fileFormat.sampleRate, 16_000)
            XCTAssertGreaterThan(recording.length, 8_000)
            XCTAssertLessThan(recording.length, 32_000)
            await audio.settleAudio()
            let stopped = await audio.hardwareSnapshot()
            XCTAssertEqual(stopped["running"], 0)
            XCTAssertEqual(stopped["input_resources"], 0)
            XCTAssertEqual(stopped["output_resources"], 0)
            XCTAssertEqual(stopped["voice_processing"], 0)
            XCTAssertGreaterThan(stopped["callbacks"] ?? 0, 0)
            XCTAssertEqual(stopped["builds"], prepared["builds"], "Recording must retain the prepared call engine")
            try FileManager.default.removeItem(at: file)
        }
        await audio.shutdownAudio()
    }

    @MainActor
    func testRealAudioReplyAndOnDemandPlayback() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["BLESSENGER_VOICE_NOTE_DIRECTORY"],
              let source = env["BLESSENGER_VOICE_NOTE_INPUT"],
              let modelPath = env["BLESSENGER_QUALIFICATION_MODEL"] else {
            throw XCTSkip("Opt-in complete voice-note pipeline")
        }
        let root = URL(fileURLWithPath: directory)
        let artifact = ModelArtifact.gemmaE4B
        let prepared = PreparedModel(modelURL: URL(fileURLWithPath: modelPath), modelID: artifact.repository,
            revision: artifact.revision, contextTokens: 4096, artifactSHA256: artifact.sha256,
            supportsAudio: true, enableMTP: false, provenance: artifact.provenance)
        let audioEngine = CallAudio()
        let controller = CallController(audio: audioEngine, directory: root.appending(path: "Runtime"))
        controller.prepare(allowAvailableModel: true, suppliedModel: prepared)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while controller.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard controller.ready else {
            XCTFail(controller.notice ?? controller.status)
            _ = await controller.shutdown()
            return
        }
        let model = MessagingModel(directory: root.appending(path: "Messages"))
        let person = Persona(name: "Ada", prompt: "Answer the user in one short sentence without any mentions.", voice: "francine_shapiro")
        let thread = ChatThread(title: "Voice", participants: [person.id])
        try await model.store.save(person)
        try await model.store.save(thread)
        // Route the known fixture through the actual recording writer so this
        // qualifies its WAV format as Gemma input, not only an imported WAV.
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: source))
        XCTAssertEqual(input.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 256))
        let recording = VoiceNoteRecording()
        while input.framePosition < input.length {
            try input.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            try await recording.append(samples)
        }
        let recorded = try await recording.finish()
        let audio = try await AttachmentLibrary().importFile(recorded)
        await recording.cancel()
        let admitted = await model.send("", threadID: thread.id, mentions: [], attachments: [audio], controller: controller)
        XCTAssertTrue(admitted)
        XCTAssertNil(model.error)
        let state = try await model.store.snapshot()
        XCTAssertEqual(state.messages.count, 2)
        XCTAssertNil(state.messages.first?.attachments.first?.extractedText)
        XCTAssertEqual(state.messages.first?.text, "")
        let answer = try XCTUnwrap(state.messages.last)
        XCTAssertTrue(answer.text.lowercased().contains("four") || answer.text.contains("4"), answer.text)
        XCTAssertEqual(answer.voiceNote, true)
        XCTAssertTrue(answer.attachments.isEmpty)
        let priorNotice = controller.notice
        controller.toggleVoiceNote(answer, contact: person)
        XCTAssertEqual(controller.playingVoiceNote, answer.id)
        let playbackDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while controller.playingVoiceNote != nil, ContinuousClock.now < playbackDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(controller.playingVoiceNote)
        XCTAssertEqual(controller.notice, priorNotice)
        let microphone = await audioEngine.hardwareSnapshot()
        XCTAssertEqual(microphone["running"], 0)
        XCTAssertEqual(microphone["callbacks"], 0, "Playing a reply must not start microphone capture")
        var longPlayback = answer
        longPlayback.text = Array(repeating: "This is a longer voice note for testing cancellation while speech is playing.", count: 12).joined(separator: " ")
        controller.toggleVoiceNote(longPlayback, contact: person)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(controller.playingVoiceNote, answer.id)
        XCTAssertGreaterThan(controller.voiceNoteDuration, 0)
        controller.toggleVoiceNote(longPlayback, contact: person)
        XCTAssertTrue(controller.voiceNotePaused)
        controller.seekVoiceNote(to: 0.25)
        let seek = controller.voiceNotePosition
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.voiceNotePosition, seek, accuracy: 0.1)
        controller.toggleVoiceNote(longPlayback, contact: person)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThanOrEqual(controller.voiceNotePosition, seek)
        let stopped = ContinuousClock.now
        await controller.stopVoiceNotePlayback()
        let pause = stopped.duration(to: .now)
        XCTAssertLessThan(pause, .milliseconds(230), "Playback cancellation must not finish rendering the unheard remainder")
        XCTAssertNil(controller.playingVoiceNote)
        let afterPlayback = try await model.store.snapshot()
        XCTAssertEqual(afterPlayback.messages, state.messages, "Playback and stopping playback cannot alter model history")
        try Data(String(describing: pause).utf8).write(to: root.appending(path: "playback-stop-\(UUID().uuidString).txt"), options: .atomic)
        let receipt = root.appending(path: "voice-note-\(UUID().uuidString).json")
        try JSONEncoder().encode(state.messages).write(to: receipt, options: .atomic)
        let saved = await controller.shutdown()
        XCTAssertTrue(saved)
        try await model.store.close()
        let reopened = MessageStore(url: root.appending(path: "Messages/messages.sqlite"))
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored.messages, state.messages)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path))
        try await reopened.close()
    }
}
