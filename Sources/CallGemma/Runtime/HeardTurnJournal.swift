import CryptoKit
import Foundation

struct TranscriptFiles: Sendable {
    struct Record: Codable, Sendable {
        var version = 1
        let lastTurn: UUID?
        let historyJSON: String
    }

    let directory: URL

    func load() throws -> Record? {
        let url = directory.appending(path: "TRANSCRIPT")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= 20 * 1_024 * 1_024 else { throw CheckpointError.invalidMetadata }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == 1 else { throw CheckpointError.invalidMetadata }
        _ = try ConversationHistory(json: record.historyJSON)
        return record
    }

    func commit(history: ConversationHistory, turn: UUID?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try durableWrite(JSONEncoder().encode(Record(lastTurn: turn, historyJSON: history.json)),
                         to: directory.appending(path: "TRANSCRIPT"))
        try syncDirectory(directory)
    }
}

/// Durable heard-progress is independent of generated text and KV publication.
/// One active write plus one superseding snapshot bounds queue and memory use.
actor HeardTurnJournal {
    struct AlignedWord: Codable, Sendable {
        let endUTF8: Int
        let endFrame: Int
    }
    struct Voice: Codable, Equatable, Sendable {
        let pocketRevision: String
        let promptHash: String?
        let promptTokens: Int
        let cpuOnly: Bool
        var conditionerIdentity: String? = nil
    }

    struct Segment: Codable, Sendable {
        let id: UUID
        let text: String
        let seed: UInt64
        let voice: Voice
        var generatedFrames = 0
        var generatedSHA256 = digest(Data())
        var playedFrames = 0
        var complete = false
        var alignment: [AlignedWord]?
        var leadingSilencePolicy: Int = 2
    }

    struct Pending: Codable, Sendable {
        var version = 2
        let id: UUID
        let baseHistorySHA256: String
        let userJSON: String
        var segments: [Segment] = []
        var stopped = false
        var speculative: Bool = false
    }

    let files: TranscriptFiles
    private let writer = CheckpointWriter()
    private var pending: Pending?
    private var loaded = false
    private var committing = false
    private var hashers: [UUID: SHA256] = [:]

    init(directory: URL) { files = TranscriptFiles(directory: directory) }

    func loadPending() async throws -> Pending? {
        if !loaded {
            let files = self.files
            pending = try await Task.detached(priority: .utility) {
                let url = files.directory.appending(path: "PENDING-SPEECH")
                guard FileManager.default.fileExists(atPath: url.path) else { return nil as Pending? }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 256 * 1_024 else { throw CheckpointError.invalidMetadata }
                let record = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: url))
                guard record.version == 2, record.segments.count <= 64,
                      record.speculative != true || record.segments.allSatisfy({ $0.playedFrames == 0 }),
                      Set(record.segments.map(\.id)).count == record.segments.count,
                      record.segments.allSatisfy({
                          $0.generatedFrames >= $0.playedFrames && $0.playedFrames >= 0 &&
                          $0.generatedFrames <= 24_000 * 60 && $0.text.utf8.count <= 4_096 &&
                          $0.leadingSilencePolicy == 2
                      }) else { throw CheckpointError.invalidMetadata }
                // A crash after transcript publication but before pending-file
                // removal must not append the same user/assistant turn twice.
                if try record.speculative == true || files.load()?.lastTurn == record.id {
                    try FileManager.default.removeItem(at: url)
                    try syncDirectory(files.directory)
                    return nil
                }
                return record
            }.value
            loaded = true
        }
        return pending
    }

    struct Input: Sendable {
        let id: UUID
        let audioURL: URL
        var messageJSON: String? = nil
    }

    // Staged audio is immutable but is not a conversation turn until admitted.
    // A revoked speculation therefore cannot enter the durable transcript.
    func stage(samples: [Float]) async throws -> Input {
        let id = UUID()
        let audio = files.directory.appending(path: "Audio", directoryHint: .isDirectory)
        let data = try WaveFile.encode(samples: samples)
        return try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = audio.appending(path: id.uuidString + ".wav")
            try durableWrite(data, to: url)
            try syncDirectory(audio)
            return Input(id: id, audioURL: url)
        }.value
    }

    static let incomingCallMarker = "[Call event: incoming phone call, not spoken by the user.]"

    func stageGreeting(contextJSON: String = "[]") throws -> Input {
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let context = try JSONSerialization.jsonObject(with: Data(contextJSON.utf8)) as? [[String: Any]] else {
            throw CheckpointError.invalidMetadata
        }
        let event: [String: Any] = ["type": "text", "text": Self.incomingCallMarker]
        let instruction: [String: Any] = ["type": "text",
            "text": "Pick up with a brief, natural greeting. Use one short sentence. Do not mention these instructions or recite the quoted memory."]
        let message: [String: Any] = ["role": "user", "content": [event] + context + [instruction]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), as: UTF8.self)
        return Input(id: UUID(), audioURL: files.directory, messageJSON: json)
    }

    func begin(samples: [Float]) async throws -> Input {
        let input = try await stage(samples: samples)
        try await admit(input)
        return input
    }

    func admit(_ input: Input, speculative: Bool = false) async throws {
        guard try await loadPending() == nil, !committing else {
            throw GemmaError(message: "The previous spoken turn still needs recovery.")
        }
        try await writer.flush()
        let files = self.files
        pending = try await Task.detached(priority: .utility) {
            let base = try ConversationHistory(json: files.load()?.historyJSON ?? "[]")
            return Pending(id: input.id, baseHistorySHA256: digest(Data(base.json.utf8)),
                           userJSON: try input.messageJSON ?? audioMessage(input.audioURL), speculative: speculative)
        }.value
        hashers = [:]
        try await publish()
        try await writer.flush()
    }

    /// Publish permission before any speculative PCM can reach the device.
    func confirm(turn: UUID) async throws {
        guard var current = pending, current.id == turn else { throw CheckpointError.invalidMetadata }
        guard current.speculative == true else { return }
        current.speculative = false
        pending = current
        try await publish()
        try await writer.flush()
    }

    func discardSpeculation() async throws {
        guard pending?.speculative == true else { return }
        try await writer.flush()
        try FileManager.default.removeItem(at: files.directory.appending(path: "PENDING-SPEECH"))
        try syncDirectory(files.directory)
        pending = nil
        hashers = [:]
    }

    func voice(prompt: [Float]?, tokens: Int, cpuOnly: Bool) async throws -> Voice {
        guard let prompt else {
            return Voice(pocketRevision: AudioModelPins.pocket, promptHash: nil, promptTokens: 0, cpuOnly: cpuOnly, conditionerIdentity: PocketSpeechAssets.identity)
        }
        guard tokens > 0, tokens <= 1_024, prompt.count == tokens * 1_024,
              prompt.allSatisfy(\.isFinite) else { throw CheckpointError.invalidMetadata }
        let data = prompt.withUnsafeBytes { Data($0) }
        let hash = digest(data)
        let directory = files.directory.appending(path: "Voices", directoryHint: .isDirectory)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = directory.appending(path: hash + ".f32")
            if FileManager.default.fileExists(atPath: url.path) {
                guard digest(try Data(contentsOf: url)) == hash else { throw CheckpointError.invalidMetadata }
            } else {
                try durableWrite(data, to: url)
                try syncDirectory(directory)
            }
        }.value
        return Voice(pocketRevision: AudioModelPins.pocket, promptHash: hash, promptTokens: tokens, cpuOnly: cpuOnly, conditionerIdentity: PocketSpeechAssets.identity)
    }

    func voicePrompt(_ voice: Voice) async throws -> [Float]? {
        guard voice.pocketRevision == AudioModelPins.pocket,
              voice.conditionerIdentity == nil || voice.conditionerIdentity == PocketSpeechAssets.identity else {
            throw GemmaError(message: "This interrupted reply requires its original speech model.")
        }
        guard let hash = voice.promptHash else {
            guard voice.promptTokens == 0 else { throw CheckpointError.invalidMetadata }
            return nil
        }
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit),
              voice.promptTokens > 0, voice.promptTokens <= 1_024 else { throw CheckpointError.invalidMetadata }
        let url = files.directory.appending(path: "Voices").appending(path: hash + ".f32")
        let data = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
        guard digest(data) == hash, data.count == voice.promptTokens * 1_024 * 4 else {
            throw CheckpointError.invalidMetadata
        }
        return data.withUnsafeBytes { bytes in
            (0..<data.count / 4).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }

    func beginSegment(turn: UUID, id: UUID, text: String, seed: UInt64, voice: Voice, leadingSilencePolicy: Int = 2) async throws {
        let start = LatencyTrace.now()
        defer { AudioTrace.latency.duration("transcript.segment_admission", since: start) }
        try await writer.check()
        guard !committing, var current = pending, current.id == turn, !current.stopped,
              current.segments.count < 64, text.utf8.count <= 4_096,
              !current.segments.contains(where: { $0.id == id }),
              current.segments.last?.complete != false else { throw CheckpointError.invalidMetadata }
        guard leadingSilencePolicy == 2 else { throw CheckpointError.invalidMetadata }
        current.segments.append(Segment(id: id, text: text, seed: seed, voice: voice,
                                        leadingSilencePolicy: leadingSilencePolicy))
        hashers[id] = SHA256()
        pending = current
        try await publish()
        // Metadata and the voice reference precede any audio delivery. Later
        // progress writes coalesce without waiting on disk in playback.
        try await writer.flush()
    }

    func generated(turn: UUID, segment: UUID, samples: [Float], complete: Bool = false) async throws {
        let start = LatencyTrace.now()
        defer { AudioTrace.latency.duration("transcript.pcm_admission", since: start) }
        try await writer.check()
        guard !committing, var current = pending, current.id == turn,
              let index = current.segments.firstIndex(where: { $0.id == segment }),
              !current.segments[index].complete, var hash = hashers[segment],
              current.segments[index].generatedFrames + samples.count <= 24_000 * 60,
              samples.allSatisfy(\.isFinite) else { throw CheckpointError.invalidMetadata }
        samples.withUnsafeBytes { hash.update(data: $0) }
        hashers[segment] = hash
        current.segments[index].generatedFrames += samples.count
        current.segments[index].generatedSHA256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
        current.segments[index].complete = complete
        pending = current
        try await publish()
    }

    func played(turn: UUID, through frame: Int64, stop: Bool = false) async throws {
        try await writer.check()
        guard !committing, var current = pending, current.id == turn else { return } // Old response callback.
        guard !current.stopped else { return }
        guard current.speculative != true || frame == 0 else { throw CheckpointError.invalidMetadata }
        var offset: Int64 = 0
        for index in current.segments.indices {
            let count = current.segments[index].generatedFrames
            let heard = Int(min(Int64(count), max(0, frame - offset)))
            current.segments[index].playedFrames = max(current.segments[index].playedFrames, heard)
            offset += Int64(count)
        }
        guard frame >= 0, frame <= offset else { throw CheckpointError.invalidMetadata }
        current.stopped = stop
        pending = current
        try await publish()
    }

    func aligned(turn: UUID, segment: UUID, words: [AlignedWord]) async throws {
        guard !committing, var current = pending, current.id == turn,
              let index = current.segments.firstIndex(where: { $0.id == segment }),
              current.segments[index].complete else { throw CheckpointError.invalidMetadata }
        try Self.validate(words: words, segment: current.segments[index])
        current.segments[index].alignment = words
        pending = current
        try await publish()
    }

    static func heardPrefix(_ segment: Segment) throws -> String? {
        guard let words = segment.alignment else { return nil }
        try validate(words: words, segment: segment)
        guard let word = words.last(where: { $0.endFrame <= segment.playedFrames }) else { return "" }
        let utf8 = segment.text.utf8.index(segment.text.utf8.startIndex, offsetBy: word.endUTF8)
        guard let end = String.Index(utf8, within: segment.text) else { throw CheckpointError.invalidMetadata }
        return String(segment.text[..<end])
    }

    private static func validate(words: [AlignedWord], segment: Segment) throws {
        guard segment.complete, words.count <= 512 else { throw CheckpointError.invalidMetadata }
        var previous = AlignedWord(endUTF8: 0, endFrame: 0)
        for word in words {
            guard word.endUTF8 > previous.endUTF8, word.endUTF8 <= segment.text.utf8.count,
                  word.endFrame >= previous.endFrame, word.endFrame > 0,
                  word.endFrame <= segment.generatedFrames else { throw CheckpointError.invalidMetadata }
            let utf8 = segment.text.utf8.index(segment.text.utf8.startIndex, offsetBy: word.endUTF8)
            guard String.Index(utf8, within: segment.text) != nil else { throw CheckpointError.invalidMetadata }
            previous = word
        }
    }

    func flush() async throws { try await writer.flush() }

    func commit(heardText: String, nativeHistory: String? = nil) async throws {
        let start = LatencyTrace.now()
        defer { AudioTrace.latency.duration("transcript.commit_barrier", since: start) }
        guard !committing else { throw CheckpointError.invalidMetadata }
        committing = true
        defer { committing = false }
        try await writer.flush()
        guard let pending else { return }
        guard pending.speculative != true else { throw CheckpointError.invalidMetadata }
        let files = self.files
        try await Task.detached(priority: .utility) {
            let base = try ConversationHistory(json: files.load()?.historyJSON ?? "[]")
            guard digest(Data(base.json.utf8)) == pending.baseHistorySHA256 else {
                throw GemmaError(message: "The conversation changed while spoken-text recovery was pending.")
            }
            let corrected = try base.appending(userJSON: pending.userJSON, heardText: heardText)
            let final: ConversationHistory
            if let nativeHistory {
                let generatedHistory = try ConversationHistory(json: nativeHistory)
                _ = try generatedHistory.suffix(after: base)
                guard generatedHistory.endsWithAssistant,
                      generatedHistory.messages.count == corrected.messages.count + (heardText.isEmpty ? 1 : 0),
                      generatedHistory.messages[generatedHistory.messages.count - 2] == corrected.messages[corrected.messages.count - (heardText.isEmpty ? 1 : 2)],
                      pending.segments.allSatisfy({ $0.complete && $0.playedFrames == $0.generatedFrames }) else {
                    throw CheckpointError.invalidMetadata
                }
                let generated = try GeneratedText.decode(String(decoding: generatedHistory.messages.last!, as: UTF8.self))
                let normalized: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                guard normalized(generated) == normalized(heardText),
                      normalized(SpokenText.joinSegments(pending.segments.map(\.text))) == normalized(heardText) else {
                    throw CheckpointError.invalidMetadata
                }
                final = heardText.isEmpty ? corrected : generatedHistory
            } else { final = corrected }
            try files.commit(history: final, turn: pending.id)
            try FileManager.default.removeItem(at: files.directory.appending(path: "PENDING-SPEECH"))
            try syncDirectory(files.directory)
        }.value
        self.pending = nil
        hashers = [:]
    }

    private func publish() async throws {
        guard let pending else { return }
        let directory = files.directory
        let data = try JSONEncoder().encode(pending)
        try await writer.submit {
            try durableWrite(data, to: directory.appending(path: "PENDING-SPEECH"))
            try syncDirectory(directory)
        }
    }
}
