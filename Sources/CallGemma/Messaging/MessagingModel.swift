import Combine
import Foundation

@MainActor
final class MessagingModel: ObservableObject {
    @Published private(set) var state = MessagingSnapshot()
    @Published var selected: UUID?
    @Published var error: String?
    @Published private(set) var generating: Set<UUID> = []
    let store: MessageStore
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Blessenger")) {
        store = MessageStore(url: directory.appending(path: "messages.sqlite"))
    }
    func installBundledContacts() async {
        do {
            guard let url = BlessengerResources.bundle.url(forResource: "contacts", withExtension: "json") else {
                throw GemmaError(message: "The bundled contacts are missing.")
            }
            let contacts = try await Task.detached {
                try JSONDecoder().decode([Persona].self, from: Data(contentsOf: url))
            }.value
            try await store.installBundledContacts(contacts)
            try await store.consolidateDirectChats()
        } catch { self.error = error.localizedDescription }
    }
    func load() async {
        do { state = try await store.snapshot() }
        catch { self.error = error.localizedDescription }
    }
    func save(_ contact: Persona) async {
        guard state.contacts.first(where: { $0.id == contact.id }) != contact else { return }
        do {
            var saved = contact
            if let path = contact.voice, path.hasPrefix("/") {
                let source = URL(fileURLWithPath: path)
                let destination = URL.applicationSupportDirectory.appending(path: "Blessenger/Media/Voices/" + contact.id.uuidString + "/" + source.lastPathComponent)
                if source != destination {
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
                    }.value
                }
                saved.voice = destination.path
            }
            try await store.save(saved); await load()
        }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func createChat(contacts: [UUID], id: UUID = UUID()) async -> UUID? {
        let title = contacts.compactMap { id in state.contacts.first { $0.id == id }?.name }.joined(separator: ", ")
        let thread = ChatThread(id: id, title: title, participants: contacts)
        do { let destination = try await store.createChat(thread); await load(); selected = destination; return destination }
        catch { self.error = error.localizedDescription; return nil }
    }
    func react(_ message: ChatMessage, emoji: String) async {
        do { try await store.react(message: message.id, emoji: emoji); await load() }
        catch { self.error = error.localizedDescription }
    }
    private var draining = false

    @discardableResult
    func send(_ text: String, threadID: UUID, mentions: [ChatMention], attachments: [MessageAttachment], controller: any MessageInference, onAdmitted: (() -> Void)? = nil) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        let message = ChatMessage(thread: threadID, text: text, mentions: mentions, attachments: attachments,
            voiceNote: attachments.contains { $0.kind == .audio } ? true : nil)
        do {
            let current = try await store.snapshot()
            let attempts = try ConversationRouting.targets(for: message, state: current)
            try await store.admit(message, attempts: attempts)
            state = try await store.snapshot()
            onAdmitted?()
            await resumePending(controller: controller)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func retry(thread: UUID, controller: any MessageInference) async {
        do { try await store.retryFailures(thread: thread); await resumePending(controller: controller) }
        catch { self.error = error.localizedDescription }
    }

    func resumePending(controller: any MessageInference) async {
        guard !draining, controller.acceptsTextWork else { return }
        draining = true
        defer { draining = false; generating = [] }
        while true {
            // A call may have started while the preceding reply was being saved.
            // Leave subsequent jobs queued for the call-end resumption.
            guard controller.acceptsTextWork else { return }
            var active: UUID?
            do {
                state = try await store.snapshot()
                let visible = Set(state.threads.filter { $0.deleted != true }.map(\.id))
                let pending = state.attempts.filter { visible.contains($0.thread) && ($0.status == .queued || $0.status == .generating) }
                generating = Set(pending.map(\.thread))
                guard var attempt = pending.first else { return }
                active = attempt.id
                guard let person = attempt.recipient else { throw GemmaError(message: "No responder was selected.") }
                let request: String
                if let frozen = attempt.requestJSON { request = frozen }
                else {
                    request = try await store.requestIncludingCallMemory(
                        ConversationRouting.request(for: attempt, state: state), contact: person.id)
                }
                attempt = try await store.prepareAttempt(attempt.id, recipient: person, requestJSON: request)
                let history = try ConversationRouting.canonicalHistory(contact: person.id, thread: attempt.thread, messages: state.messages)
                guard controller.acceptsTextWork else { return }
                let answer = try await controller.replyToMessage(request, contact: person, thread: attempt.thread, history: history)
                _ = try await store.completeAttempt(attempt.id, text: answer)
                state = try await store.snapshot()
                try await controller.persistTextReply(history: ConversationRouting.canonicalHistory(contact: person.id, thread: attempt.thread, messages: state.messages))
            } catch {
                controller.abandonTextReply()
                if let active {
                    do { try await store.failAttempt(active, reason: error.localizedDescription) }
                    catch { self.error = "The reply failed and its status could not be saved: \(error.localizedDescription)"; return }
                }
                self.error = error.localizedDescription
                await load()
                return
            }
        }
    }

    func deleteMessage(_ id: UUID, deleted: Bool = true) async {
        do { try await store.setMessageDeleted(id, deleted: deleted); await load() }
        catch { self.error = error.localizedDescription }
    }
    func restoreMessages(in thread: UUID) async {
        do { try await store.restoreMessages(in: thread); await load() }
        catch { self.error = error.localizedDescription }
    }
    func updateThread(_ thread: ChatThread) async {
        do { try await store.save(thread); state = try await store.snapshot() }
        catch { self.error = error.localizedDescription }
    }

}

enum BlessengerResources {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
    static let voiceNames = ["ad_de_jongh", "arnold_popky", "bessel_van_der_kolk", "christine_courtois", "dolores_mosquera", "francine_shapiro", "gabor_mate", "janina_fisher", "jim_knipe", "judith_herman", "peter_levine", "richard_schwartz", "robert_miller", "shirley_jean_schmidt"]
    static func voiceURL(_ name: String) -> URL? {
        bundle.url(forResource: name, withExtension: "wav", subdirectory: "Voices")
            ?? bundle.url(forResource: name, withExtension: "wav")
    }
    static func label(_ name: String) -> String { name.replacingOccurrences(of: "_", with: " ").capitalized }
}
