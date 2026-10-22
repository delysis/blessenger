import Foundation
import CreateML

// Offline native feasibility experiment; never installs a model in the app.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: train DATASET NEW_OUTPUT_DIRECTORY")
}
let dataset = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Output already exists") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let parameters = MLSoundClassifier.ModelParameters(
    validation: .dataSource(.labeledDirectories(at: dataset.appending(path: "validation"))),
    maxIterations: 100, overlapFactor: 0.5, featureExtractionTimeWindowSize: 4)
let start = Date()
let model = try MLSoundClassifier(trainingData: .labeledDirectories(at: dataset.appending(path: "train")), parameters: parameters)
let evaluation = model.evaluation(on: .labeledDirectories(at: dataset.appending(path: "test")))
try model.write(to: output.appending(path: "wake-names.mlmodel"))
let report: [String: Any] = [
    "scope": "Native Create ML feasibility test; synthetic held-out voices, not microphone acceptance",
    "elapsed_seconds": Date().timeIntervalSince(start),
    "parameters": String(describing: parameters),
    "training": String(describing: model.trainingMetrics),
    "validation": String(describing: model.validationMetrics),
    "test": String(describing: evaluation)
]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "receipt.json"), options: .atomic)
print(String(describing: evaluation))
