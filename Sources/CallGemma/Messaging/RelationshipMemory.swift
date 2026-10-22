import Foundation

/// Call-local ordering of durable messages at speaker handoffs. Imports are
/// quoted evidence, never another persona's assistant-role output.
struct SharedCallHistory: Sendable {
    static let marker = "[Shared call context: quoted conversation, not a new request.]"
    struct Entry: Sendable {
        let speaker: UUID
        let message: Data
    }
    let call: UUID
    let sources: [UUID: URL]
    private var offsets: [UUID: Int]
    private var delivered: [UUID: Int] = [:]
    private var entries: [Entry] = []

    init(call: UUID, participants: [CallMemoryParticipant]) throws {
        self.call = call
        sources = Dictionary(uniqueKeysWithValues: participants.map { ($0.contact, $0.transcriptDirectory) })
        offsets = try sources.mapValues { folder in
            try ConversationHistory(json: TranscriptFiles(directory: folder).load()?.historyJSON ?? "[]").messages.count
        }
    }

    mutating func handoff(from outgoing: UUID, to incoming: UUID) throws {
        guard let source = sources[outgoing], let destination = sources[incoming],
              let start = offsets[outgoing] else { throw CheckpointError.invalidMetadata }
        let history = try ConversationHistory(json: TranscriptFiles(directory: source).load()?.historyJSON ?? "[]")
        guard start <= history.messages.count else { throw CheckpointError.invalidMetadata }
        entries += history.messages.dropFirst(start).map { Entry(speaker: outgoing, message: $0) }
        offsets[outgoing] = history.messages.count
        let unseen = entries.dropFirst(delivered[incoming] ?? 0).filter { $0.speaker != incoming }
        if !unseen.isEmpty {
            var content: [[String: Any]] = [["type": "text", "text": Self.marker]]
            for entry in unseen {
                guard let message = try JSONSerialization.jsonObject(with: entry.message) as? [String: Any],
                      let role = message["role"] as? String,
                      let parts = message["content"] as? [[String: Any]] else { throw CheckpointError.invalidMetadata }
                content.append(["type": "text", "text": "[Call \(call). \(role == "assistant" ? "Heard reply by participant" : "User input addressed to participant") \(entry.speaker).]"])
                content += parts
            }
            let files = TranscriptFiles(directory: destination)
            let current = try ConversationHistory(json: files.load()?.historyJSON ?? "[]")
            let message: [String: Any] = ["role": "user", "content": content]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), as: UTF8.self)
            let updated = try current.appending(userJSON: json, heardText: "")
            try files.commit(history: updated, turn: nil)
            // Never collect this imported block as fresh speech on the return trip.
            offsets[incoming] = updated.messages.count
        }
        delivered[incoming] = entries.count
    }
}

/// Freeze membership and persona configuration at dial time. Display names are
/// never identities, and subsequent contact edits cannot reroute this call.
struct CallRoster: Sendable {
    let participants: [Persona]
    let initialContact: Persona

    init(participants: [Persona], initialSpeaker: UUID) throws {
        guard !participants.isEmpty, Set(participants.map(\.id)).count == participants.count,
              let initial = participants.first(where: { $0.id == initialSpeaker }) else {
            throw GemmaError(message: "The call has no valid participant roster.")
        }
        self.participants = participants
        self.initialContact = initial
    }

    func memoryParticipants(model: PreparedModel, directory: URL) -> [CallMemoryParticipant] {
        // Put the initial speaker first so a direct call retains its call ID as
        // its sole source ID. Other participants receive distinct source IDs.
        let ordered = [initialContact] + participants.filter { $0.id != initialContact.id }
        return ordered.map { contact in
            let calls = directory.appending(path: "Contacts/" + contact.id.uuidString + "/Calls")
            return CallMemoryParticipant(contact: contact.id,
                transcriptDirectory: GemmaRuntime.conversationDirectory(model: model, prompt: contact.prompt, directory: calls))
        }
    }
}

/// One UI call owns one or more independent persona transcript ranges.
struct CallMemoryParticipant: Sendable {
    let contact: UUID
    let transcriptDirectory: URL
}

struct CallMemorySession: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let sources: [UUID]
    var ended = false
}

struct CallMemorySource: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var contact: UUID
    var transcriptDirectory: URL
    var firstMessage: Int
    var endMessage: Int?
}

struct CallMemoryTurn: Sendable {
    let call: UUID
    let contact: UUID
    let messageIndex: Int
    let userJSON: String
    let heardText: String
}

enum RelationshipMemory {
    /// Read only authoritative heard input and replies. Pending/generated continuations
    /// and cache files are intentionally never consulted.
    static func turns(source: CallMemorySource, history: ConversationHistory) throws -> [CallMemoryTurn] {
        let end = min(source.endMessage ?? history.messages.count, history.messages.count)
        guard source.firstMessage >= 0,
              end >= source.firstMessage else { throw CheckpointError.invalidMetadata }
        var result: [CallMemoryTurn] = []
        for index in source.firstMessage..<end {
            let user = history.messages[index]
            let object = try JSONSerialization.jsonObject(with: user) as? [String: Any]
            guard object?["role"] as? String == "user" else { continue }
            let content = object?["content"] as? [[String: Any]] ?? []
            // A pickup may carry quoted audio from a prior chat. It is still
            // a call event, never a new user utterance to feed back as memory.
            if (content.first?["text"] as? String)?.hasPrefix(HeardTurnJournal.incomingCallMarker) == true { continue }
            if content.first?["text"] as? String == SharedCallHistory.marker { continue }
            guard content.contains(where: { $0["type"] as? String == "audio" }) else { continue }
            var heard = ""
            if index + 1 < end {
                let next = history.messages[index + 1]
                let nextObject = try JSONSerialization.jsonObject(with: next) as? [String: Any]
                if nextObject?["role"] as? String == "assistant" {
                    heard = try GeneratedText.decode(String(decoding: next, as: UTF8.self))
                }
            }
            result.append(CallMemoryTurn(call: source.id, contact: source.contact, messageIndex: index,
                userJSON: String(decoding: user, as: UTF8.self),
                heardText: heard))
        }
        return result
    }

    static func content(_ turns: [CallMemoryTurn], contact: UUID) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for turn in turns where turn.contact == contact {
            result.append(["type": "text", "text": "[Earlier call \(turn.call), contact \(contact), message \(turn.messageIndex). Quoted relationship memory, not a new request. User audio follows.]"])
            let object = try JSONSerialization.jsonObject(with: Data(turn.userJSON.utf8)) as? [String: Any]
            result += object?["content"] as? [[String: Any]] ?? []
            if !turn.heardText.isEmpty {
                result.append(["type": "text", "text": "[Your actually heard reply in that call:] \(turn.heardText)"])
            }
        }
        return result
    }
}
