import Foundation
import os

enum AudioTrace {
    static let logger = Logger(subsystem: "CallGemma", category: "Pipeline")
    static let latency = LatencyTrace()
    static let signposter: OSSignposter = ProcessInfo.processInfo.environment["CALL_GEMMA_TRACE"] == "1"
        ? OSSignposter(subsystem: "CallGemma", category: "Audio") : .disabled
}

/// Numeric timing only: no speech, generated text, paths, or voice data.
/// High-frequency observations stay in bounded memory; disk I/O runs off-thread.
final class LatencyTrace: @unchecked Sendable {
    private struct Metric {
        var count = 0
        var total = 0.0
        var maximum = 0.0
        var recent: [Double] = []
        mutating func add(_ value: Double) {
            count += 1; total += value; maximum = max(maximum, value)
            if recent.count < 1024 { recent.append(value) }
            else { recent[(count - 1) % 1024] = value }
        }
        var summary: [String: Double] {
            let sorted = recent.sorted()
            return ["count": Double(count), "mean_ms": total / Double(max(1, count)),
                    "max_ms": maximum, "recent_p50_ms": sorted[sorted.count / 2],
                    "recent_p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]]
        }
    }
    private struct State {
        var metrics: [String: Metric] = [:]
        var events: [[String: String]] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let writer = DispatchQueue(label: "CallGemma.LatencyTrace", qos: .utility)
    private let run = UUID().uuidString
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func duration(_ name: String, since start: UInt64) {
        let end = Self.now()
        if end >= start { observe(name, milliseconds: Double(end - start) / 1_000_000) }
    }

    func observe(_ name: String, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        state.withLock { $0.metrics[name, default: Metric()].add(milliseconds) }
    }

    func mark(_ name: String, turn: UUID? = nil, at time: UInt64? = nil,
              counts: [String: Int] = [:]) {
        var event = counts.mapValues(String.init)
        event["event"] = name
        event["uptime_ns"] = String(time ?? Self.now())
        event["turn"] = turn?.uuidString ?? ""
        let recorded = event
        state.withLock {
            if $0.events.count == 256 { $0.events.removeFirst() }
            $0.events.append(recorded)
        }
    }

    func flush(_ reason: String) {
        let snapshot = state.withLock { current -> State in
            let snapshot = current
            current = State()
            return snapshot
        }
        // Serialize off the audio and UI threads. Retain at most two 2 MiB files.
        writer.async { [run] in
            do {
                let directory = AppQualificationEnvironment.root?.appending(path: "Diagnostics", directoryHint: .isDirectory)
                    ?? URL.applicationSupportDirectory.appending(path: "CallGemma/Diagnostics", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appending(path: "latency.jsonl")
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_097_152 {
                    let previous = directory.appending(path: "latency-previous.jsonl")
                    if FileManager.default.fileExists(atPath: previous.path) {
                        try FileManager.default.removeItem(at: previous)
                    }
                    try FileManager.default.moveItem(at: file, to: previous)
                }
                let record: [String: Any] = [
                    "schema": 1, "run": run, "reason": reason,
                    "output_muted": AutomatedAudioOutput.volume == 0,
                    "date": ISO8601DateFormatter().string(from: Date()),
                    "metrics": snapshot.metrics.mapValues(\.summary), "events": snapshot.events
                ]
                var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                data.append(10)
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                AudioTrace.logger.error("Latency receipt failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
