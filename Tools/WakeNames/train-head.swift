import Foundation

@main struct TrainWakeHead {
    struct Row: Decodable {
        let split: String
        let decoded: String
        let label: String
    }
    struct Score: Codable {
        var correctNames = 0
        var missedNames = 0
        var wrongNames = 0
        var falseActivations = 0
        var negatives = 0
    }
    static func score(_ rows: [Row], model: WakeNameClassifier) throws -> Score {
        var score = Score()
        for row in rows {
            let predicted = try model.prediction(row.decoded).label
            if row.label == "other" {
                score.negatives += 1
                if predicted != "other" { score.falseActivations += 1 }
            } else if predicted == row.label { score.correctNames += 1 }
            else if predicted == "other" { score.missedNames += 1 }
            else { score.wrongNames += 1 }
        }
        return score
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Usage: train-head TRAIN_VALIDATION_JSON TEST_JSON NEW_OUTPUT_DIRECTORY") }
        let output = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Preserve prior evidence; choose a new output") }
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let test = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        guard rows.allSatisfy({ ["train", "validation"].contains($0.split) }), test.allSatisfy({ $0.split == "test" }), !test.isEmpty else { fatalError("Invalid split") }
        let start = Date()
        let model = try WakeNameClassifier.train(rows.filter { $0.split == "train" }.map { .init(text: $0.decoded, label: $0.label) })
        let trainingSeconds = Date().timeIntervalSince(start)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try encoder.encode(model).write(to: output.appending(path: "head.json"), options: .atomic)
        let validation = try score(rows.filter { $0.split == "validation" }, model: model)
        let heldOut = try score(test, model: model)
        struct Receipt: Codable {
            let scope: String
            let trainingSeconds: Double
            let validation: Score
            let test: Score
            let appEnabled: Bool
        }
        let receipt = Receipt(scope: "Native CPU phonetic decoding and Swift logistic head; synthetic held-out voices only. No microphone, streaming-prefix or speaker-echo acceptance.", trainingSeconds: trainingSeconds, validation: validation, test: heldOut, appEnabled: false)
        let data = try encoder.encode(receipt)
        try data.write(to: output.appending(path: "receipt.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}
