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


extension MessageStoreTests {
    func testBundledAdWakeNameMigrationPreservesContactEdits() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MessageStore(url: folder.appending(path: "messages.sqlite"))
        var bundled = Persona(name: "Ad de Jongh", prompt: "Bundled", wakeName: "Ad de Jongh")
        var old = bundled
        old.wakeName = "Ad"; old.prompt = "Edited prompt"; old.name = "Edited display name"
        try await store.save(old)
        try await store.installBundledContacts([bundled])
        var snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.contacts.first?.wakeName, "Ad de Jongh")
        XCTAssertEqual(snapshot.contacts.first?.prompt, "Edited prompt")
        XCTAssertEqual(snapshot.contacts.first?.name, "Edited display name")
        old.wakeName = "Doctor Ad"
        try await store.save(old)
        bundled.prompt = "New bundled prompt"
        try await store.installBundledContacts([bundled])
        snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.contacts.first?.wakeName, "Doctor Ad")
        XCTAssertTrue(snapshot.threads.isEmpty)
        try await store.close()
    }
}


extension MessageStoreTests {
    func testGroupIdentityUsesParticipantSetAndConsolidatesWithoutLosingMessages() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MessageStore(url: folder.appending(path: "messages.sqlite"))
        let peter = Persona(name: "Peter", prompt: "P"), gabor = Persona(name: "Gabor", prompt: "G")
        try await store.save(peter); try await store.save(gabor)
        async let first = store.createChat(ChatThread(title: "P, G", participants: [peter.id, gabor.id]))
        async let reversed = store.createChat(ChatThread(title: "G, P", participants: [gabor.id, peter.id]))
        let ids = try await (first, reversed)
        XCTAssertEqual(ids.0, ids.1)
        let legacy = ChatThread(title: "Legacy duplicate", participants: [gabor.id, peter.id])
        try await store.save(legacy)
        let message = ChatMessage(thread: legacy.id, text: "Preserve me")
        try await store.append(message)
        try await store.consolidateChats(); try await store.consolidateChats()
        let state = try await store.snapshot()
        let visible = state.threads.filter { $0.deleted != true }
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(state.messages.first?.text, message.text)
        XCTAssertEqual(state.messages.first?.thread, visible.first?.id)
        do { _ = try await store.createChat(ChatThread(title: "Invalid", participants: [peter.id, peter.id])); XCTFail("Duplicate participants accepted") } catch {}
        try await store.close()
    }
}
