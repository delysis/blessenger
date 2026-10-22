@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import CallGemma

/// Uses Apple's real file decoder and FluidAudio's converter; no models are loaded.
struct VoiceSampleTests {
    @Test func wavImportStopsAtTenSeconds() throws {
        try withAudioFile(frameCount: 276_000) { url in
            let samples = try VoiceSample.read(from: url)
            #expect(samples.count == 240_000)
            #expect(samples.allSatisfy { $0 == 0.25 })
        }
    }

    @Test func shortAACImportKeepsItsDecodablePrefix() throws {
        try withAudioFile(frameCount: 66_150, sampleRate: 44_100, compressed: true) { url in
            let samples = try VoiceSample.read(from: url)
            // AAC padding and a rejected final packet can change the exact tail.
            #expect((32_000...40_000).contains(samples.count))
            #expect(samples.allSatisfy { $0.isFinite })
            #expect(samples.contains { abs($0) > 0.01 })
        }
    }

    @Test func subsecondSampleIsRejected() throws {
        try withAudioFile(frameCount: 12_000) { url in
            #expect(throws: CallAudioError.self) { try VoiceSample.read(from: url) }
        }
    }

    @Test func nonfinitePCMIsRejected() throws {
        try withAudioFile(frameCount: 36_000, invalidSample: .nan) { url in
            #expect(throws: CallAudioError.self) { try VoiceSample.read(from: url) }
        }
    }

    @Test func largeFileSelectionSeeksAndExportsOnlyChosenInterval() throws {
        try withAudioFile(frameCount: 6_000_000) { url in
            #expect((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 20 * 1_024 * 1_024)
            let selected = try VoiceSample.read(from: url, start: 120, duration: 2)
            #expect(selected.count == 48_000)
            #expect(selected.allSatisfy { $0 == -0.75 })
            let output = url.deletingLastPathComponent().appending(path: "selection.wav")
            try VoiceSample.export(from: url, start: 120, duration: 2, to: output)
            #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 250_000)
            #expect(try VoiceSample.read(from: output) == selected)
        }
    }

    @Test func selectionBoundsAreEnforced() throws {
        try withAudioFile(frameCount: 72_000) { url in
            for (start, duration) in [(-1.0, 2.0), (0, 11), (0, 0.5), (10, 2), (.nan, 2), (0, .infinity)] {
                #expect(throws: CallAudioError.self) { try VoiceSample.read(from: url, start: start, duration: duration) }
            }
        }
    }

    private func withAudioFile(frameCount: Int, sampleRate: Double = 24_000,
                               compressed: Bool = false, invalidSample: Float? = nil,
                               _ check: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(compressed ? "sample.m4a" : "sample.wav")
        try autoreleasepool {
            let settings: [String: Any] = compressed ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
            ] : [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                     frameCapacity: AVAudioFrameCount(frameCount)))
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let channel = try #require(buffer.floatChannelData?[0])
            for index in 0..<frameCount {
                channel[index] = compressed ? Float(sin(2 * .pi * 440 * Double(index) / sampleRate)) * 0.25
                    : (index < Int(sampleRate * 10) ? 0.25 : -0.75)
            }
            if let invalidSample { channel[frameCount / 2] = invalidSample }
            try file.write(from: buffer)
        }
        try check(url)
    }
}
