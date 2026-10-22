import Foundation

/// Keeps partial punctuation across token callbacks; bounds even unpunctuated text.
struct SentenceBuffer {
    private var pending = ""
    private let limit = 240
    private var emittedFirst = false
    private let eagerFirstClause: Bool

    init(eagerFirstClause: Bool = ProcessInfo.processInfo.environment["CALL_GEMMA_EAGER_FIRST_CLAUSE"] != "0") {
        self.eagerFirstClause = eagerFirstClause
    }
    private let abbreviations = Set(["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "vs", "etc"])

    mutating func append(_ delta: String) -> [String] {
        pending += delta
        var sentences: [String] = []
        while let end = nextBoundary() {
            let sentence = String(pending[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(..<end)
            if !sentence.isEmpty { sentences.append(sentence); emittedFirst = true }
        }
        return sentences
    }

    mutating func finish() -> String? {
        let remaining = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return remaining.isEmpty ? nil : remaining
    }

    private func nextBoundary() -> String.Index? {
        let scalars = pending.unicodeScalars
        var count = 0
        var lastSpace: String.Index?
        var hasWord = false
        for index in scalars.indices {
            count += 1
            let value = scalars[index]
            let next = scalars.index(after: index)
            if CharacterSet.alphanumerics.contains(value) { hasWord = true }
            if CharacterSet.whitespacesAndNewlines.contains(value), count >= limit / 2 {
                lastSpace = next
            }
            if value == "\n" { return next }
            let clause = !emittedFirst && hasWord && ",;:".unicodeScalars.contains(value)
            // A first clause ending in a comma/semicolon after a word is ready
            // now. Do not await another decoder callback just for whitespace.
            // Keep numeric separators, colons, periods/abbreviations and closing
            // quotes on the existing look-ahead path.
            if eagerFirstClause, !emittedFirst, next == scalars.endIndex,
               value == "," || value == ";", index > scalars.startIndex,
               CharacterSet.letters.contains(scalars[scalars.index(before: index)]) {
                return next
            }
            if (".!?".unicodeScalars.contains(value) || clause), next < scalars.endIndex {
                var after = next
                while after < scalars.endIndex && "\"'”’)]".unicodeScalars.contains(scalars[after]) {
                    after = scalars.index(after: after)
                }
                if after < scalars.endIndex && CharacterSet.whitespacesAndNewlines.contains(scalars[after]) {
                    let prefix = pending[..<index].split(whereSeparator: { $0.isWhitespace }).last ?? ""
                    if !(value == "." && abbreviations.contains(prefix.lowercased())) {
                        return after
                    }
                }
            }
            if count >= limit { return lastSpace ?? next }
        }
        return nil
    }
}

/// One producer, one consumer. Backpressure keeps at most eight sentences ahead.
actor SentenceQueue {
    private let capacity: Int
    private var values: [String] = []
    private var reader: CheckedContinuation<String?, Error>?
    private var writer: (String, CheckedContinuation<Void, Error>)?
    private var finished = false
    private var failure: Error?

    init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    func send(_ value: String) async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard !finished else { throw CancellationError() }
        if let reader {
            self.reader = nil
            reader.resume(returning: value)
        } else if values.count < capacity {
            values.append(value)
        } else {
            guard writer == nil else { throw CallAudioError.concurrentProducer }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { writer = (value, $0) }
            } onCancel: {
                Task { await self.cancel() }
            }
        }
    }

    func next() async throws -> String? {
        try Task.checkCancellation()
        if let failure { throw failure }
        if !values.isEmpty {
            let value = values.removeFirst()
            if let writer {
                self.writer = nil
                values.append(writer.0)
                writer.1.resume()
            }
            return value
        }
        if finished { return nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reader = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func finish() {
        finished = true
        reader?.resume(returning: nil)
        reader = nil
    }

    func cancel(_ error: Error = CancellationError()) {
        failure = error
        finished = true
        values.removeAll()
        reader?.resume(throwing: error)
        writer?.1.resume(throwing: error)
        reader = nil
        writer = nil
    }
}
