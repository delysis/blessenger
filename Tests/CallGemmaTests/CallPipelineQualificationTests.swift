import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import CallGemma

/// Recorded speech replaces mic PCM on the real capture clock. All subsequent
/// production stages, including VAD, controller, LM, TTS, playback and disk run.
/// This is deliberately NOT an acoustic mouth-to-ear measurement.
final class CallPipelineQualificationTests: XCTestCase {
    @MainActor func testRecordedCallAndRestoredConversation() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CALL_GEMMA_SPOKEN_QUALIFICATION"] else {
            throw XCTSkip("Set CALL_GEMMA_SPOKEN_QUALIFICATION for the complete call test")
        }
        var initialUsage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &initialUsage), 0)
        await AudioModelPins.configure()
        let root = URL(fileURLWithPath: folder)
        let twelve = ProcessInfo.processInfo.environment["CALL_GEMMA_PIPELINE_MODEL"] == "12B"
        let artifact = twelve ? ModelArtifact.gemma12B : ModelArtifact.gemmaE4B
        let requestedContext = Int(ProcessInfo.processInfo.environment["CALL_GEMMA_PIPELINE_CONTEXT"] ?? "4096") ?? 4096
        let context = try ModelPolicy.alignedContextCapacity(requested: requestedContext, maximum: artifact.maximumContextTokens)
        let model = PreparedModel(modelURL: root.appending(path: twelve ? "model-12b.litertlm" : "model.litertlm"),
            modelID: artifact.repository, revision: artifact.revision, contextTokens: context,
            artifactSHA256: artifact.sha256, supportsAudio: true,
            enableMTP: ProcessInfo.processInfo.environment["CALL_GEMMA_PIPELINE_MTP"] == "1",
            provenance: artifact.provenance)
        let invocation = UUID().uuidString
        let directory = ProcessInfo.processInfo.environment["CALL_GEMMA_PIPELINE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0) } ?? root.appending(path: "pipeline-" + invocation)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let compiled = ProcessInfo.processInfo.environment["CALL_GEMMA_SPOKEN_COMPILED"],
           !FileManager.default.fileExists(atPath: directory.appending(path: "Compiled").path) {
            try FileManager.default.createSymbolicLink(at: directory.appending(path: "Compiled"),
                                                       withDestinationURL: URL(fileURLWithPath: compiled))
        }
        let wav = try Data(contentsOf: root.appending(path: "question.wav"))
        let samples: [Float] = wav.dropFirst(44).withUnsafeBytes { bytes in
            (0..<bytes.count / 2).map { Float(bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) / 32_768 }
        }
        let turnCount = Int(ProcessInfo.processInfo.environment["CALL_GEMMA_PIPELINE_TURNS"] ?? "1") ?? 1
        guard (1...3).contains(turnCount) else { throw CheckpointError.invalidMetadata }
        var recording = Array(repeating: Float.zero, count: 16_000)
        var speechEnds: [Int] = []
        let audioFiles = ProcessInfo.processInfo.environment["CALL_GEMMA_PIPELINE_AUDIO_FILES"]?.split(separator: ":").map(String.init) ?? []
        for index in 0..<turnCount {
            let input: [Float]
            if audioFiles.isEmpty { input = samples }
            else {
                let data = try Data(contentsOf: URL(fileURLWithPath: audioFiles[index % audioFiles.count]))
                input = data.dropFirst(44).withUnsafeBytes { bytes in
                    (0..<bytes.count / 2).map { Float(bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) / 32_768 }
                }
            }
            let lastSignal = input.lastIndex { abs($0) >= 0.01 } ?? input.count - 1
            speechEnds.append(recording.count + lastSignal + 1)
            recording += input
            recording += Array(repeating: 0, count: 16_000 * (index + 1 == turnCount ? 1 : 12))
        }
        let audio = CallAudio(captureOverride: recording, captureSpeechEnds: speechEnds)
        let controller = CallController(audio: audio, directory: directory)
        controller.prompt = .concise
        controller.prepare(allowAvailableModel: true, suppliedModel: model)
        var deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while controller.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.ready, controller.notice ?? controller.status)
        guard controller.ready else { return }
        let conversation = GemmaRuntime.conversationDirectory(model: model, prompt: controller.systemPrompt, directory: directory)
        let prior = try TranscriptFiles(directory: conversation).load()
        let priorMessages = try prior.map { try ConversationHistory(json: $0.historyJSON).messages } ?? []
        let press = ContinuousClock.now
        controller.toggleCall()
        XCTAssertTrue(controller.inCall, "Call intent must change synchronously")
        XCTAssertTrue(controller.dialing, "Ringback must cover setup and greeting synthesis")
        XCTAssertEqual(controller.statusLabel, "Calling")
        XCTAssertLessThan(press.duration(to: .now), .milliseconds(100))
        deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while controller.busy && !controller.inCall, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.inCall, controller.notice ?? controller.status)
        deadline = ContinuousClock.now.advanced(by: .seconds(40 * turnCount))
        var canonical: TranscriptFiles.Record?
        while ContinuousClock.now < deadline {
            canonical = try TranscriptFiles(directory: conversation).load()
            if let canonical, controller.status == "Listening",
               try ConversationHistory(json: canonical.historyJSON).messages.count == priorMessages.count + 2 * (turnCount + 1) { break }
            if !controller.inCall && !controller.busy { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.notice == nil || controller.notice == "Conversation restored.",
                      controller.notice ?? "")
        var record = try XCTUnwrap(canonical, controller.notice ?? controller.status)
        let messages = try ConversationHistory(json: record.historyJSON).messages
        XCTAssertEqual(messages.count, priorMessages.count + 2 * (turnCount + 1),
                       "The greeting and each injected utterance must append one accepted turn")
        XCTAssertEqual(Array(messages.prefix(priorMessages.count)), priorMessages,
                       "Restoration must preserve the complete canonical prefix")
        if ProcessInfo.processInfo.environment["CALL_GEMMA_PIPELINE_CRASH_AFTER_CAPTURE"] == "1" {
            // Kill the isolated test host without shutdown or writer flushing.
            // Recovery runs in a separately launched test process.
            let marker: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                "history": record.historyJSON, "message_count": messages.count,
                "point": "controller returned to Listening after capture; no shutdown flush"]
            try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys, .prettyPrinted])
                .write(to: directory.appending(path: "crash-marker.json"), options: .withoutOverwriting)
            Darwin.kill(Darwin.getpid(), SIGKILL)
            XCTFail("SIGKILL unexpectedly returned")
            return
        }
        await controller.endCall()
        if ProcessInfo.processInfo.environment["CALL_GEMMA_AUDIO_QUALIFICATION"] != nil {
            await audio.settleAudio()
            let prepared = await audio.hardwareSnapshot()
            controller.toggleCall()
            deadline = ContinuousClock.now.advanced(by: .seconds(40 * turnCount))
            let expected = messages.count + 2 * (turnCount + 1)
            while ContinuousClock.now < deadline {
                if let next = try TranscriptFiles(directory: conversation).load(),
                   controller.status == "Listening",
                   try ConversationHistory(json: next.historyJSON).messages.count == expected {
                    record = next
                    break
                }
                if !controller.inCall && !controller.busy { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(try ConversationHistory(json: record.historyJSON).messages.count, expected)
            let reused = await audio.hardwareSnapshot()
            XCTAssertEqual(reused["builds"], prepared["builds"])
            await controller.endCall()
        }
        let closed = await controller.shutdown()
        XCTAssertTrue(closed)
        let restarted = CallController(directory: directory)
        restarted.prompt = .concise
        restarted.prepare(allowAvailableModel: true, suppliedModel: model)
        deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while restarted.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(restarted.ready, restarted.notice ?? restarted.status)
        XCTAssertEqual(try TranscriptFiles(directory: conversation).load()?.historyJSON, record.historyJSON)
        let reclosed = await restarted.shutdown()
        XCTAssertTrue(reclosed)
        var finalUsage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &finalUsage), 0)
        let cpuSeconds = Double(finalUsage.ru_utime.tv_sec + finalUsage.ru_stime.tv_sec
            - initialUsage.ru_utime.tv_sec - initialUsage.ru_stime.tv_sec)
            + Double(finalUsage.ru_utime.tv_usec + finalUsage.ru_stime.tv_usec
                - initialUsage.ru_utime.tv_usec - initialUsage.ru_stime.tv_usec) / 1_000_000
        let result: [String: Any] = ["directory": directory.path, "history": record.historyJSON,
                                    "model_repository": artifact.repository,
                                    "model_revision": artifact.revision,
                                    "model_sha256": artifact.sha256,
                                    "context_tokens": model.contextTokens,
                                    "mtp": model.enableMTP,
                                    "sampling": RuntimeConfiguration.samplingIdentity,
                                    "test_cpu_seconds": cpuSeconds,
                                    "process_peak_rss_bytes": finalUsage.ru_maxrss,
                                    "resource_scope": "Test host including two engine preparations and shutdown; Darwin peak RSS, not device jetsam footprint",
                                    "pid": ProcessInfo.processInfo.processIdentifier,
                                    "prior_message_count": priorMessages.count,
                                    "completed_turns": turnCount,
                                    "restored": restarted.ready, "measurement": "device-clock PCM injection; real output; not acoustic"]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appending(path: "pipeline-receipt-" + invocation + ".json"), options: .withoutOverwriting)
    }
}

final class AudioPrewarmQualificationTests: XCTestCase {
    private func resources() -> [String: Double] {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / 4)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ["cpu_ms": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000,
                "footprint_bytes": result == KERN_SUCCESS ? Double(info.phys_footprint) : -1,
                "rss_bytes": result == KERN_SUCCESS ? Double(info.resident_size) : -1]
    }
    @MainActor func testColdPrewarmedAndRepeatedStartup() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CALL_GEMMA_AUDIO_QUALIFICATION"] else {
            throw XCTSkip("Hardware audio qualification only")
        }
        var rows: [[String: Any]] = []
        var maxGap = 0.0
        let heartbeat = Task { @MainActor in
            var last = LatencyTrace.now()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = LatencyTrace.now()
                maxGap = max(maxGap, Double(now - last) / 1e6)
                last = now
            }
        }
        defer { heartbeat.cancel() }
        // Permission is intentionally outside measured startup.
        let permission = await AVCaptureDevice.requestAccess(for: .audio)
        XCTAssertTrue(permission)
        guard permission else { return }
        for mode in ["prewarmed", "cold"] {
            let audio = CallAudio(captureOverride: Array(repeating: 0, count: 16000))
            let baseline = resources()
            if mode == "prewarmed" {
                let start = LatencyTrace.now(); let before = resources()
                let peak = PeakMemoryRecorder()
                try await audio.prewarm()
                let elapsed = Double(LatencyTrace.now() - start) / 1e6
                let after = resources()
                let peakMemory = peak.stop()
                let state = await audio.hardwareSnapshot()
                XCTAssertEqual(state["running"], 0)
                XCTAssertEqual(state["callbacks"], 0)
                try await Task.sleep(for: .milliseconds(250))
                let idle = await audio.hardwareSnapshot()
                XCTAssertEqual(idle["callbacks"], 0, "Prewarming must not capture microphone samples")
                rows.append(["stage": "prewarm", "wall_ms": elapsed, "peak": peakMemory,
                             "cpu_ms": after["cpu_ms"]! - before["cpu_ms"]!, "before": before, "after": after])
            }
            for trial in 0..<3 {
                let before = resources(); let start = LatencyTrace.now()
                let peak = PeakMemoryRecorder()
                let stream = try await audio.start()
                let consumer = Task { for try await _ in stream {} }
                let returned = LatencyTrace.now()
                var state = await audio.hardwareSnapshot()
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while state["callbacks"] == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                    state = await audio.hardwareSnapshot()
                }
                XCTAssertGreaterThan(state["callbacks"] ?? 0, 0)
                XCTAssertEqual(state["builds"], 1, "Paused calls must reuse prepared resources")
                let after = resources()
                rows.append(["stage": mode, "trial": trial, "start_return_ms": Double(returned - start) / 1e6,
                    "first_capture_ms": Double((state["first_capture_ns"] ?? start) - start) / 1e6,
                    "cpu_ms": after["cpu_ms"]! - before["cpu_ms"]!, "before": before, "after": after,
                    "baseline": baseline, "peak": peak.stop(), "engine": state])
                let stopStart = LatencyTrace.now()
                audio.stop()
                let stopReturn = LatencyTrace.now()
                await audio.settleAudio()
                consumer.cancel()
                _ = await consumer.result
                let paused = await audio.hardwareSnapshot()
                XCTAssertEqual(paused["running"], 0)
                try await Task.sleep(for: .milliseconds(100))
                let quiet = await audio.hardwareSnapshot()
                XCTAssertEqual(paused["callbacks"], quiet["callbacks"], "Hang-up must stop microphone callbacks")
                rows.append(["stage": "pause", "ui_ms": Double(stopReturn - stopStart) / 1e6,
                             "resources": resources()])
            }
            await audio.shutdownAudio()
            rows.append(["stage": "released", "resources": resources()])
        }
        XCTAssertLessThan(maxGap, 100, "Audio lifecycle must not stall the UI actor")
        let receipt: [String: Any] = ["rows": rows, "main_actor_max_gap_ms": maxGap]
        let url = URL(fileURLWithPath: folder).appending(path: "audio-prewarm-" + UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}

extension CallPipelineQualificationTests {
    @MainActor func testRepeatedCallsDeliverPlaybackAfterGraphReuse() async throws {
        guard ProcessInfo.processInfo.environment["CALL_GEMMA_AUDIO_QUALIFICATION"] != nil else {
            throw XCTSkip("Opt-in physical audio graph qualification")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw XCTSkip("Microphone permission unavailable") }
        let audio = CallAudio(captureOverride: [])
        do {
            for trial in 0..<3 {
                let stream = try await audio.start()
                let consumer = Task { for try await _ in stream {} }
                let segment = UUID()
                audio.beginPlaybackResponse(UUID())
                try audio.beginPlaybackSegment(segment, text: "Playback after graph reuse")
                try await audio.play([Float](repeating: 0, count: 1920), firstFrameOfSentence: true, segment: segment)
                try audio.finishPlaybackSegment(segment)
                let playback = Task { @MainActor in try await audio.drainPlayback() }
                let deadline = Task { @MainActor in
                    try await Task.sleep(for: .seconds(3))
                    playback.cancel()
                }
                do { try await playback.value; deadline.cancel() }
                catch {
                    deadline.cancel()
                    throw CallAudioError.unavailable("Playback did not drain after graph reuse, trial \(trial): \(error)")
                }
                XCTAssertEqual(audio.playbackPosition(), 1920, "Capture alone does not establish playback health")
                audio.stop()
                await audio.settleAudio()
                consumer.cancel()
                _ = await consumer.result
            }
        } catch { await audio.shutdownAudio(); throw error }
        await audio.shutdownAudio()
    }
}
