import Foundation
import AVFoundation
import CoreML

// Read-only evaluation of the same pinned phonetic model used for alignment.
// Never installs a detector or changes call routing.
let args = CommandLine.arguments
guard args.count == 5, ["train-validation", "test"].contains(args[4]) else { fatalError("Usage: phonetic-probe MODEL DATASET OUTPUT train-validation|test") }
guard !FileManager.default.fileExists(atPath: args[3]) else { fatalError("Preserve prior evidence; choose a new output") }
let root = URL(fileURLWithPath: args[2])
let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuOnly
let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: args[1]))
defer { try? FileManager.default.removeItem(at: compiled) }
let model = try MLModel(contentsOf: compiled, configuration: configuration)
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "manifest.json"))) as! [[String: Any]]
let labels = Array("    |ETAONIHSRDLUMWCFGYPBVK'XJQZ")
var rows: [[String: Any]] = []
for entry in manifest {
    let split = entry["split"] as! String
    guard args[4] == "test" ? split == "test" : (split == "validation" || (split == "train" && (entry["path"] as! String).hasSuffix("-0.wav"))) else { continue }
    let url = root.appending(path: entry["path"] as! String)
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { fatalError("Invalid input") }
    try file.read(into: buffer)
    let count = Int(buffer.frameLength)
    let waveform = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .float32)
    waveform.dataPointer.assumingMemoryBound(to: Float.self).update(from: buffer.floatChannelData![0], count: count)
    let start = ContinuousClock.now
    let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": waveform]))
    let duration = start.duration(to: .now)
    let emissions = output.featureValue(for: "emissions")!.multiArrayValue!
    var text = "", last = -1
    for frame in 0..<emissions.shape[1].intValue {
        let best = (0..<32).max { emissions[[0, NSNumber(value: frame), NSNumber(value: $0)]].floatValue < emissions[[0, NSNumber(value: frame), NSNumber(value: $1)]].floatValue }!
        if best != last, best >= 4 { text.append(labels[best]) }
        last = best
    }
    rows.append(["split": entry["split"]!, "path": entry["path"]!, "expected": entry["text"]!, "label": entry["label"]!, "decoded": text.replacingOccurrences(of: "|", with: " "), "seconds": Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18])
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    print("\(rows.count) \(text) \(duration)")
}
