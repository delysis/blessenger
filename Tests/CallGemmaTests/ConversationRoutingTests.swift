import XCTest
@testable import CallGemma

final class ConversationRoutingTests: XCTestCase {
    func testRecipientsRespectDeletedDirectChatsAndRestoreWithoutHidingNewContacts() {
        let removed = Persona(name: "Qualification", prompt: "Test")
        let fresh = Persona(name: "New", prompt: "Test")
        var direct = ChatThread(title: removed.name, participants: [removed.id], deleted: true)
        var state = MessagingSnapshot(contacts: [removed, fresh], threads: [direct])
        XCTAssertEqual(ConversationRouting.recipientContacts(in: state).map(\.id), [fresh.id])
        direct.deleted = false
        state.threads = [direct]
        XCTAssertEqual(ConversationRouting.recipientContacts(in: state).map(\.id), [removed.id, fresh.id])
        state.threads.append(ChatThread(title: "Old", participants: [removed.id], deleted: true))
        XCTAssertEqual(ConversationRouting.recipientContacts(in: state).map(\.id), [removed.id, fresh.id])
        state.threads = [ChatThread(title: "Deleted group", participants: [removed.id, fresh.id], deleted: true)]
        XCTAssertEqual(ConversationRouting.recipientContacts(in: state).map(\.id), [removed.id, fresh.id])
    }

    func testUnaddressedGroupUsesMostRecentPresentContactNotUserOrGuest() throws {
        let ada = Persona(name: "Ada", prompt: "Math")
        let grace = Persona(name: "Grace", prompt: "Computers")
        let guest = Persona(name: "Guest", prompt: "Visitor")
        let thread = ChatThread(title: "Group", participants: [ada.id, grace.id])
        var state = MessagingSnapshot(contacts: [ada, grace, guest], threads: [thread], messages: [
            ChatMessage(thread: thread.id, sender: ada.id, text: "A"),
            ChatMessage(thread: thread.id, sender: grace.id, text: "B"),
            ChatMessage(thread: thread.id, sender: guest.id, text: "C"),
            ChatMessage(thread: thread.id, text: "User")])
        let message = ChatMessage(thread: thread.id, text: "Continue")
        XCTAssertEqual(try ConversationRouting.targets(for: message, state: state).map { $0.recipient?.id }, [grace.id])
        state.messages = []
        for _ in 0..<100 {
            let target = try XCTUnwrap(ConversationRouting.targets(for: message, state: state).first?.recipient)
            XCTAssertTrue(thread.participants.contains(target.id))
        }
    }

    func testCallInitialSpeakerSharesRoutingAndExcludesDeletedHistory() throws {
        let a = Persona(name: "Same", prompt: "A")
        let b = Persona(name: "Same", prompt: "B")
        let removed = Persona(name: "Removed", prompt: "C")
        var thread = ChatThread(title: "Group", participants: [a.id, b.id, removed.id])
        var deleted = ChatMessage(thread: thread.id, sender: a.id, text: "Deleted")
        deleted.deleted = true
        var state = MessagingSnapshot(contacts: [a, b], threads: [thread], messages: [
            ChatMessage(thread: thread.id, sender: b.id, text: "Latest present speaker"),
            deleted,
            ChatMessage(thread: thread.id, sender: removed.id, text: "Removed speaker"),
            ChatMessage(thread: UUID(), sender: a.id, text: "Other chat"),
            ChatMessage(thread: thread.id, text: "User")])
        XCTAssertEqual(ConversationRouting.initialResponder(in: thread, state: state)?.id, b.id)
        let message = ChatMessage(thread: thread.id, text: "Continue")
        XCTAssertEqual(try ConversationRouting.targets(for: message, state: state).first?.recipient?.id, b.id)
        state.contacts = []
        XCTAssertNil(ConversationRouting.initialResponder(in: thread, state: state))
        state.contacts = [a, b]
        thread.deleted = true
        XCTAssertNil(ConversationRouting.initialResponder(in: thread, state: state))
    }

    func testExplicitMentionsAndChatGuestsOverrideRecentResponderWithoutMembershipChanges() throws {
        let a = Persona(name: "Ada", prompt: "A")
        let b = Persona(name: "Grace", prompt: "B")
        let c = Persona(name: "Guest", prompt: "C")
        let home = ChatThread(title: "Home", participants: [a.id, b.id])
        let source = ChatThread(title: "Consultants", participants: [b.id, c.id])
        let state = MessagingSnapshot(contacts: [a, b, c], threads: [home, source], messages: [ChatMessage(thread: home.id, sender: a.id, text: "Recent")])
        let message = ChatMessage(thread: home.id, text: "Consult", mentions: [
            ChatMention(kind: .contact, id: b.id, label: b.name),
            ChatMention(kind: .conversation, id: source.id, label: "#Consultants")])
        let jobs = try ConversationRouting.targets(for: message, state: state)
        XCTAssertEqual(jobs.map { $0.recipient?.id }, [b.id, c.id])
        XCTAssertEqual(jobs.map(\.consultations), [[source.id], [source.id]])
        XCTAssertEqual(state.threads[0].participants, [a.id, b.id])
    }

    func testMentionBoundariesAndDuplicateNamesAreUnambiguous() {
        let a = Persona(name: "Ann", prompt: "A")
        let b = Persona(name: "Ann", prompt: "B")
        let c = Persona(name: "Anna", prompt: "C")
        let thread = ChatThread(title: "Ann", participants: [a.id])
        let state = MessagingSnapshot(contacts: [a,b,c], threads: [thread])
        XCTAssertEqual(ConversationRouting.generatedMentions(in: "@Ann", state: state), [])
        let label = ConversationRouting.displayLabel(a, contacts: state.contacts)
        let mentions = ConversationRouting.generatedMentions(in: "@\(label), @Anna and @#Ann", state: state)
        XCTAssertEqual(Set(mentions.map(\.id)), Set([a.id, c.id, thread.id]))
        XCTAssertFalse(ConversationRouting.contains(ChatMention(kind: .contact, id: a.id, label: "Ann"), in: "@Anna"))
    }

    func testFrozenConsultationInputIsCanonicalAfterSourceEdits() throws {
        let person = Persona(name: "Ada", prompt: "A")
        let thread = ChatThread(title: "Home", participants: [person.id])
        let source = ChatThread(title: "Source", participants: [person.id])
        let user = ChatMessage(thread: thread.id, text: "Consult source")
        var state = MessagingSnapshot(contacts: [person], threads: [thread,source], messages: [
            ChatMessage(thread: source.id, text: "The codeword is marigold."), user])
        let attempt = GenerationAttempt(origin: user.id, trigger: user.id, thread: thread.id, candidates: [person], recipient: person, consultations: [source.id])
        let frozen = try ConversationRouting.request(for: attempt, state: state)
        XCTAssertTrue(frozen.contains("marigold"))
        let answer = ChatMessage(thread: thread.id, sender: person.id, text: "marigold", origin: user.id, requestJSON: frozen)
        state.messages[0].text = "The codeword is violet."
        state.messages.append(answer)
        let canonical = try ConversationRouting.canonicalHistory(contact: person.id, thread: thread.id, messages: state.messages)
        XCTAssertTrue(canonical.json.contains("marigold"))
        XCTAssertFalse(canonical.json.contains("violet"))
    }
}
