import Foundation

/// Canonical heard messages, including unanswered user speech, independent of the native cache's cursor.
/// A checkpoint is reusable only if every one of its messages is a prefix of
/// this history. Matching just message counts or the last turn is insufficient.
struct ConversationHistory: Sendable, Equatable {
    private(set) var messages: [Data]

    init(json: String) throws {
        guard json.utf8.count <= 16 * 1_024 * 1_024,
              let array = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw GemmaError(message: "Conversation history is not a valid message sequence.")
        }
        var previousRole: String?
        messages = try array.map { message in
            let role = message["role"] as? String
            guard role == "user" || (role == "assistant" && previousRole == "user"),
                  message["content"] != nil else {
                throw GemmaError(message: "Conversation history has an invalid message.")
            }
            previousRole = role
            return try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        }
    }

    func suffix(after cached: Self) throws -> String {
        guard cached.messages.count <= messages.count,
              zip(cached.messages, messages).allSatisfy({ $0 == $1 }) else {
            throw GemmaError(message: "The cache extends beyond or differs from the heard conversation.")
        }
        return Self.encode(messages.dropFirst(cached.messages.count))
    }

    func appending(userJSON: String, heardText: String) throws -> Self {
        guard let user = try JSONSerialization.jsonObject(with: Data(userJSON.utf8)) as? [String: Any],
              user["role"] as? String == "user", user["content"] != nil else {
            throw GemmaError(message: "The interrupted user turn is invalid.")
        }
        let assistant: [String: Any] = [
            "role": "assistant",
            "content": [["type": "text", "text": heardText]]
        ]
        var result = self
        result.messages.append(try JSONSerialization.data(withJSONObject: user, options: [.sortedKeys]))
        if !heardText.isEmpty {
            result.messages.append(try JSONSerialization.data(withJSONObject: assistant, options: [.sortedKeys]))
        }
        return result
    }

    var endsWithAssistant: Bool {
        guard let last = messages.last,
              let object = try? JSONSerialization.jsonObject(with: last) as? [String: Any] else { return false }
        return object["role"] as? String == "assistant"
    }

    var json: String { Self.encode(messages[...]) }

    private static func encode(_ messages: ArraySlice<Data>) -> String {
        "[" + messages.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]"
    }
}
