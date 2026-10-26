import XCTest
import Combine
@testable import CallGemma

final class RelationshipMemoryTests: XCTestCase {
    func testSharedCallHandoffPreservesAttributionWithoutRecursiveReplay() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID(), call = UUID()
        let af = TranscriptFiles(directory: root.appending(path: "a"))
        let bf = TranscriptFiles(directory: root.appending(path: "b"))
        let old = try ConversationHistory(json: "[]").appending(userJSON: #"{"role":"user","content":[{"type":"text","text":"Private earlier call"}]}"#, heardText: "Private reply")
        try af.commit(history: old, turn: nil)
        var shared = try SharedCallHistory(call: call, participants: [
            CallMemoryParticipant(contact: a, name: "Peter Levine", transcriptDirectory: af.directory),
            CallMemoryParticipant(contact: b, name: "Gabor Maté", transcriptDirectory: bf.directory)])
        let audio = #"{"role":"user","content":[{"type":"audio","path":"/owned/current-call.wav"}]}"#
        let ah = try old.appending(userJSON: audio, heardText: "A actually heard")
        try af.commit(history: ah, turn: UUID())
        try shared.handoff(from: a, to: b)
        let imported = try ConversationHistory(json: XCTUnwrap(bf.load()).historyJSON)
        XCTAssertEqual(imported.messages.count, 1)
        XCTAssertFalse(imported.endsWithAssistant)
        XCTAssertTrue(imported.json.contains(a.uuidString))
        XCTAssertTrue(imported.json.contains("Peter Levine"))
        XCTAssertTrue(imported.json.contains("Gabor Maté"))
        let context = try shared.context(for: b)
        XCTAssertTrue((context.first?["text"] as? String)?.contains("Gabor Maté") == true)
        XCTAssertTrue(imported.json.contains("A actually heard"))
        XCTAssertFalse(imported.json.contains("Private"))
        let bs = CallMemorySource(id: UUID(), contact: b, transcriptDirectory: bf.directory, firstMessage: 0)
        XCTAssertTrue(try RelationshipMemory.turns(source: bs, history: imported).isEmpty)
        let bh = try imported.appending(userJSON: audio, heardText: "B actually heard")
        try bf.commit(history: bh, turn: UUID())
        try shared.handoff(from: b, to: a)
        let returned = try ConversationHistory(json: XCTUnwrap(af.load()).historyJSON)
        XCTAssertEqual(returned.messages.count, ah.messages.count + 1)
        let last = String(decoding: try XCTUnwrap(returned.messages.last), as: UTF8.self)
        XCTAssertTrue(last.contains("B actually heard"))
        XCTAssertFalse(last.contains("A actually heard"))
        try shared.handoff(from: a, to: b)
        XCTAssertEqual(try ConversationHistory(json: XCTUnwrap(bf.load()).historyJSON), bh)
    }

    @MainActor
    func testMicrophoneTelemetryDoesNotInvalidateMessagingScreen() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CallController(directory: directory)
        var screenUpdates = 0
        var diagnosticUpdates = 0
        let screen = controller.objectWillChange.sink { screenUpdates += 1 }
        let diagnostics = controller.callDiagnostics.objectWillChange.sink { diagnosticUpdates += 1 }
        for index in 0..<100 { controller.callDiagnostics.text = "Frame \(index)" }
        XCTAssertEqual(diagnosticUpdates, 100)
        XCTAssertEqual(screenUpdates, 0, "Audio telemetry must not relayout the messaging screen")
        withExtendedLifetime((screen, diagnostics)) {}
    }

    func testCallRosterFreezesIdentitiesAndRejectsAmbiguousMembership() throws {
        var a = Persona(name: "Same", prompt: "Original", voice: "voice-a")
        let b = Persona(name: "Same", prompt: "Other", voice: "voice-b")
        let roster = try CallRoster(participants: [a, b], initialSpeaker: b.id)
        a.prompt = "Changed"; a.voice = "changed"
        XCTAssertEqual(roster.initialContact.id, b.id)
        XCTAssertEqual(roster.participants[0].prompt, "Original")
        XCTAssertEqual(roster.participants[0].voice, "voice-a")
        XCTAssertThrowsError(try CallRoster(participants: [], initialSpeaker: b.id))
        XCTAssertThrowsError(try CallRoster(participants: [a, a], initialSpeaker: a.id))
        XCTAssertThrowsError(try CallRoster(participants: [a, b], initialSpeaker: UUID()))
    }

    func testGroupCallMemoryIsAtomicIsolatedAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "store.sqlite")
        let store = MessageStore(url: database)
        let a = Persona(name: "Same", prompt: "A"), b = Persona(name: "Same", prompt: "B")
        try await store.save(a); try await store.save(b)
        let af = TranscriptFiles(directory: root.appending(path: "a"))
        let bf = TranscriptFiles(directory: root.appending(path: "b"))
        let id = UUID()
        try await store.registerCall(id: id, participants: [
            CallMemoryParticipant(contact: a.id, transcriptDirectory: root.appending(path: "a")),
            CallMemoryParticipant(contact: b.id, transcriptDirectory: root.appending(path: "b"))])
        let audio = #"{"role":"user","content":[{"type":"audio","path":"/owned/question.wav"}]}"#
        let ah = try ConversationHistory(json: "[]").appending(userJSON: audio, heardText: "A heard")
        let bh = try ConversationHistory(json: "[]").appending(userJSON: audio, heardText: "B heard")
        try af.commit(history: ah, turn: UUID()); try bf.commit(history: bh, turn: UUID())
        try await store.finishCall(id: id)
        try await store.close()
        let reopened = MessageStore(url: database)
        let sessionValue = try await reopened.callSession(id: id)
        let session = try XCTUnwrap(sessionValue)
        XCTAssertTrue(session.ended)
        XCTAssertEqual(Set(session.sources).count, 2)
        // Later durable turns cannot enter a finished call's range.
        try af.commit(history: ah.appending(userJSON: audio, heardText: "Later call"), turn: UUID())
        try await reopened.finishCall(id: id)
        let am = try await reopened.recentCallMemory(contact: a.id)
        let bm = try await reopened.recentCallMemory(contact: b.id)
        XCTAssertEqual(am.map(\.heardText), ["A heard"])
        XCTAssertEqual(bm.map(\.heardText), ["B heard"])
        XCTAssertTrue(am.allSatisfy { session.sources.contains($0.call) })
        XCTAssertTrue(bm.allSatisfy { session.sources.contains($0.call) })
        let snapshot = try await reopened.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        try await reopened.close()
    }

    func testRejectedGroupDoesNotCloseOrPublishAnyParticipant() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MessageStore(url: root.appending(path: "store.sqlite"))
        let a = Persona(name: "A", prompt: "A")
        try await store.save(a)
        let folder = root.appending(path: "a"), first = UUID(), rejected = UUID()
        try await store.registerCall(id: first, contact: a.id, transcriptDirectory: folder)
        do {
            try await store.registerCall(id: rejected, participants: [
                CallMemoryParticipant(contact: a.id, transcriptDirectory: folder),
                CallMemoryParticipant(contact: UUID(), transcriptDirectory: root.appending(path: "missing"))])
            XCTFail("Missing participant must reject the whole registration")
        } catch {}
        let rejectedSession = try await store.callSession(id: rejected)
        XCTAssertNil(rejectedSession)
        let audio = #"{"role":"user","content":[{"type":"audio","path":"/owned/question.wav"}]}"#
        let history = try ConversationHistory(json: "[]").appending(userJSON: audio, heardText: "Still first call")
        try TranscriptFiles(directory: folder).commit(history: history, turn: UUID())
        let memory = try await store.recentCallMemory(contact: a.id)
        XCTAssertEqual(memory.map(\.call), [first])
        XCTAssertEqual(memory.map(\.heardText), ["Still first call"])
        try await store.close()
    }

    func testLateTeardownCannotExtendAnInterruptedCallIntoTheNextCall() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MessageStore(url: root.appending(path: "store.sqlite"))
        let a = Persona(name: "A", prompt: "A")
        try await store.save(a)
        let folder = root.appending(path: "a"), first = UUID(), second = UUID()
        let files = TranscriptFiles(directory: folder)
        let audio = #"{"role":"user","content":[{"type":"audio","path":"/owned/question.wav"}]}"#
        try await store.registerCall(id: first, contact: a.id, transcriptDirectory: folder)
        let h = try ConversationHistory(json: "[]").appending(userJSON: audio, heardText: "First")
        try files.commit(history: h, turn: UUID())
        try await store.registerCall(id: second, contact: a.id, transcriptDirectory: folder)
        try files.commit(history: h.appending(userJSON: audio, heardText: "Second"), turn: UUID())
        try await store.finishCall(id: first)
        let memory = try await store.recentCallMemory(contact: a.id)
        XCTAssertEqual(memory.map(\.call), [first, second])
        XCTAssertEqual(memory.map(\.heardText), ["First", "Second"])
        try await store.close()
    }

    @MainActor
    func testRealContactCallFeedsChatMemory() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let destination = env["BLESSENGER_CALL_MEMORY_DIRECTORY"],
              let input = env["BLESSENGER_VOICE_NOTE_INPUT"],
              let modelPath = env["BLESSENGER_QUALIFICATION_MODEL"] else {
            throw XCTSkip("Opt-in full contact call and chat qualification")
        }
        await AudioModelPins.configure()
        let root = URL(fileURLWithPath: destination)
        let wav = try Data(contentsOf: URL(fileURLWithPath: input))
        let samples: [Float] = wav.dropFirst(44).withUnsafeBytes { bytes in
            (0..<bytes.count / 2).map { Float(bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) / 32_768 }
        }
        let audio = CallAudio(captureOverride: Array(repeating: 0, count: 16_000) + samples + Array(repeating: 0, count: 32_000))
        let directory = root.appending(path: "Runtime")
        let controller = CallController(audio: audio, directory: directory)
        let shipping = env["BLESSENGER_SHIPPING_REPRO"] == "1"
        let artifact = shipping ? ModelArtifact.gemma12B : ModelArtifact.gemmaE4B
        let prepared = PreparedModel(modelURL: URL(fileURLWithPath: modelPath), modelID: artifact.repository,
            revision: artifact.revision, contextTokens: shipping ? 32768 : 4096, artifactSHA256: artifact.sha256,
            supportsAudio: true, enableMTP: artifact.enableMTP, provenance: artifact.provenance)
        controller.prepare(allowAvailableModel: true, suppliedModel: prepared)
        var deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while controller.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard controller.ready else { XCTFail(controller.notice ?? controller.status); _ = await controller.shutdown(); return }
        let model = MessagingModel(directory: root.appending(path: "Messages"))
        let bundledURL = try XCTUnwrap(BlessengerResources.bundle.url(forResource: "contacts", withExtension: "json"))
        let bundled = try JSONDecoder().decode([Persona].self, from: Data(contentsOf: bundledURL))
        let person = shipping ? try XCTUnwrap(bundled.first { $0.voice == "gabor_mate" }) : Persona(name: "Ada", prompt: "Answer briefly in one short sentence without mentions.", voice: "francine_shapiro")
        let group = env["BLESSENGER_GROUP_HANDOFF"] == "1"
        let initial = shipping ? try XCTUnwrap(bundled.first { $0.voice == "bessel_van_der_kolk" }) : Persona(name: "Grace", prompt: "Answer briefly in one short sentence without mentions.", voice: "bessel_van_der_kolk")
        let thread = ChatThread(title: "Ada", participants: group ? [initial.id, person.id] : [person.id])
        try await model.store.save(person)
        if group { try await model.store.save(initial) }
        try await model.store.save(thread)
        let chatToCall = env["BLESSENGER_CHAT_TO_CALL"] == "1"
        if chatToCall {
            let admitted = await model.send("Remember that my favorite color is chartreuse.", threadID: thread.id,
                mentions: [], attachments: [], controller: controller)
            XCTAssertTrue(admitted)
            XCTAssertNil(model.error)
        }
        if shipping {
            let admitted = await model.send("@\(initial.name), please reply with one short greeting.", threadID: thread.id,
                mentions: [ChatMention(kind: .contact, id: initial.id, label: initial.name)], attachments: [], controller: controller)
            XCTAssertTrue(admitted)
            XCTAssertNil(model.error)
        }
        let start = ContinuousClock.now
        if group {
            controller.dial(participants: [initial, person], initialSpeaker: initial.id, memoryStore: model.store)
            XCTAssertFalse(controller.requestCallParticipant(UUID()), "Unknown identities must not enter the call")
            XCTAssertTrue(controller.requestCallParticipant(person.id))
        } else { controller.dial(contact: person, memoryStore: model.store) }
        XCTAssertTrue(controller.inCall)
        XCTAssertTrue(controller.dialing)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        deadline = ContinuousClock.now.advanced(by: .seconds(120))
        var turns: [CallMemoryTurn] = []
        while ContinuousClock.now < deadline {
            turns = try await model.store.recentCallMemory(contact: person.id)
            if !turns.isEmpty && controller.status == "Listening" { break }
            if !controller.inCall && !controller.busy { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if group {
            XCTAssertEqual(controller.activeCallParticipant, person.id)
            let outgoing = try await model.store.recentCallMemory(contact: initial.id)
            XCTAssertTrue(outgoing.isEmpty, "The outgoing persona must not inherit the next participant's user turn")
            let graph = await audio.hardwareSnapshot()
            XCTAssertEqual(graph["builds"], 1, "Participant handoff must retain the audio graph")
        }
        await controller.endCall()
        let heard = try await model.store.recentCallMemory(contact: person.id)
        guard let callTurn = heard.last else {
            XCTFail(controller.notice ?? "No committed call utterance")
            _ = await controller.shutdown(); return
        }
        XCTAssertFalse(callTurn.heardText.isEmpty)
        if chatToCall {
            XCTAssertTrue(callTurn.heardText.localizedCaseInsensitiveContains("chartreuse"), callTurn.heardText)
        }
        let before = try await model.store.snapshot()
        XCTAssertEqual(before.messages.count, (chatToCall || shipping) ? 2 : 0, "Calls must not create chat bubbles")
        let accepted = await model.send(group ? "@\(person.name), what did I ask during our phone call?" : "What did I ask during our phone call?", threadID: thread.id,
            mentions: group ? [ChatMention(kind: .contact, id: person.id, label: person.name)] : [],
            attachments: [], controller: controller)
        XCTAssertTrue(accepted)
        XCTAssertNil(model.error)
        let after = try await model.store.snapshot()
        XCTAssertEqual(after.messages.count, (chatToCall || shipping) ? 4 : 2)
        let answer = try XCTUnwrap(after.messages.last)
        XCTAssertEqual(answer.sender, person.id)
        XCTAssertTrue(answer.requestJSON?.contains(callTurn.call.uuidString) == true)
        let requestData = try XCTUnwrap(answer.requestJSON?.data(using: .utf8))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let parts = try XCTUnwrap(request["content"] as? [[String: Any]])
        XCTAssertTrue(parts.contains { ($0["text"] as? String) == "[Your actually heard reply in that call:] " + callTurn.heardText },
                      "The decoded consultation must preserve the exact heard reply, including quotes and newlines")
        XCTAssertFalse(answer.text.isEmpty)
        let stopped = await audio.hardwareSnapshot()
        XCTAssertEqual(stopped["running"], 0)
        let shutdown = await controller.shutdown()
        XCTAssertTrue(shutdown)
        let receipt = ["call": callTurn.call.uuidString, "heard": callTurn.heardText,
            "chat_reply": answer.text, "request": answer.requestJSON ?? ""]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "call-memory-receipt.json"))
        try await model.store.close()
    }

    func testUnansweredSpeechDoesNotInventOrMisattributeReplies() throws {
        let contact = UUID()
        let source = CallMemorySource(id: UUID(), contact: contact,
            transcriptDirectory: URL(fileURLWithPath: "/unused"), firstMessage: 0)
        let history = try ConversationHistory(json: #"[{"role":"user","content":[{"type":"audio","path":"/first.wav"}]},{"role":"user","content":[{"type":"audio","path":"/second.wav"}]},{"role":"assistant","content":[{"type":"text","text":"Heard reply"}]},{"role":"user","content":[{"type":"audio","path":"/third.wav"}]}]"#)
        let turns = try RelationshipMemory.turns(source: source, history: history)
        XCTAssertEqual(turns.map(\.messageIndex), [0, 1, 3])
        XCTAssertEqual(turns.map(\.heardText), ["", "Heard reply", ""])
        let content = try RelationshipMemory.content(turns, contact: contact)
        XCTAssertEqual(content.filter { ($0["text"] as? String)?.hasPrefix("[Your actually heard reply") == true }.count, 1)
    }

    func testGreetingWithQuotedAudioIsJournaledButNotReexportedAsUserSpeech() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = HeardTurnJournal(directory: root)
        let context = #"[{"type":"text","text":"Earlier chat source 123"},{"type":"audio","path":"/owned/chat.wav"}]"#
        let greeting = try await journal.stageGreeting(contextJSON: context)
        let json = try XCTUnwrap(greeting.messageJSON)
        XCTAssertTrue(json.contains("Earlier chat source 123"))
        var history = try ConversationHistory(json: "[]")
        history = try history.appending(userJSON: json, heardText: "Hello.")
        let contact = UUID()
        let source = CallMemorySource(id: UUID(), contact: contact, transcriptDirectory: root, firstMessage: 0)
        XCTAssertTrue(try RelationshipMemory.turns(source: source, history: history).isEmpty)
        try await journal.admit(greeting)
        try await journal.commit(heardText: "Hello.")
        let restored = try XCTUnwrap(TranscriptFiles(directory: root).load())
        XCTAssertEqual(try ConversationHistory(json: restored.historyJSON), history)
    }

    func testCallCanEndAndRestartAfterUnansweredSpeech() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "messages.sqlite")
        let store = MessageStore(url: database)
        let persona = Persona(name: "Ada", prompt: "A")
        try await store.save(persona)
        let files = TranscriptFiles(directory: root.appending(path: "calls"))
        let first = UUID(), second = UUID()
        try await store.registerCall(id: first, contact: persona.id, transcriptDirectory: files.directory)
        var history = try ConversationHistory(json: "[]")
        history = try history.appending(userJSON: #"{"role":"user","content":[{"type":"audio","path":"/owned/unanswered.wav"}]}"#, heardText: "")
        try files.commit(history: history, turn: UUID())
        try await store.finishCall(id: first)
        try await store.registerCall(id: second, contact: persona.id, transcriptDirectory: files.directory)
        history = try history.appending(userJSON: #"{"role":"user","content":[{"type":"audio","path":"/owned/next-call.wav"}]}"#, heardText: "Next call reply")
        try files.commit(history: history, turn: UUID())
        try await store.finishCall(id: second)
        try await store.close()
        let reopened = MessageStore(url: database)
        let turns = try await reopened.recentCallMemory(contact: persona.id)
        XCTAssertEqual(turns.map(\.call), [first, second])
        XCTAssertEqual(turns.map(\.messageIndex), [0, 1])
        XCTAssertEqual(turns.map(\.heardText), ["", "Next call reply"])
        try await reopened.close()
    }

    func testCallBoundariesHeardTextProvenanceAndContactIsolationSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "messages.sqlite")
        let store = MessageStore(url: database)
        let ada = Persona(name: "Ada", prompt: "A")
        let grace = Persona(name: "Grace", prompt: "B")
        try await store.save(ada); try await store.save(grace)
        let folder = root.appending(path: "calls")
        let files = TranscriptFiles(directory: folder)
        let first = UUID(), second = UUID()
        try await store.registerCall(id: first, contact: ada.id, transcriptDirectory: folder)
        var history = try ConversationHistory(json: "[]")
        history = try history.appending(userJSON: #"{"role":"user","content":[{"type":"text","text":"greet"}]}"#, heardText: "Hello")
        history = try history.appending(userJSON: #"{"role":"user","content":[{"type":"audio","path":"/owned/question.wav"}]}"#, heardText: "Only heard words")
        try files.commit(history: history, turn: UUID())
        try await store.finishCall(id: first)
        try await store.registerCall(id: second, contact: ada.id, transcriptDirectory: folder)
        history = try history.appending(userJSON: #"{"role":"user","content":[{"type":"audio","path":"/owned/second.wav"}]}"#, heardText: "Second heard answer")
        try files.commit(history: history, turn: UUID())
        // A crash before finishCall must still expose only committed heard turns.
        try Data("unheard continuation".utf8).write(to: folder.appending(path: "uncommitted-generation"))
        try await store.close()
        let reopened = MessageStore(url: database)
        let turns = try await reopened.recentCallMemory(contact: ada.id)
        XCTAssertEqual(turns.map(\.call), [first, second])
        XCTAssertEqual(turns.map(\.messageIndex), [2, 4])
        XCTAssertEqual(turns.map(\.heardText), ["Only heard words", "Second heard answer"])
        let other = try await reopened.recentCallMemory(contact: grace.id)
        XCTAssertTrue(other.isEmpty)
        let input = #"{"role":"user","content":[{"type":"text","text":"New question"}]}"#
        let request = try await reopened.requestIncludingCallMemory(input, contact: ada.id)
        XCTAssertTrue(request.contains(first.uuidString))
        XCTAssertTrue(request.contains(second.uuidString))
        XCTAssertFalse(request.contains("unheard continuation"))
        XCTAssertFalse(request.contains("Hello"))
        XCTAssertTrue(request.contains("New question"))
        let untouched = try await reopened.requestIncludingCallMemory(input, contact: grace.id)
        XCTAssertEqual(untouched, input)
        let snapshot = try await reopened.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty, "Call memory must not create chat bubbles")
        try await reopened.close()
    }
}
