import CryptoKit
import Darwin
import Foundation
import Metal

struct RuntimeConfiguration: Codable, Equatable, Sendable {
    static let samplingTemperature: Float = 1.0
    static let samplingIdentity = "top-p:k=64,p=0.95,t=\(samplingTemperature),seed=0"

    let modelSHA256: String
    let modelRevision: String
    var runtimeSHA256: String
    let systemPrompt: String
    var contextTokens: Int
    let enableMTP: Bool
    let formatVersion: Int
    let backend: String
    let audioBackend: String
    let audioThreads: Int
    let maximumOutputTokens: Int
    let sampler: String
    let thinking: Bool
    let filterChannels: Bool
    let platform: String
    let metalDevice: String

    init(modelSHA256: String, modelRevision: String, runtimeSHA256: String,
         systemPrompt: String, contextTokens: Int, enableMTP: Bool) {
        self.modelSHA256 = modelSHA256
        self.modelRevision = modelRevision
        self.runtimeSHA256 = runtimeSHA256
        self.systemPrompt = systemPrompt
        self.contextTokens = contextTokens
        self.enableMTP = enableMTP
        formatVersion = 1
        backend = "gpu"
        audioBackend = "cpu"
        audioThreads = 2
        maximumOutputTokens = 256
        sampler = Self.samplingIdentity
        thinking = false
        filterChannels = false
        platform = ProcessInfo.processInfo.operatingSystemVersionString
        metalDevice = MTLCreateSystemDefaultDevice()?.name ?? "unavailable"
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func matchesIgnoringCapacity(_ other: Self) -> Bool {
        var copy = self
        copy.contextTokens = other.contextTokens
        return copy == other
    }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A generation is immutable. CURRENT is replaced only after both history and
/// the runtime's atomic KV write are durable. A crash cannot pair generations.
struct CheckpointStore: Sendable {
    struct Record: Codable, Sendable {
        let generation: UUID
        let configuration: RuntimeConfiguration
        let historySHA256: String
    }

    struct Snapshot: Sendable {
        let record: Record
        let stateURL: URL
        let historyJSON: String
        let key: String
    }

    let directory: URL

    func currentRecord() throws -> Record? {
        let pointer = directory.appending(path: "CURRENT")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let size = try pointer.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 64 * 1_024 else { throw CheckpointError.invalidMetadata }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: pointer))
    }

    func load(configuration: RuntimeConfiguration) throws -> Snapshot? {
        guard let record = try currentRecord(),
              record.configuration == configuration else { return nil }
        return try load(record: record)
    }

    /// Only CURRENT publishes its immutable retention manifest. Interrupted
    /// saves cannot add candidates, and retired branches are never scanned.
    private func predecessors(of record: Record) throws -> [Record] {
        let url = directory.appending(path: record.generation.uuidString + "/prefix-records.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 512 * 1024 else { throw CheckpointError.invalidMetadata }
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        guard records.count < 8, Set(records.map(\.generation)).count == records.count,
              !records.contains(where: { $0.generation == record.generation }) else { throw CheckpointError.invalidMetadata }
        return records
    }

    func longestPrefix(configuration: RuntimeConfiguration, canonical: ConversationHistory) throws -> Snapshot? {
        guard let current = try currentRecord() else { return nil }
        let records = try [current] + predecessors(of: current)
        var best: Snapshot?
        var bestCount = -1
        for record in records where record.configuration == configuration {
            let candidate = try load(record: record)
            let history = try ConversationHistory(json: candidate.historyJSON)
            if history.messages.count > bestCount, (try? canonical.suffix(after: history)) != nil {
                best = candidate
                bestCount = history.messages.count
                if bestCount == canonical.messages.count { return best }
            }
        }
        return best
    }

    private func load(record: Record) throws -> Snapshot {
        let generation = directory.appending(path: record.generation.uuidString, directoryHint: .isDirectory)
        let historyURL = generation.appending(path: "history.json")
        let size = try historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 16 * 1_024 * 1_024 else { throw CheckpointError.invalidMetadata }
        let data = try Data(contentsOf: historyURL)
        guard digest(data) == record.historySHA256,
              let history = String(data: data, encoding: .utf8),
              !history.utf8.contains(0) else { throw CheckpointError.invalidMetadata }
        return Snapshot(record: record, stateURL: generation.appending(path: "state.cache"),
                        historyJSON: history, key: try key(record.configuration, historySHA256: record.historySHA256))
    }

    /// Retire an exhausted conversation before replacing its live context.
    /// Old generation files are removed by the next successful save.
    func retire() throws {
        let pointer = directory.appending(path: "CURRENT")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return }
        try FileManager.default.removeItem(at: pointer)
        try syncDirectory(directory)
    }

    @discardableResult
    func save(configuration: RuntimeConfiguration, historyJSON: String,
              writeState: (URL, String) throws -> Void) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let record = Record(generation: UUID(), configuration: configuration,
                            historySHA256: digest(Data(historyJSON.utf8)))
        var retained: [Record] = []
        if let current = try currentRecord() {
            for old in try [current] + predecessors(of: current) {
                guard old.configuration == configuration, old.historySHA256 != record.historySHA256,
                      !retained.contains(where: { $0.historySHA256 == old.historySHA256 }) else { continue }
                retained.append(old)
                if retained.count == 7 { break }
            }
        }
        let generation = directory.appending(path: record.generation.uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: generation, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? manager.removeItem(at: generation) } }
        let historyStart = LatencyTrace.now()
        try durableWrite(Data(historyJSON.utf8), to: generation.appending(path: "history.json"))
        AudioTrace.latency.duration("checkpoint.history_durable_write", since: historyStart)
        let nativeStart = LatencyTrace.now()
        try writeState(generation.appending(path: "state.cache"),
                       key(configuration, historySHA256: record.historySHA256))
        AudioTrace.latency.duration("checkpoint.native_save", since: nativeStart)
        let publishStart = LatencyTrace.now()
        try durableWrite(JSONEncoder().encode(retained), to: generation.appending(path: "prefix-records.json"))
        try syncDirectory(generation)
        try durableWrite(JSONEncoder().encode(record), to: directory.appending(path: "CURRENT"))
        // Even if the directory sync fails, CURRENT may already be visible;
        // keep the referenced generation rather than creating a dangling link.
        published = true
        try syncDirectory(directory)
        AudioTrace.latency.duration("checkpoint.publish", since: publishStart)
        let retireStart = LatencyTrace.now()
        defer { AudioTrace.latency.duration("checkpoint.retire_old", since: retireStart) }
        let keep = Set(([record] + retained).map { $0.generation.uuidString })
        for old in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard !keep.contains(old.lastPathComponent),
                  UUID(uuidString: old.lastPathComponent) != nil else { continue }
            try? manager.removeItem(at: old)
        }
        return generation.appending(path: "state.cache")
    }

    private func key(_ configuration: RuntimeConfiguration, historySHA256: String) throws -> String {
        "CallGemma-v1:" + digest(try configuration.encoded()) + ":" + historySHA256
    }
}

enum CheckpointError: LocalizedError {
    case invalidMetadata
    case io(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "The saved conversation metadata is invalid. A new conversation is required."
        case .io(let code): return "Could not commit the conversation checkpoint: \(String(cString: strerror(code)))."
        }
    }
}

func durableWrite(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
        throw CheckpointError.io(errno)
    }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    } catch {
        try? handle.close()
        throw error
    }
    guard rename(temporary.path, destination.path) == 0 else { throw CheckpointError.io(errno) }
}

func syncDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { throw CheckpointError.io(errno) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CheckpointError.io(errno) }
}
