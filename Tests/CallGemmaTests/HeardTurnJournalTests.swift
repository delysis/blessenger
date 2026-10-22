import Foundation
import XCTest
@testable import CallGemma

final class HeardTurnJournalTests: XCTestCase {
    @MainActor func testConfirmedInputSurvivesCancellationBeforeReplyPlayback() async throws {
        for confirmBeforeAdmission in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = HeardTurnJournal(directory: directory)
            let gate = SpeculativeEndpoint(id: UUID())
            if confirmBeforeAdmission {
                try await gate.confirm()
                gate.revoke() // Cancellation can precede journal staging too.
            }
            let turn = try await journal.stage(samples: [0, 0.1, -0.1])
            try await journal.admit(turn, speculative: true)
            try await gate.bindInputAdmission { try await journal.confirm(turn: turn.id) }
            if !confirmBeforeAdmission { try await gate.confirm() }
            // No reply PCM was played. Revoke output, then recover exactly as
            // barge-in/relaunch does; the accepted audio must still be present.
            gate.revoke()
            let reopened = HeardTurnJournal(directory: directory)
            _ = try await reopened.loadPending()
            try await reopened.discardSpeculation()
            let pending = try await reopened.loadPending()
            XCTAssertEqual(pending?.speculative, false)
            try await reopened.commit(heardText: "")
            let history = try XCTUnwrap(TranscriptFiles(directory: directory).load())
            XCTAssertTrue(history.historyJSON.contains(turn.audioURL.lastPathComponent))
            XCTAssertEqual(try ConversationHistory(json: history.historyJSON).messages.count, 1)
            XCTAssertFalse(history.historyJSON.contains("assistant"))
        }
    }

    func testRejectsOlderPendingFormatsAndMissingAdmissionFlag() async throws {
        for mutation in 0..<3 {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = HeardTurnJournal(directory: directory)
            let turn = try await journal.begin(samples: [0, 0.1, -0.1])
            let voice = try await journal.voice(prompt: nil, tokens: 0, cpuOnly: false)
            try await journal.beginSegment(turn: turn.id, id: UUID(), text: "Hello", seed: 1, voice: voice)
            try await journal.flush()
            let url = directory.appending(path: "PENDING-SPEECH")
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            if mutation == 0 { record["version"] = 1 }
            if mutation == 1 { record.removeValue(forKey: "speculative") }
            if mutation == 2 {
                var segments = try XCTUnwrap(record["segments"] as? [[String: Any]])
                segments[0]["leadingSilencePolicy"] = 1
                record["segments"] = segments
            }
            try JSONSerialization.data(withJSONObject: record).write(to: url)
            do {
                _ = try await HeardTurnJournal(directory: directory).loadPending()
                XCTFail("An obsolete journal must not be interpreted as the current format")
            } catch { }
        }
    }

    func testPickupEventSurvivesCancellationBeforeAnySpeech() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        let turn = try await journal.stageGreeting()
        try await journal.admit(turn)
        let pending = try await HeardTurnJournal(directory: directory).loadPending()
        XCTAssertTrue(pending?.userJSON.contains("Call event") == true)
        try await journal.commit(heardText: "")
        let history = try XCTUnwrap(TranscriptFiles(directory: directory).load())
        XCTAssertTrue(history.historyJSON.contains("Call event"))
        XCTAssertFalse(history.historyJSON.contains("audio"))
    }

    @MainActor func testDialAndHangupChangeIntentBeforeAsyncWork() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CallController(directory: directory)
        controller.toggleCall()
        XCTAssertTrue(controller.inCall)
        XCTAssertTrue(controller.dialing)
        XCTAssertEqual(controller.statusLabel, "Calling")
        controller.toggleCall()
        XCTAssertFalse(controller.inCall)
        XCTAssertFalse(controller.dialing)
        // Rapid redial must queue behind teardown without resurrecting an old call.
        controller.toggleCall()
        XCTAssertTrue(controller.inCall)
        controller.toggleCall()
        XCTAssertFalse(controller.inCall)
        let closed = await controller.shutdown()
        XCTAssertTrue(closed)
    }

    func testRestartRetainsOnlyConfirmedProgressAndText() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        let turn = try await journal.begin(samples: [0, 0.1, -0.1])
        let segment = UUID()
        let voice = try await journal.voice(prompt: nil, tokens: 0, cpuOnly: false)
        try await journal.beginSegment(turn: turn.id, id: segment, text: "Hello there.", seed: 42, voice: voice)
        try await journal.generated(turn: turn.id, segment: segment, samples: [0.1, 0.2, 0.3, 0.4])
        try await journal.played(turn: turn.id, through: 2, stop: true)
        try await journal.played(turn: turn.id, through: 4) // A late callback cannot change the cut.
        try await journal.flush()
        let restored = HeardTurnJournal(directory: directory)
        let pending = try await restored.loadPending()
        XCTAssertEqual(pending?.segments.first?.playedFrames, 2)
        XCTAssertEqual(pending?.segments.first?.generatedFrames, 4)
        XCTAssertEqual(pending?.segments.first?.seed, 42)
        XCTAssertTrue(FileManager.default.fileExists(atPath: turn.audioURL.path))
        try await restored.commit(heardText: "Hello")
        let history = try XCTUnwrap(TranscriptFiles(directory: directory).load())
        XCTAssertEqual(history.lastTurn, turn.id)
        XCTAssertTrue(history.historyJSON.contains("Hello"))
        XCTAssertFalse(history.historyJSON.contains("there"))
        let reopened = HeardTurnJournal(directory: directory)
        let recovered = try await reopened.loadPending()
        XCTAssertNil(recovered)
    }

    func testCrashAfterTranscriptPublicationDoesNotDuplicateTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        let turn = try await journal.begin(samples: [0])
        let record = try await journal.loadPending()
        let pending = try XCTUnwrap(record)
        let history = try ConversationHistory(json: "[]").appending(userJSON: pending.userJSON, heardText: "")
        // Exactly the durable state between TRANSCRIPT rename and pending unlink.
        try TranscriptFiles(directory: directory).commit(history: history, turn: turn.id)
        let restarted = HeardTurnJournal(directory: directory)
        let recovered = try await restarted.loadPending()
        XCTAssertNil(recovered)
        XCTAssertEqual(try TranscriptFiles(directory: directory).load()?.historyJSON, history.json)
    }

    func testUnheardNativeTailCannotBePublished() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        _ = try await journal.begin(samples: [0])
        let record = try await journal.loadPending()
        let pending = try XCTUnwrap(record)
        let native = try ConversationHistory(json: "[]").appending(userJSON: pending.userJSON,
                                                                   heardText: "Unheard tail.")
        do {
            try await journal.commit(heardText: "", nativeHistory: native.json)
            XCTFail("Published text without playback evidence")
        } catch {}
        XCTAssertNil(try TranscriptFiles(directory: directory).load())
        let saved = try await journal.loadPending()
        XCTAssertNotNil(saved)
    }

    func testGeneratedHashIsIncrementalAndVoiceConditioningSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        let turn = try await journal.begin(samples: [0])
        let prompt = [Float](repeating: 0.125, count: 1_024)
        let voice = try await journal.voice(prompt: prompt, tokens: 1, cpuOnly: true)
        let segment = UUID()
        try await journal.beginSegment(turn: turn.id, id: segment, text: "Hello.", seed: 7, voice: voice)
        let samples: [Float] = [0.1, 0.2, 0.3]
        try await journal.generated(turn: turn.id, segment: segment, samples: Array(samples.prefix(1)))
        try await journal.generated(turn: turn.id, segment: segment, samples: Array(samples.dropFirst()), complete: true)
        try await journal.flush()
        let restarted = HeardTurnJournal(directory: directory)
        let pending = try await restarted.loadPending()
        XCTAssertEqual(pending?.segments.first?.generatedSHA256, samples.withUnsafeBytes { digest(Data($0)) })
        let restoredPrompt = try await restarted.voicePrompt(voice)
        XCTAssertEqual(restoredPrompt, prompt)
    }
}

extension HeardTurnJournalTests {
    func testSpeculativeInputIsNotAConversationUntilAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        let input = try await journal.stage(samples: [0.1, 0.2])
        let reopened = HeardTurnJournal(directory: directory)
        let pending = try await reopened.loadPending()
        XCTAssertNil(pending)
        XCTAssertNil(try TranscriptFiles(directory: directory).load())
        try await journal.admit(input)
        let admitted = try await journal.loadPending()
        XCTAssertEqual(admitted?.id, input.id)
        XCTAssertEqual(admitted?.userJSON, try audioMessage(input.audioURL))
    }

    func testUnconfirmedSynthesisIsDiscardedAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        let input = try await journal.stage(samples: [0.1, 0.2])
        try await journal.admit(input, speculative: true)
        let voice = try await journal.voice(prompt: nil, tokens: 0, cpuOnly: false)
        let segment = UUID()
        try await journal.beginSegment(turn: input.id, id: segment, text: "Unheard", seed: 42, voice: voice)
        try await journal.generated(turn: input.id, segment: segment, samples: [0.1], complete: true)
        try await journal.flush()
        let restored = try await HeardTurnJournal(directory: directory).loadPending()
        XCTAssertNil(restored)
        XCTAssertNil(try TranscriptFiles(directory: directory).load())
    }

    func testConfirmedSpeculationSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        let input = try await journal.stage(samples: [0.1, 0.2])
        try await journal.admit(input, speculative: true)
        try await journal.confirm(turn: input.id)
        let restored = HeardTurnJournal(directory: directory)
        let pending = try await restored.loadPending()
        XCTAssertEqual(pending?.id, input.id)
        XCTAssertEqual(pending?.speculative, false)
        try await restored.commit(heardText: "")
        XCTAssertNotNil(try TranscriptFiles(directory: directory).load())
    }

    func testCancelledSpeculationDoesNotBecomeAUserTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        let input = try await journal.stage(samples: [0.1, 0.2])
        try await journal.admit(input, speculative: true)
        try await journal.discardSpeculation()
        let pending = try await journal.loadPending()
        XCTAssertNil(pending)
        XCTAssertNil(try TranscriptFiles(directory: directory).load())
    }

    func testSavedWordBoundariesRecoverTextWithoutSynthesis() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = HeardTurnJournal(directory: directory)
        let input = try await journal.begin(samples: [0])
        let segment = UUID()
        let voice = try await journal.voice(prompt: nil, tokens: 0, cpuOnly: false)
        try await journal.beginSegment(turn: input.id, id: segment, text: "Hello there.", seed: 42, voice: voice)
        try await journal.generated(turn: input.id, segment: segment, samples: Array(repeating: 0.1, count: 100), complete: true)
        try await journal.aligned(turn: input.id, segment: segment, words: [
            .init(endUTF8: 5, endFrame: 25), .init(endUTF8: 11, endFrame: 80)])
        try await journal.played(turn: input.id, through: 50, stop: true)
        try await journal.flush()
        let reopened = HeardTurnJournal(directory: directory)
        let recovery = SpokenTextRecovery()
        let heard = try await recovery.text(journal: reopened, modelDirectory: directory) { _, _ in
            XCTFail("Recovery regenerated audio despite durable word boundaries")
            throw CheckpointError.invalidMetadata
        }
        XCTAssertEqual(heard, "Hello")
        try await reopened.commit(heardText: heard)
        let record = try XCTUnwrap(TranscriptFiles(directory: directory).load())
        XCTAssertFalse(record.historyJSON.contains("there"))
    }
}
