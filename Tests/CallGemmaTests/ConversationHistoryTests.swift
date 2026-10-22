import Testing
@testable import CallGemma

struct ConversationHistoryTests {
    @Test func rejectsCacheWithUnheardSuffix() throws {
        let empty = try ConversationHistory(json: "[]")
        let heard = try empty.appending(userJSON: #"{"role":"user","content":"Hi"}"#, heardText: "Hello")
        let generated = try empty.appending(userJSON: #"{"role":"user","content":"Hi"}"#,
                                            heardText: "Hello. Here is an unplayed sentence.")
        #expect(throws: GemmaError.self) { try heard.suffix(after: generated) }
        #expect(throws: GemmaError.self) { try empty.suffix(after: heard) }
    }

    @Test func keyOrderDoesNotInvalidatePrefix() throws {
        let a = try ConversationHistory(json: #"[{"role":"user","content":"Hi"},{"role":"assistant","content":"Hello"}]"#)
        let b = try ConversationHistory(json: #"[{"content":"Hi","role":"user"},{"content":"Hello","role":"assistant"}]"#)
        #expect(try a.suffix(after: b) == "[]")
    }

    @Test func unansweredUserHasNoInventedAssistant() throws {
        let empty = try ConversationHistory(json: "[]")
        let first = try empty.appending(userJSON: #"{"role":"user","content":"First"}"#, heardText: "Yes")
        let interrupted = try first.appending(userJSON: #"{"role":"user","content":"Second"}"#, heardText: "")
        let suffix = try ConversationHistory(json: interrupted.suffix(after: first))
        #expect(suffix.messages.count == 1)
        #expect(!suffix.json.contains("assistant"))
        #expect(try ConversationHistory(json: interrupted.json) == interrupted)
    }

    @Test func continuedUserSpeechPreservesOrder() throws {
        let first = try ConversationHistory(json: #"[{"role":"user","content":"First clause"}]"#)
        let continued = try first.appending(userJSON: #"{"role":"user","content":"Second clause"}"#, heardText: "Reply")
        #expect(continued.messages.count == 3)
        #expect(!first.endsWithAssistant)
        #expect(continued.endsWithAssistant)
        #expect(try ConversationHistory(json: continued.json) == continued)
        #expect(throws: GemmaError.self) {
            try ConversationHistory(json: #"[{"role":"assistant","content":"Unprompted"}]"#)
        }
        #expect(throws: GemmaError.self) {
            try ConversationHistory(json: #"[{"role":"user","content":"Hi"},{"role":"assistant","content":"One"},{"role":"assistant","content":"Two"}]"#)
        }
    }
}
