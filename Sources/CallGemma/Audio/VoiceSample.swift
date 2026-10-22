@preconcurrency import AVFoundation
import FluidAudio
import class FluidAudio.AudioConverter
import Foundation

enum VoiceSample {
    /// Decode at most ten seconds, downmix at the original rate, then resample once.
    static func read(from url: URL, start: Double = 0, duration: Double = 10) throws -> [Float] {
        guard start.isFinite, start >= 0, duration.isFinite, duration >= 1, duration <= 10 else { throw CallAudioError.invalidVoice }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.sampleRate.isFinite, format.channelCount > 0,
              format.sampleRate <= 384_000, format.channelCount <= 8 else { throw CallAudioError.invalidVoice }
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw CallAudioError.invalidVoice
        }
        guard start * format.sampleRate < Double(file.length) else { throw CallAudioError.invalidVoice }
        file.framePosition = AVAudioFramePosition(start * format.sampleRate)
        var remainingFrames = Int(format.sampleRate * duration)
        let downmix = AudioConverter(sampleRate: format.sampleRate)
        var mono: [Float] = []
        while remainingFrames > 0, file.framePosition < file.length {
            try Task.checkCancellation()
            do {
                try file.read(into: input, frameCount: AVAudioFrameCount(min(4_096, remainingFrames)))
            } catch {
                // MP3/AAC length estimates can include an undecodable tail. Keep
                // the valid prefix, as FluidAudio's own file converter does.
                if mono.isEmpty { throw error }
                break
            }
            guard input.frameLength > 0 else { break }
            remainingFrames -= Int(input.frameLength)
            mono.append(contentsOf: try downmix.resampleBuffer(input))
        }
        // Resample once so converter priming cannot introduce gaps between reads.
        let samples = Array(try AudioConverter(sampleRate: 24_000)
            .resample(mono, from: format.sampleRate).prefix(240_000))
        guard samples.count >= 24_000, samples.allSatisfy(\.isFinite) else { throw CallAudioError.invalidVoice }
        return samples
    }
    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, file.length > 0 else { throw CallAudioError.invalidVoice }
        return Double(file.length) / rate
    }

    /// Only the selected interval is decoded; source size is not a memory limit.
    static func export(from source: URL, start: Double, duration: Double, to destination: URL) throws {
        let samples = try read(from: source, start: start, duration: duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw CallAudioError.invalidVoice }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)
        try file.write(from: buffer)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

}
