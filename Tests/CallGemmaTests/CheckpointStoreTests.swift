import Foundation
import XCTest
@testable import CallGemma

final class CheckpointStoreTests: XCTestCase {
    private func configuration(prompt: String = "Answer briefly.", capacity: Int = 4_096) -> RuntimeConfiguration {
        RuntimeConfiguration(modelSHA256: String(repeating: "1", count: 64), modelRevision: "model-revision",
                             runtimeSHA256: String(repeating: "2", count: 64), systemPrompt: prompt,
                             contextTokens: capacity, enableMTP: true)
    }

    func testLongestPublishedPrefixAcrossBranchesAndBoundedRetention() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CheckpointStore(directory: folder)
        let config = configuration()
        let empty = try ConversationHistory(json: "[]")
        func append(_ base: ConversationHistory, _ text: String) throws -> ConversationHistory {
            try base.appending(userJSON: #"{"role":"user","content":"question"}"#, heardText: text)
        }
        func save(_ history: ConversationHistory) throws {
            try store.save(configuration: config, historyJSON: history.json) { url, _ in try Data([1]).write(to: url) }
        }
        let one = try append(empty, "one")
        let two = try append(one, "two")
        let three = try append(two, "three")
        try save(one); try save(two); try save(three)
        let divergent = try append(two, "replacement")
        XCTAssertEqual(try store.longestPrefix(configuration: config, canonical: divergent)?.historyJSON, two.json)
        XCTAssertEqual(try store.longestPrefix(configuration: config, canonical: one)?.historyJSON, one.json)
        XCTAssertNil(try store.longestPrefix(configuration: config, canonical: empty))
        XCTAssertNil(try store.longestPrefix(configuration: configuration(prompt: "Other"), canonical: three))
        try save(divergent)
        XCTAssertEqual(try store.longestPrefix(configuration: config, canonical: three)?.historyJSON, three.json)
        var extended = divergent
        for i in 0..<12 { extended = try append(extended, "new \(i)"); try save(extended) }
        let generations = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(generations.count, 8)
        XCTAssertEqual(try store.longestPrefix(configuration: config, canonical: extended)?.historyJSON, extended.json)
        try store.retire()
        XCTAssertNil(try store.longestPrefix(configuration: config, canonical: extended))
    }

    func testCorruptPublishedCandidateIsNotSilentlySkipped() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CheckpointStore(directory: folder)
        let config = configuration()
        let one = try ConversationHistory(json: "[]").appending(userJSON: #"{"role":"user","content":"one"}"#, heardText: "one")
        try store.save(configuration: config, historyJSON: one.json) { url, _ in try Data([1]).write(to: url) }
        let first = try XCTUnwrap(store.currentRecord())
        let two = try one.appending(userJSON: #"{"role":"user","content":"two"}"#, heardText: "two")
        try store.save(configuration: config, historyJSON: two.json) { url, _ in try Data([2]).write(to: url) }
        try Data("corrupt".utf8).write(to: folder.appending(path: first.generation.uuidString + "/history.json"))
        XCTAssertThrowsError(try store.longestPrefix(configuration: config, canonical: one))
    }

    func testRuntimeIdentityMustMatchExactly() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CheckpointStore(directory: folder)
        let old = configuration()
        var new = old
        new.runtimeSHA256 = String(repeating: "3", count: 64)
        var writtenKey = ""
        try store.save(configuration: old, historyJSON: "history") { url, key in
            writtenKey = key
            try Data([1]).write(to: url)
        }
        XCTAssertNil(try store.load(configuration: new))
        let restored = try XCTUnwrap(store.load(configuration: old))
        XCTAssertEqual(restored.key, writtenKey)
        XCTAssertEqual(restored.record.configuration, old)
        var wrong = configuration(prompt: "Changed")
        wrong.runtimeSHA256 = new.runtimeSHA256
        XCTAssertNil(try store.load(configuration: wrong))
    }

    func testFailedStateWriteKeepsLastCompleteGeneration() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CheckpointStore(directory: folder)
        let config = configuration()
        let oldHistory = "[{\"role\":\"assistant\",\"content\":\"old\"}]"
        try store.save(configuration: config, historyJSON: oldHistory) { url, _ in
            try Data("old-state".utf8).write(to: url)
        }
        let old = try XCTUnwrap(store.load(configuration: config))
        XCTAssertThrowsError(try store.save(configuration: config, historyJSON: "new-history") { url, _ in
            try Data("partial-state".utf8).write(to: url)
            throw CocoaError(.fileWriteOutOfSpace)
        })
        let restored = try XCTUnwrap(store.load(configuration: config))
        XCTAssertEqual(restored.record.generation, old.record.generation)
        XCTAssertEqual(restored.historyJSON, oldHistory)
        XCTAssertEqual(try Data(contentsOf: restored.stateURL), Data("old-state".utf8))
        let directories = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(directories.count, 1)
    }

    func testHistoryAndEveryConfigurationChangeBindTheStateKey() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CheckpointStore(directory: folder)
        let config = configuration()
        var keys: [String] = []
        for history in ["first", "second"] {
            try store.save(configuration: config, historyJSON: history) { url, key in
                keys.append(key)
                try Data([1]).write(to: url)
            }
        }
        XCTAssertNotEqual(keys[0], keys[1])
        XCTAssertNil(try store.load(configuration: configuration(prompt: "Another prompt.")))
        XCTAssertNil(try store.load(configuration: configuration(capacity: 4_092)))
        let snapshot = try XCTUnwrap(store.load(configuration: config))
        try Data("modified".utf8).write(to: snapshot.stateURL.deletingLastPathComponent().appending(path: "history.json"))
        XCTAssertThrowsError(try store.load(configuration: config))
    }

    func testSavedFormatAndSettingsAreDecodedInsteadOfReplacedWithDefaults() throws {
        let original = configuration()
        let json = String(decoding: try original.encoded(), as: UTF8.self)
        let changed = json.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2")
        let decoded = try JSONDecoder().decode(RuntimeConfiguration.self, from: Data(changed.utf8))
        XCTAssertEqual(decoded.formatVersion, 2)
        XCTAssertFalse(original.matchesIgnoringCapacity(decoded))
        XCTAssertTrue(original.matchesIgnoringCapacity(configuration(capacity: 2_048)))
    }

    func testRetiredFullConversationCannotBeRestoredOnRestart() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CheckpointStore(directory: folder)
        let config = configuration()
        try store.save(configuration: config, historyJSON: "completed-history") { url, _ in
            try Data([1]).write(to: url)
        }
        try store.retire()
        let restarted = CheckpointStore(directory: folder)
        XCTAssertNil(try restarted.load(configuration: config))
        XCTAssertNoThrow(try restarted.retire())
    }
}
