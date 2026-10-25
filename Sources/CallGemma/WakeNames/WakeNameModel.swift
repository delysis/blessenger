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

    /// Exact, unambiguous complete names beat the statistical head. Do not
    /// equate homophones (Ad/add/a), or select among multiple mentioned names.
    func recipient(_ decoded: String, roster: Set<UUID>) throws -> UUID? {
        try Self.recipient(decoded, names: names, roster: roster, classifier: classifier)
    }

    /// Complete decoded names do not depend on approximate-name enrollment.
    /// A missing/rejected trained head disables only its fuzzy fallback.
    static func recipient(_ decoded: String, names: [Name], roster: Set<UUID>,
                          classifier: WakeNameClassifier?) throws -> UUID? {
        let words = Self.words(decoded)
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
        let predicted = try classifier.prediction(decoded).label
        guard let id = UUID(uuidString: predicted), roster.contains(id),
              let name = names.first(where: { $0.id == id }), Self.words(name.name).joined().count >= 3 else { return nil }
        return id
    }
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }
}
