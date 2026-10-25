import XCTest
import SQLite3
@testable import CallGemma

final class GenerationQueueTests: XCTestCase {
    @MainActor
    func testCallAdmissionBetweenRepliesLeavesRemainingWorkQueued() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = MessagingModel(directory: folder)
        let a = Persona(name: "Ada", prompt: "A")
        let b = Persona(name: "Ben", prompt: "B")
        try await model.store.save(a); try await model.store.save(b)
        let thread = ChatThread(title: "Team", participants: [a.id, b.id])
        try await model.store.save(thread)
        let inference = CallBoundaryInference()
        let accepted = await model.send("Hello", threadID: thread.id,
            mentions: [a, b].map { .init(kind: .contact, id: $0.id, label: $0.name) },
            attachments: [], controller: inference)
        XCTAssertTrue(accepted)
        XCTAssertNil(model.error)
        let interrupted = try await model.store.snapshot()
        XCTAssertEqual(interrupted.attempts.map(\.status), [.completed, .queued])
        XCTAssertEqual(inference.replies, 1)
        inference.acceptsTextWork = true
        await model.resumePending(controller: inference)
        let resumed = try await model.store.snapshot()
        XCTAssertTrue(resumed.attempts.allSatisfy { $0.status == .completed })
        XCTAssertEqual(inference.replies, 2)
        try await model.store.close()
    }

    func testCrashAfterPreparationRestoresExactRequestAndCompletionIsIdempotent() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "messages.sqlite")
        let store = MessageStore(url: url)
        let a = Persona(name: "Ada", prompt: "A")
        let b = Persona(name: "Grace", prompt: "B")
        try await store.save(a); try await store.save(b)
        let thread = ChatThread(title: "Team", participants: [a.id,b.id])
        try await store.save(thread)
        let user = ChatMessage(thread: thread.id, text: "Ask Grace", mentions: [.init(kind: .contact, id: a.id, label: a.name)])
        var state = try await store.snapshot()
        let attempt = try XCTUnwrap(ConversationRouting.targets(for: user, state: state).first)
        try await store.admit(user, attempts: [attempt])
        state = try await store.snapshot()
        let request = try ConversationRouting.request(for: attempt, state: state)
        _ = try await store.prepareAttempt(attempt.id, recipient: a, requestJSON: request)
        try await store.close()
        let reopened = MessageStore(url: url)
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored.attempts.first?.status, .generating)
        XCTAssertEqual(restored.attempts.first?.requestJSON, request)
        let first = try await reopened.completeAttempt(attempt.id, text: "@Grace, please help.")
        let second = try await reopened.completeAttempt(attempt.id, text: "Different text must not replace the first commit.")
        XCTAssertEqual(first, second)
        let final = try await reopened.snapshot()
        XCTAssertEqual(final.messages.count, 2)
        XCTAssertEqual(final.attempts.filter(\.automatic).count, 1)
        XCTAssertEqual(final.attempts.last?.recipient?.id, b.id)
        XCTAssertEqual(final.messages.last?.requestJSON, request)
        try await reopened.close()
    }

    func testPublicationFailureRollsBackReplyStatusAndFollowupsTogether() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "messages.sqlite")
        let store = MessageStore(url: url)
        let person = Persona(name: "Ada", prompt: "A")
        try await store.save(person)
        let thread = ChatThread(title: "Chat", participants: [person.id])
        try await store.save(thread)
        let user = ChatMessage(thread: thread.id, text: "Hello")
        let state = try await store.snapshot()
        let job = try XCTUnwrap(ConversationRouting.targets(for: user, state: state).first)
        try await store.admit(user, attempts: [job])
        _ = try await store.prepareAttempt(job.id, recipient: person, requestJSON: user.inputJSON())
        var injected: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &injected), SQLITE_OK)
        defer { sqlite3_close(injected) }
        let sql = "CREATE TRIGGER qualification_abort BEFORE INSERT ON events WHEN NEW.kind='attempt' AND json_extract(CAST(NEW.body AS TEXT),'$.status')='completed' BEGIN SELECT RAISE(ABORT,'qualification fault'); END"
        XCTAssertEqual(sqlite3_exec(injected, sql, nil, nil, nil), SQLITE_OK)
        do { _ = try await store.completeAttempt(job.id, text: "Hello!"); XCTFail("Injected failure was ignored") } catch {}
        let rolledBack = try await store.snapshot()
        XCTAssertEqual(rolledBack.messages, [user])
        XCTAssertEqual(rolledBack.attempts.first?.status, .generating)
        XCTAssertEqual(sqlite3_exec(injected, "DROP TRIGGER qualification_abort", nil, nil, nil), SQLITE_OK)
        _ = try await store.completeAttempt(job.id, text: "Hello!")
        let committed = try await store.snapshot()
        XCTAssertEqual(committed.messages.count, 2)
        XCTAssertEqual(committed.attempts.first?.status, .completed)
        try await store.close()
    }

    func testAutomaticSummonsAreBoundedAndCannotLoop() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MessageStore(url: folder.appending(path: "messages.sqlite"))
        let people = (0..<8).map { Persona(name: "Contact\($0)", prompt: "P\($0)") }
        for person in people { try await store.save(person) }
        let thread = ChatThread(title: "Group", participants: people.map(\.id))
        try await store.save(thread)
        let user = ChatMessage(thread: thread.id, text: "Go", mentions: [.init(kind: .contact, id: people[0].id, label: people[0].name)])
        let initial = try await store.snapshot()
        let jobs = try ConversationRouting.targets(for: user, state: initial)
        try await store.admit(user, attempts: jobs)
        for _ in 0..<10 {
            let state = try await store.snapshot()
            guard let job = state.attempts.first(where: { $0.status == .queued }), let recipient = job.recipient else { break }
            _ = try await store.prepareAttempt(job.id, recipient: recipient, requestJSON: ConversationRouting.request(for: job, state: state))
            _ = try await store.completeAttempt(job.id, text: people.map { "@" + $0.name }.joined(separator: ", "))
        }
        let final = try await store.snapshot()
        XCTAssertEqual(final.attempts.count, 5)
        XCTAssertEqual(final.attempts.filter(\.automatic).count, 4)
        XCTAssertEqual(Set(final.attempts.compactMap { $0.recipient?.id }).count, 5)
        XCTAssertTrue(final.attempts.allSatisfy { $0.status == .completed })
        try await store.close()
    }
}

@MainActor
private final class CallBoundaryInference: MessageInference {
    var acceptsTextWork = true
    var replies = 0
    func replyToMessage(_ json: String, contact: Persona, thread: UUID, history: ConversationHistory) async throws -> String {
        XCTAssertTrue(acceptsTextWork)
        replies += 1
        return "Hello."
    }
    func persistTextReply(history: ConversationHistory) async throws { acceptsTextWork = false }
    func abandonTextReply() { XCTFail("Queued work should not fail when a call starts") }
}

extension GenerationQueueTests {
    func testDirectChatCreationUsesStableContactIdentityAndMergesLegacyDuplicates() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MessageStore(url: folder.appending(path: "messages.sqlite"))
        let a = Persona(name: "Same name", prompt: "A")
        let b = Persona(name: "Same name", prompt: "B")
        try await store.installBundledContacts([a, b])
        async let first = store.createChat(ChatThread(title: a.name, participants: [a.id]))
        async let second = store.createChat(ChatThread(title: a.name, participants: [a.id]))
        let ids = try await [first, second]
        XCTAssertEqual(ids, [a.id, a.id])
        let distinct = try await store.createChat(ChatThread(title: b.name, participants: [b.id]))
        XCTAssertEqual(distinct, b.id)
        let old = ChatThread(title: "Old duplicate", participants: [a.id])
        try await store.save(old)
        let message = ChatMessage(thread: old.id, text: "Retain this")
        try await store.append(message)
        try await store.consolidateChats()
        try await store.consolidateChats()
        try await store.close()
        let restored = try await store.snapshot()
        XCTAssertEqual(restored.threads.filter { $0.deleted != true && $0.participants == [a.id] }.map(\.id), [a.id])
        XCTAssertEqual(restored.messages.first(where: { $0.id == message.id })?.thread, a.id)
        XCTAssertEqual(restored.messages.first(where: { $0.id == message.id })?.text, message.text)
        XCTAssertEqual(restored.threads.first(where: { $0.id == old.id })?.deleted, true)
        try await store.close()
    }
}
