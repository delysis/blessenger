import Foundation
import XCTest
@testable import CallGemma

/// Real packaged-host inference, queue, canonical transcript and KV persistence.
/// Run a second process with BLESSENGER_QUALIFICATION_PHASE=restore against the
/// same directory to distinguish restart qualification from an in-memory test.
final class MessagingQualificationTests: XCTestCase {
    @MainActor func testResidentChatTracksCanonicalDeletion() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let destination = env["BLESSENGER_CACHE_EDIT_DIRECTORY"],
              let modelPath = env["BLESSENGER_QUALIFICATION_MODEL"] else {
            throw XCTSkip("Opt-in real resident chat reconciliation")
        }
        let root = URL(fileURLWithPath: destination)
        let artifact = ModelArtifact.gemmaE4B
        let prepared = PreparedModel(modelURL: URL(fileURLWithPath: modelPath), modelID: artifact.repository,
            revision: artifact.revision, contextTokens: 4096, artifactSHA256: artifact.sha256,
            supportsAudio: true, enableMTP: false, provenance: artifact.provenance)
        let controller = CallController(directory: root)
        controller.prepare(allowAvailableModel: true, suppliedModel: prepared)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while controller.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard controller.ready else { XCTFail(controller.notice ?? controller.status); _ = await controller.shutdown(); return }
        let person = Persona(name: "Ada", prompt: "Answer briefly. If a fact is not available in this conversation, respond UNKNOWN. Never invent secrets.")
        let thread = UUID()
        let empty = try ConversationHistory(json: "[]")
        func input(_ text: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["role": "user", "content": [["type": "text", "text": text]]]), as: UTF8.self)
        }
        let secret = "ORCHID-482917" // gitleaks:allow -- synthetic conversation-recall fixture
        let initial = try input("The secret is " + secret + ". Acknowledge.")
        let first = try await controller.replyToMessage(initial, contact: person, thread: thread, history: empty)
        let originalHistory = try empty.appending(userJSON: initial, heardText: first)
        try await controller.persistTextReply(history: originalHistory)
        let question = try input("What is the secret? If it is unavailable respond UNKNOWN.")
        // The canonical conversation has been deleted between turns; identity
        // and prompt are unchanged, so this catches identity-only reuse.
        let second = try await controller.replyToMessage(question, contact: person, thread: thread, history: empty)
        XCTAssertFalse(second.contains(secret), second)
        XCTAssertTrue(second.localizedCaseInsensitiveContains("UNKNOWN"), second)
        let secondHistory = try empty.appending(userJSON: question, heardText: second)
        try await controller.persistTextReply(history: secondHistory)
        let thirdInput = try input("The replacement secret is MAPLE-731802. Acknowledge.")
        _ = try await controller.replyToMessage(thirdInput, contact: person, thread: thread, history: secondHistory)
        // Simulate deletion arriving between inference and publication.
        try await controller.persistTextReply(history: empty)
        let fourth = try await controller.replyToMessage(question, contact: person, thread: thread, history: empty)
        XCTAssertFalse(fourth.contains("MAPLE-731802"), fourth)
        XCTAssertTrue(fourth.localizedCaseInsensitiveContains("UNKNOWN"), fourth)
        let erasedHistory = try empty.appending(userJSON: question, heardText: fourth)
        try await controller.persistTextReply(history: erasedHistory)
        // Restoring a previous branch must select its retained exact prefix,
        // rather than the latest (different) branch or an unrelated contact.
        let restored = try await controller.replyToMessage(question, contact: person, thread: thread, history: originalHistory)
        XCTAssertTrue(restored.contains(secret), restored)
        let authoritative = try originalHistory.appending(userJSON: question, heardText: restored)
        try await controller.persistTextReply(history: authoritative)
        let closed = await controller.shutdown()
        XCTAssertTrue(closed)
        let folder = GemmaRuntime.conversationDirectory(model: prepared, prompt: person.prompt,
            directory: root.appending(path: "Contacts/" + person.id.uuidString + "/Chats/" + thread.uuidString))
        let store = CheckpointStore(directory: folder)
        let record = try XCTUnwrap(store.currentRecord())
        let saved = try XCTUnwrap(store.load(configuration: record.configuration))
        XCTAssertEqual(try ConversationHistory(json: saved.historyJSON), authoritative)
        XCTAssertEqual(try TranscriptFiles(directory: folder).load()?.historyJSON, authoritative.json)
        try JSONSerialization.data(withJSONObject: ["after_deletion": second, "after_publication_race": fourth, "after_restoration": restored,
            "cache_history": saved.historyJSON], options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appending(path: "resident-reconciliation.json"))
    }

    @MainActor func testMessagingAndConsultationPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BLESSENGER_QUALIFICATION_DIRECTORY"],
              let modelPath = environment["BLESSENGER_QUALIFICATION_MODEL"] else {
            throw XCTSkip("Opt-in real Gemma messaging qualification")
        }
        let root = URL(fileURLWithPath: path)
        let artifact = ModelArtifact.gemmaE4B
        let prepared = PreparedModel(modelURL: URL(fileURLWithPath: modelPath), modelID: artifact.repository,
            revision: artifact.revision, contextTokens: 4096, artifactSHA256: artifact.sha256,
            supportsAudio: true, enableMTP: false, provenance: artifact.provenance)
        let controller = CallController(directory: root.appending(path: "Runtime"))
        controller.prepare(allowAvailableModel: true, suppliedModel: prepared)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while controller.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.ready, controller.notice ?? controller.status)
        guard controller.ready else { _ = await controller.shutdown(); return }
        let model = MessagingModel(directory: root.appending(path: "Messages"))
        await model.load()
        if environment["BLESSENGER_QUALIFICATION_PHASE"] == "restore" {
            let notes = try XCTUnwrap(model.state.threads.first { $0.title == "Notes" })
            let count = model.state.messages.count
            await model.send("What project codeword did I tell you? Reply with just the codeword, no mentions.", threadID: notes.id, mentions: [], attachments: [], controller: controller)
            XCTAssertNil(model.error)
            XCTAssertEqual(model.state.messages.count, count + 2)
            XCTAssertTrue(model.state.messages.last?.text.lowercased().contains("marigold") == true)
        } else {
            XCTAssertTrue(model.state.contacts.isEmpty, "Use a fresh evidence directory")
            let ada = Persona(name: "Ada", prompt: "You are Ada, a helpful contact. Answer briefly. Only summon another contact if explicitly asked. Do not mention contacts otherwise.")
            let grace = Persona(name: "Grace", prompt: "You are Grace, a helpful contact. Answer briefly. When explicitly asked to ask another contact a question, address that person by @name and ask them directly.")
            let ben = Persona(name: "Ben", prompt: "You are Ben, a helpful contact. Answer questions briefly yourself. Do not mention or summon other contacts.")
            for person in [ada,grace,ben] { try await model.store.save(person) }
            let notes = ChatThread(title: "Notes", participants: [ada.id])
            let panel = ChatThread(title: "Panel", participants: [grace.id,ben.id])
            try await model.store.save(notes); try await model.store.save(panel)
            await model.load()
            await model.send("The project codeword is marigold. Remember it. Reply briefly without mentioning any contact.", threadID: notes.id, mentions: [], attachments: [], controller: controller)
            XCTAssertNil(model.error)
            let sourceBefore = model.state.messages.filter { $0.thread == notes.id }
            XCTAssertEqual(sourceBefore.count, 2)
            XCTAssertTrue(sourceBefore.last?.text.lowercased().contains("marigold") == true)
            await model.send("@Grace, say hello in one short sentence.", threadID: panel.id,
                mentions: [.init(kind: .contact, id: grace.id, label: grace.name)], attachments: [], controller: controller)
            XCTAssertNil(model.error)
            await model.send("Who are you? Give only your name.", threadID: panel.id, mentions: [], attachments: [], controller: controller)
            XCTAssertNil(model.error)
            XCTAssertEqual(model.state.messages.last?.sender, grace.id)
            await model.send("@#Notes, what is the project codeword? Answer with only the word.", threadID: panel.id,
                mentions: [.init(kind: .conversation, id: notes.id, label: "#Notes")], attachments: [], controller: controller)
            XCTAssertNil(model.error)
            XCTAssertEqual(model.state.messages.last?.sender, ada.id)
            XCTAssertEqual(model.state.messages.last?.consultationSources, [notes.id])
            XCTAssertTrue(model.state.messages.last?.text.lowercased().contains("marigold") == true)
            XCTAssertEqual(model.state.messages.filter { $0.thread == notes.id }, sourceBefore, "Consultation must not write to its source")
            XCTAssertEqual(model.state.threads.first { $0.id == panel.id }?.participants, [grace.id,ben.id])
            await model.send("Say your name only.", threadID: panel.id, mentions: [], attachments: [], controller: controller)
            XCTAssertNil(model.error)
            XCTAssertEqual(model.state.messages.last?.sender, grace.id, "Recent guest must not replace a group member as default responder")
            await model.send("@Grace, ask @Ben to explain two plus two in one sentence. Address him by @Ben. Do not answer the math question yourself.", threadID: panel.id,
                mentions: [.init(kind: .contact, id: grace.id, label: grace.name)], attachments: [], controller: controller)
            XCTAssertNil(model.error)
            XCTAssertTrue(model.state.attempts.contains { $0.automatic && $0.recipient?.id == ben.id && $0.status == .completed })
            XCTAssertLessThanOrEqual(model.state.attempts.filter(\.automatic).count, 4)
        }
        let receipt = try JSONEncoder().encode(model.state.messages)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let phase = environment["BLESSENGER_QUALIFICATION_PHASE"] ?? "initial"
        try receipt.write(to: root.appending(path: "messages-\(phase)-\(UUID().uuidString).json"), options: .atomic)
        let saved = await controller.shutdown()
        XCTAssertTrue(saved, controller.notice ?? "Shutdown failed")
        try await model.store.close()
    }
}
