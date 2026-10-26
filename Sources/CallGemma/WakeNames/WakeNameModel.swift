import Foundation

struct WakeNameModel: Codable, Sendable {
    struct Name: Codable, Equatable, Sendable {
        let id: UUID
        let name: String
    }
    let fingerprint: String
    let names: [Name]
    let classifier: WakeNameClassifier
    let accepted: Bool

    /// Leading addresses take precedence over later mentions. Do not equate
    /// homophones (Ad/add/a), or select among coordinated addressees.
    func recipient(_ decoded: String, roster: Set<UUID>) throws -> UUID? {
        try Self.recipient(decoded, names: names, roster: roster, classifier: classifier)
    }

    /// Complete decoded names do not depend on approximate-name enrollment.
    /// A missing/rejected trained head disables only its fuzzy fallback.
    static func recipient(_ decoded: String, names: [Name], roster: Set<UUID>,
                          classifier: WakeNameClassifier?) throws -> UUID? {
        let words = Self.words(decoded)
        // A leading address owns the turn. A later, better-decoded mention
        // must not override it ("Gabor, what did Peter say?"). Resolve exact
        // and approximate spellings at the same position before looking ahead.
        let salutations: Set<String> = ["hey", "hi", "hello", "okay", "ok", "well", "please"]
        let start = words.firstIndex { !salutations.contains($0) } ?? words.count
        if start < words.count {
            let width = max(3, names.map { Self.words($0.name).count }.max() ?? 1)
            for count in 1...min(width, words.count - start) {
                let phrase = Array(words[start..<(start + count)])
                let exact = names.filter { Self.words($0.name) == phrase && phrase.joined().count >= 3 }
                var ids = Set(exact.map(\.id))
                if ids.isEmpty, let classifier,
                   let id = UUID(uuidString: try classifier.prediction(phrase.joined(separator: " "), searching: true).label),
                   names.contains(where: { $0.id == id }) { ids.insert(id) }
                if !ids.isEmpty {
                    guard ids.count == 1, let id = ids.first, roster.contains(id) else { return nil }
                    let next = start + count
                    if next < words.count, ["and", "or"].contains(words[next]) { return nil }
                    return id
                }
            }
        }
        let matches = names.filter { item in
            let target = Self.words(item.name)
            guard !target.isEmpty, target.joined().count >= 3, target.count <= words.count else { return false }
            return (0...(words.count - target.count)).contains { start in
                Array(words[start..<(start + target.count)]) == target
            }
        }
        if matches.count == 1 { return roster.contains(matches[0].id) ? matches[0].id : nil }
        if matches.count > 1 { return nil }
        guard let classifier else { return nil }
        var candidates = Set<UUID>()
        let whole = try classifier.prediction(decoded).label
        if let id = UUID(uuidString: whole), roster.contains(id), names.contains(where: { $0.id == id }) { candidates.insert(id) }
        let width = max(3, names.map { Self.words($0.name).count }.max() ?? 1)
        for start in words.indices {
            for count in 1...min(width, words.count - start) {
                let phrase = words[start..<(start + count)].joined(separator: " ")
                let predicted = try classifier.prediction(phrase, searching: true).label
                if let id = UUID(uuidString: predicted), roster.contains(id), names.contains(where: { $0.id == id }) {
                    candidates.insert(id)
                }
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }
}
