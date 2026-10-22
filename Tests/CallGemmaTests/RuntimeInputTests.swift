import Foundation
import Testing
@testable import CallGemma

struct RuntimeInputTests {
    @Test func audioPathIsEncodedAsJSONWithoutChangingThePath() throws {
        let file = URL(fileURLWithPath: "/tmp/voice \"sample\" \\ café\n.wav")
        let json = try audioMessage(file)
        #expect(!json.utf8.contains(0))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["role"] as? String == "user")
        let content = try #require(object["content"] as? [[String: String]])
        #expect(content == [["type": "audio", "path": file.path]])
    }

    @Test func waveIsSixteenBitMonoWithClippedFiniteSamples() throws {
        let data = try WaveFile.encode(samples: [-2, -1, 0, 1, 2])
        #expect(data.count == 54)
        #expect(String(data: data[0..<4], encoding: .utf8) == "RIFF")
        #expect(String(data: data[8..<16], encoding: .utf8) == "WAVEfmt ")
        #expect(Array(data[20..<24]) == [1, 0, 1, 0])
        #expect(Array(data[24..<28]) == [0x80, 0x3e, 0, 0])
        #expect(Array(data[40..<44]) == [10, 0, 0, 0])
        #expect(Array(data[44...]) == [1, 128, 1, 128, 0, 0, 255, 127, 255, 127])
    }

    @Test func invalidOrUnboundedAudioIsRejected() {
        #expect(throws: GemmaError.self) { try WaveFile.encode(samples: []) }
        #expect(throws: GemmaError.self) { try WaveFile.encode(samples: [.nan]) }
        #expect(throws: GemmaError.self) { try WaveFile.encode(samples: [.infinity]) }
        #expect(throws: GemmaError.self) {
            try WaveFile.encode(samples: Array(repeating: 0, count: 480_001))
        }
    }

    @Test func onlyPublicTextContentIsSpoken() throws {
        let json = #"{"role":"assistant","content":[{"type":"text","text":"Hello "},{"type":"image","path":"ignored"},{"type":"text","text":"world."}],"channels":{"thought":"private chain"},"reasoning_content":"ignored"}"#
        #expect(try GeneratedText.decode(json) == "Hello world.")
        #expect(try GeneratedText.decode(#"{"channels":{"thought":"ignored"}}"#) == "")
        #expect(try GeneratedText.decode(#"{"content":"A direct answer."}"#) == "A direct answer.")
        #expect(throws: (any Error).self) { try GeneratedText.decode("not json") }
    }
}
