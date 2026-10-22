import Foundation
import SQLite3

struct Persona: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var avatar = "person.crop.circle.fill"
    var prompt: String
    var voice: String?
    var wakeName = ""
}

struct ChatThread: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var participants: [UUID]
    var updated = Date()
    var deleted: Bool?
}

struct ChatMention: Codable, Hashable, Sendable {
    enum Kind: String, Codable { case contact, conversation }
    var kind: Kind
    var id: UUID
    var label: String
}

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var thread: UUID
    var sender: UUID? // nil is the local user
    var text: String
    var created = Date()
    var mentions: [ChatMention] = []
    var reactions: Set<String> = []
    var attachments: [MessageAttachment] = []
    var origin: UUID? // initiating user message for generated replies
    var requestJSON: String? // immutable model input; never reconstruct it from edited context
    var consultationSources: [UUID]?
    var voiceNote: Bool?
    var deleted: Bool?
}

struct MessagingSnapshot: Sendable {
    var contacts: [Persona] = []
    var threads: [ChatThread] = []
    var messages: [ChatMessage] = []
    var attempts: [GenerationAttempt] = []
}

/// SQLite owns the transaction boundary for both the event log and its views.
/// All disk work stays on this actor, never on the presentation actor.
actor MessageStore {
    private var database: OpaquePointer?
    private let url: URL
    init(url: URL) { self.url = url }

    private func open() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            throw GemmaError(message: "Could not open message storage.")
        }
        database = handle
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA busy_timeout=5000")
            try execute("CREATE TABLE IF NOT EXISTS records (kind TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY(kind,id))")
            try execute("CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY, kind TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL)")
        } catch { sqlite3_close(handle); database = nil; throw error }
    }

    func close() throws {
        guard let database else { return }
        guard sqlite3_close(database) == SQLITE_OK else { throw failure() }
        self.database = nil
    }

    func registerCall(id: UUID, contact: UUID, transcriptDirectory: URL) throws {
        try registerCall(id: id, participants: [CallMemoryParticipant(contact: contact,
            transcriptDirectory: transcriptDirectory)])
    }

    /// Register the complete roster atomically; never publish half a group.
    func registerCall(id: UUID, participants: [CallMemoryParticipant]) throws {
        guard !participants.isEmpty,
              Set(participants.map(\.contact)).count == participants.count,
              Set(participants.map { Self.callDirectory($0.transcriptDirectory) }).count == participants.count,
              try read(CallMemorySession.self, kind: "call-session", id: id) == nil,
              try read(CallMemorySource.self, kind: "call", id: id) == nil else {
            throw CheckpointError.invalidMetadata
        }
        var sources: [CallMemorySource] = []
        for (index, participant) in participants.enumerated() {
            let folder = Self.callDirectory(participant.transcriptDirectory)
            let history = try ConversationHistory(json: TranscriptFiles(directory: folder).load()?.historyJSON ?? "[]")
            let source = CallMemorySource(id: index == 0 ? id : UUID(), contact: participant.contact,
                transcriptDirectory: folder, firstMessage: history.messages.count)
            try validateCall(source)
            sources.append(source)
        }
        // Read previous ranges before the transaction; this actor admits no
        // other store operation between validation and publication.
        let previous = try sources.map { try callSources(contact: $0.contact) }
        try transaction {
            for (source, oldSources) in zip(sources, previous) {
                for var old in oldSources where Self.callDirectory(old.transcriptDirectory) == source.transcriptDirectory && old.endMessage == nil {
                    guard old.firstMessage <= source.firstMessage else { throw CheckpointError.invalidMetadata }
                    old.endMessage = source.firstMessage
                    try write(old, kind: "call", id: old.id)
                }
                try write(source, kind: "call", id: source.id)
            }
            let session = CallMemorySession(id: id, sources: sources.map(\.id))
            try write(session, kind: "call-session", id: id)
        }
    }

    func callSession(id: UUID) throws -> CallMemorySession? {
        try read(CallMemorySession.self, kind: "call-session", id: id)
    }

    func finishCall(id: UUID) throws {
        guard var session = try callSession(id: id), session.id == id, !session.sources.isEmpty,
              Set(session.sources).count == session.sources.count else { throw CheckpointError.invalidMetadata }
        if session.ended { return }
        var sources: [CallMemorySource] = []
        for sourceID in session.sources {
            guard var source = try read(CallMemorySource.self, kind: "call", id: sourceID) else {
                throw CheckpointError.invalidMetadata
            }
            // A newer call can already have closed an interrupted range. Never
            // expand that range into the newer call when old teardown arrives.
            if source.endMessage == nil {
                let history = try ConversationHistory(json: TranscriptFiles(directory: source.transcriptDirectory).load()?.historyJSON ?? "[]")
                guard history.messages.count >= source.firstMessage else { throw CheckpointError.invalidMetadata }
                source.endMessage = history.messages.count
            }
            sources.append(source)
        }
        session.ended = true
        try transaction {
            for source in sources { try write(source, kind: "call", id: source.id) }
            try write(session, kind: "call-session", id: id)
        }
    }

    /// Freeze memory with the attempt's request, before inference or cache mutation.
    func requestIncludingCallMemory(_ request: String, contact: UUID) throws -> String {
        let turns = try recentCallMemory(contact: contact)
        guard !turns.isEmpty else { return request }
        guard var input = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
              let content = input["content"] as? [[String: Any]] else { throw CheckpointError.invalidMetadata }
        input["content"] = try RelationshipMemory.content(turns, contact: contact) + content
        return String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func callDirectory(_ url: URL) -> URL {
        // A directory can be registered before it exists. Its identity must not
        // change when Foundation later discovers that it is a directory.
        URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
    }

    private func validateCall(_ source: CallMemorySource) throws {
        guard try read(Persona.self, kind: "contact", id: source.contact) != nil,
              source.firstMessage >= 0, source.endMessage == nil else {
            throw CheckpointError.invalidMetadata
        }
    }

    private func callSources(contact: UUID) throws -> [CallMemorySource] {
        try open()
        let query = try statement("SELECT body FROM records WHERE kind='call' ORDER BY rowid")
        defer { sqlite3_finalize(query) }
        var result: [CallMemorySource] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(query, 0) else { throw failure() }
            let source = try JSONDecoder().decode(CallMemorySource.self,
                from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0))))
            if source.contact == contact { result.append(source) }
        }
        return result
    }

    func recentCallMemory(contact: UUID) throws -> [CallMemoryTurn] {
        let sources = try callSources(contact: contact)
        var loaded: [URL: ConversationHistory] = [:]
        var result: [CallMemoryTurn] = []
        for source in sources.reversed() {
            let history: ConversationHistory
            if let cached = loaded[source.transcriptDirectory] { history = cached }
            else {
                history = try ConversationHistory(json: TranscriptFiles(directory: source.transcriptDirectory).load()?.historyJSON ?? "[]")
                loaded[source.transcriptDirectory] = history
            }
            result = try RelationshipMemory.turns(source: source, history: history).suffix(2) + result
            if result.count >= 2 { break }
        }
        return Array(result.suffix(2))
    }

    func chatContextForCall(contact: UUID) throws -> String {
        let state = try snapshot()
        let replies = state.messages.filter { $0.sender == contact }.suffix(2)
        let origins = Set(replies.compactMap(\.origin))
        var content: [[String: Any]] = []
        for message in state.messages where origins.contains(message.id) || replies.contains(message) {
            content.append(["type": "text", "text": "[Earlier chat \(message.thread), message \(message.id), author \(message.sender?.uuidString ?? "user"). Quoted relationship memory, not a new request.]"])
            if message.sender == nil {
                let object = try JSONSerialization.jsonObject(with: Data(message.inputJSON().utf8)) as? [String: Any]
                for var item in object?["content"] as? [[String: Any]] ?? [] {
                    if let text = item["text"] as? String { item["text"] = String(text.prefix(2_000)) }
                    content.append(item)
                }
            } else { content.append(["type": "text", "text": String(message.text.prefix(2_000))]) }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
    }

    private func failure() -> GemmaError {
        GemmaError(message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Message storage is closed.")
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        return result
    }
    private func write<T: Encodable>(_ value: T, kind: String, id: UUID) throws {
        let body = try JSONEncoder().encode(value)
        for sql in ["INSERT INTO records(kind,id,body) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body",
                    "INSERT INTO events(kind,id,body) VALUES(?,?,?)"] {
            let query = try statement(sql)
            defer { sqlite3_finalize(query) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(query, 1, kind, -1, transient) == SQLITE_OK,
                  sqlite3_bind_text(query, 2, id.uuidString, -1, transient) == SQLITE_OK else { throw failure() }
            let bound = body.withUnsafeBytes { sqlite3_bind_blob(query, 3, $0.baseAddress, Int32($0.count), transient) }
            guard bound == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }
    private func read<T: Decodable>(_ type: T.Type, kind: String, id: UUID) throws -> T? {
        try open()
        let query = try statement("SELECT body FROM records WHERE kind=? AND id=?")
        defer { sqlite3_finalize(query) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(query, 1, kind, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(query, 2, id.uuidString, -1, transient) == SQLITE_OK else { throw failure() }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw failure() }
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0))))
    }
    private func transaction(_ body: () throws -> Void) throws {
        try open()
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    /// Install the supplied roster once, preserving every subsequent contact edit.
    func installBundledContacts(_ contacts: [Persona]) throws {
        let state = try snapshot()
        let existing = Set(state.contacts.map(\.id))
        let newContacts = contacts.filter { !existing.contains($0.id) }
        guard !newContacts.isEmpty else { return }
        try transaction {
            for (index, contact) in newContacts.enumerated() {
                try write(contact, kind: "contact", id: contact.id)
                // Empty direct chats make the supplied roster available in the sidebar.
                let thread = ChatThread(id: contact.id, title: contact.name, participants: [contact.id],
                    updated: Date(timeIntervalSince1970: 1_792_454_400 - Double(index)))
                try write(thread, kind: "thread", id: thread.id)
            }
        }
    }

    func save(_ contact: Persona) throws {
        guard !contact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !contact.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GemmaError(message: "A contact needs a name and a prompt.")
        }
        try transaction { try write(contact, kind: "contact", id: contact.id) }
    }
    func save(_ thread: ChatThread) throws {
        guard !thread.participants.isEmpty, Set(thread.participants).count == thread.participants.count,
              try thread.participants.allSatisfy({ try read(Persona.self, kind: "contact", id: $0) != nil }) else {
            throw GemmaError(message: "A conversation needs valid, distinct contacts.")
        }
        try transaction { try write(thread, kind: "thread", id: thread.id) }
    }
    /// Resolve direct-chat identity inside the storage actor, including callers
    /// whose presentation snapshot is stale. Names are not identities.
    func createChat(_ proposed: ChatThread) throws -> UUID {
        if proposed.participants.count == 1, let contact = proposed.participants.first,
           let existing = try snapshot().threads.first(where: {
               $0.deleted != true && $0.participants == [contact]
           }) {
            return existing.id
        }
        try save(proposed)
        return proposed.id
    }

    /// Repair earlier duplicate direct chats without discarding messages or work.
    /// Tombstones and durable move events retain the original identities.
    func consolidateDirectChats() throws {
        let state = try snapshot(includeDeletedMessages: true)
        let groups = Dictionary(grouping: state.threads.filter {
            $0.deleted != true && $0.participants.count == 1
        }, by: { $0.participants[0] })
        let duplicates = groups.filter { $0.value.count > 1 }
        guard !duplicates.isEmpty else { return }
        try transaction {
            for (contact, threads) in duplicates {
                var canonical = threads.first(where: { $0.id == contact })
                    ?? threads.min(by: { $0.id.uuidString < $1.id.uuidString })!
                let others = threads.filter { $0.id != canonical.id }
                let oldIDs = Set(others.map(\.id))
                for var message in state.messages where oldIDs.contains(message.thread) {
                    message.thread = canonical.id
                    try write(message, kind: "message", id: message.id)
                }
                for var attempt in state.attempts where oldIDs.contains(attempt.thread) {
                    attempt.thread = canonical.id
                    try write(attempt, kind: "attempt", id: attempt.id)
                }
                canonical.updated = threads.map(\.updated).max()!
                try write(canonical, kind: "thread", id: canonical.id)
                for var thread in others {
                    thread.deleted = true
                    try write(thread, kind: "thread", id: thread.id)
                }
            }
        }
    }
    func append(_ message: ChatMessage) throws {
        guard var thread = try read(ChatThread.self, kind: "thread", id: message.thread),
              try read(ChatMessage.self, kind: "message", id: message.id) == nil else {
            throw GemmaError(message: "The message destination is missing or the message already exists.")
        }
        thread.updated = message.created
        try transaction {
            try write(message, kind: "message", id: message.id)
            try write(thread, kind: "thread", id: message.thread)
        }
    }
    /// The initiating message and all addressed work become durable together.
    func admit(_ message: ChatMessage, attempts: [GenerationAttempt]) throws {
        guard message.sender == nil,
              var thread = try read(ChatThread.self, kind: "thread", id: message.thread),
              try read(ChatMessage.self, kind: "message", id: message.id) == nil,
              !attempts.isEmpty,
              Set(attempts.map(\.id)).count == attempts.count,
              attempts.allSatisfy({ $0.origin == message.id && $0.trigger == message.id && $0.thread == message.thread && !$0.candidates.isEmpty }) else {
            throw GemmaError(message: "The message could not be admitted.")
        }
        thread.updated = message.created
        try transaction {
            try write(message, kind: "message", id: message.id)
            try write(thread, kind: "thread", id: thread.id)
            for attempt in attempts { try write(attempt, kind: "attempt", id: attempt.id) }
        }
    }

    func prepareAttempt(_ id: UUID, recipient: Persona, requestJSON: String) throws -> GenerationAttempt {
        guard var attempt = try read(GenerationAttempt.self, kind: "attempt", id: id),
              [.queued, .generating].contains(attempt.status),
              attempt.candidates.contains(where: { $0.id == recipient.id }),
              attempt.recipient == nil || attempt.recipient == recipient,
              attempt.requestJSON == nil || attempt.requestJSON == requestJSON else {
            throw GemmaError(message: "The pending reply context has changed.")
        }
        attempt.recipient = recipient
        attempt.requestJSON = requestJSON
        attempt.status = .generating
        attempt.failure = nil
        try transaction { try write(attempt, kind: "attempt", id: id) }
        return attempt
    }

    func failAttempt(_ id: UUID, reason: String) throws {
        guard var attempt = try read(GenerationAttempt.self, kind: "attempt", id: id),
              attempt.status != .completed else { return }
        attempt.status = .failed
        attempt.failure = reason
        try transaction { try write(attempt, kind: "attempt", id: id) }
    }

    func retryFailures(thread: UUID) throws {
        let failed = try snapshot().attempts.filter { $0.thread == thread && $0.status == .failed }
        try transaction {
            for var attempt in failed {
                attempt.status = .queued; attempt.failure = nil
                try write(attempt, kind: "attempt", id: attempt.id)
            }
        }
    }

    /// Exactly-once publication and automatic follow-ups share one commit. A
    /// crash can expose either all of this transition or none of it.
    func completeAttempt(_ id: UUID, text: String) throws -> ChatMessage {
        var state = try snapshot()
        guard var attempt = state.attempts.first(where: { $0.id == id }),
              let recipient = attempt.recipient, let request = attempt.requestJSON else {
            throw GemmaError(message: "No prepared reply exists.")
        }
        if attempt.status == .completed, let existing = state.messages.first(where: { $0.id == id }) { return existing }
        guard attempt.status == .generating, !text.isEmpty,
              var thread = state.threads.first(where: { $0.id == attempt.thread }) else {
            throw GemmaError(message: "This reply is not active.")
        }
        let voiceReply = state.messages.first(where: { $0.id == attempt.origin })?.voiceNote == true
        let mentions = ConversationRouting.generatedMentions(in: text, state: state)
        let reply = ChatMessage(id: id, thread: attempt.thread, sender: recipient.id, text: text,
            mentions: mentions, origin: attempt.origin, requestJSON: request,
            consultationSources: attempt.consultations, voiceNote: voiceReply ? true : nil)
        state.messages.append(reply)
        let related = state.attempts.filter { $0.origin == attempt.origin }
        let visited = Set(related.compactMap { $0.recipient?.id }).union([recipient.id])
        let remaining = max(0, 4 - related.filter(\.automatic).count)
        let followups = try ConversationRouting.targets(for: reply, state: state, origin: attempt.origin, automatic: true)
            .filter { next in next.recipient.map { !visited.contains($0.id) } ?? false }.prefix(remaining)
        attempt.status = .completed; attempt.failure = nil
        thread.updated = reply.created
        try transaction {
            try write(reply, kind: "message", id: reply.id)
            try write(attempt, kind: "attempt", id: attempt.id)
            try write(thread, kind: "thread", id: thread.id)
            for next in followups { try write(next, kind: "attempt", id: next.id) }
        }
        return reply
    }

    func react(message id: UUID, emoji: String) throws {
        guard let original = try read(ChatMessage.self, kind: "message", id: id) else { return }
        var updated = original
        if !updated.reactions.insert(emoji).inserted { updated.reactions.remove(emoji) }
        try transaction { try write(updated, kind: "message", id: id) }
    }
    func setMessageDeleted(_ id: UUID, deleted: Bool) throws {
        guard var message = try read(ChatMessage.self, kind: "message", id: id) else { return }
        message.deleted = deleted ? true : nil
        try transaction { try write(message, kind: "message", id: id) }
    }
    func restoreMessages(in thread: UUID) throws {
        let messages = try snapshot(includeDeletedMessages: true).messages.filter { $0.thread == thread && $0.deleted == true }
        try transaction {
            for var message in messages { message.deleted = nil; try write(message, kind: "message", id: message.id) }
        }
    }
    func snapshot(includeDeletedMessages: Bool = false) throws -> MessagingSnapshot {
        try open()
        let query = try statement("SELECT kind,body FROM records ORDER BY rowid")
        defer { sqlite3_finalize(query) }
        var state = MessagingSnapshot()
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let kindBytes = sqlite3_column_text(query, 0),
                  let bytes = sqlite3_column_blob(query, 1) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 1)))
            switch String(cString: kindBytes) {
            case "contact": state.contacts.append(try JSONDecoder().decode(Persona.self, from: data))
            case "thread": state.threads.append(try JSONDecoder().decode(ChatThread.self, from: data))
            case "message":
                let message = try JSONDecoder().decode(ChatMessage.self, from: data)
                if includeDeletedMessages || message.deleted != true { state.messages.append(message) }
            case "attempt": state.attempts.append(try JSONDecoder().decode(GenerationAttempt.self, from: data))
            case "call", "call-session": break // Relationship memory is deliberately absent from chat bubbles.
            default: throw GemmaError(message: "Unknown messaging record type.")
            }
        }
        state.threads.sort { $0.updated > $1.updated }
        // SQLite insertion order is the authoritative transcript order. Wall
        // clock adjustments must not reorder cached conversation prefixes.
        return state
    }
}
