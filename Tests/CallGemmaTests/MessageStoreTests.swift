import XCTest
@testable import CallGemma

final class MessageStoreTests: XCTestCase {
    func testDurableContactsMessagesAndReactions() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "messages.sqlite")
        let store = MessageStore(url: url)
        let contact = Persona(name: "Ada", prompt: "Be helpful.")
        try await store.save(contact)
        let thread = ChatThread(title: "Ada", participants: [contact.id])
        try await store.save(thread)
        let user = ChatMessage(thread: thread.id, text: "Hello")
        try await store.append(user)
        let reply = ChatMessage(thread: thread.id, sender: contact.id, text: "Hello!", origin: user.id)
        try await store.append(reply)
        try await store.react(message: reply.id, emoji: "❤️")
        try await store.close()
        let reopened = MessageStore(url: url)
        let state = try await reopened.snapshot()
        XCTAssertEqual(state.contacts, [contact])
        XCTAssertEqual(state.messages.map(\.text), ["Hello", "Hello!"])
        XCTAssertEqual(state.messages.last?.reactions, ["❤️"])
        try await reopened.react(message: reply.id, emoji: "❤️")
        let toggled = try await reopened.snapshot()
        XCTAssertEqual(toggled.messages.last?.reactions, [])
        try await reopened.close()
    }
    func testWallClockChangesCannotReorderTheTranscript() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MessageStore(url: folder.appending(path: "messages.sqlite"))
        let person = Persona(name: "Ada", prompt: "A")
        try await store.save(person)
        let thread = ChatThread(title: "Ada", participants: [person.id])
        try await store.save(thread)
        let first = ChatMessage(thread: thread.id, text: "First", created: Date(timeIntervalSince1970: 200))
        let second = ChatMessage(thread: thread.id, text: "Second", created: Date(timeIntervalSince1970: 100))
        try await store.append(first); try await store.append(second)
        try await store.react(message: first.id, emoji: "👍")
        let state = try await store.snapshot()
        XCTAssertEqual(state.messages.map(\.id), [first.id, second.id])
        try await store.close()
    }

    func testInvalidDestinationDoesNotCommitAndDuplicateIsRejected() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MessageStore(url: folder.appending(path: "messages.sqlite"))
        let contact = Persona(name: "Ada", prompt: "Be helpful.")
        try await store.save(contact)
        do {
            try await store.save(ChatThread(title: "Missing", participants: [UUID()]))
            XCTFail("Unknown contact accepted")
        } catch {}
        let thread = ChatThread(title: "Ada", participants: [contact.id])
        try await store.save(thread)
        let message = ChatMessage(thread: thread.id, text: "Once")
        try await store.append(message)
        do { try await store.append(message); XCTFail("Duplicate accepted") } catch {}
        let state = try await store.snapshot()
        XCTAssertEqual(state.threads.count, 1)
        XCTAssertEqual(state.messages, [message])
        try await store.close()
    }
}
