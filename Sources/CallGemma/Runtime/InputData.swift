import Foundation

struct GemmaError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

func audioMessage(_ file: URL) throws -> String {
    // Preserve the original app's spoken-turn contract alongside the untouched
    // persona prompt. Use the same message for prefill, generation and journaling.
    let message: [String: Any] = ["role": "user", "content": [
        ["type": "text", "text": "[Phone call] Reply naturally in at most two short sentences. No headings, lists, preamble, or extended explanation."],
        ["type": "audio", "path": file.path]
    ]]
    return String(decoding: try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), as: UTF8.self)
}

enum GeneratedText {
    static func decode(_ json: String) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw GemmaError(message: "Gemma returned invalid conversation JSON.")
        }
        // Channel/tool payloads are never spoken. The model processor supplies
        // ordinary response text under content, separately from reasoning.
        if let text = object["content"] as? String { return text }
        guard let parts = object["content"] as? [[String: Any]] else { return "" }
        return parts.compactMap { part in
            part["type"] as? String == "text" ? part["text"] as? String : nil
        }.joined()
    }
}

enum WaveFile {
    static func encode(samples: [Float]) throws -> Data {
        guard !samples.isEmpty, samples.count <= 30 * 16_000, samples.allSatisfy(\.isFinite) else {
            throw GemmaError(message: "The captured utterance is invalid or longer than 30 seconds.")
        }
        var data = Data()
        data.reserveCapacity(44 + samples.count * 2)
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(16_000))
        data.appendLittleEndian(UInt32(32_000))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(samples.count * 2))
        for sample in samples {
            data.appendLittleEndian(Int16((max(-1, min(1, sample)) * 32_767).rounded()))
        }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
