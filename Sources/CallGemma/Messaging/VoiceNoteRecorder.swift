@preconcurrency import AVFoundation
import SwiftUI

/// Receives the same 16 kHz frames used by live calls. File I/O stays off the
/// UI and audio render threads, with the call capture stream's bounded queue.
actor VoiceNoteRecording {
    let url = FileManager.default.temporaryDirectory.appending(path: "VoiceNote-\(UUID().uuidString).wav")
    private var file: AVAudioFile?
    private var frames = 0
    private var peaks: [Float] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    func append(_ samples: [Float]) throws {
        guard frames + samples.count <= 16_000 * 120 else {
            throw GemmaError(message: "The recording reached two minutes.")
        }
        if file == nil { file = try AVAudioFile(forWriting: url, settings: format.settings) }
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw CallAudioError.invalidVoice }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        try file?.write(from: buffer)
        frames += samples.count
        peaks.append(samples.reduce(Float(0)) { max($0, abs($1)) })
        if peaks.count > 64 { peaks.removeFirst(peaks.count - 64) }
    }

    func levels() -> [Float] { peaks }
    func elapsed() -> Double { Double(frames) / 16_000 }
    func finish() throws -> URL {
        file = nil
        guard frames > 0 else { throw CallAudioError.invalidVoice }
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize(); try handle.close()
        return url
    }
    func cancel() {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}

struct VoiceNoteComposer: View {
    @Environment(\.scenePhase) private var phase
    @ObservedObject var controller: CallController
    let commit: (URL) async throws -> Void
    let dismiss: () -> Void
    @State private var elapsed = 0.0
    @State private var levels: [Float] = []
    @State private var recording = false
    @State private var saving = false
    @State private var error: String?
    @State private var finished: URL?
    @State private var preview: AVAudioPlayer?
    @State private var playing = false

    var body: some View {
        HStack(spacing: 10) {
            if finished != nil {
                cancelButton
                    .glassEffect(.regular, in: Circle())
            }
            HStack(spacing: 12) {
                if finished == nil { cancelButton }
                else {
                    Button {
                        if playing { preview?.stop(); playing = false }
                        else if let finished {
                            do { preview = try AVAudioPlayer(contentsOf: finished); preview?.play(); playing = true }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(.primary.opacity(0.06), in: Circle())
                    }.accessibilityLabel(playing ? "Stop preview" : "Preview recording")
                }
                VoiceNoteWaveform(levels: levels, seed: "", active: recording)
                    .frame(maxWidth: .infinity).frame(height: 24)
                    .foregroundStyle(finished == nil ? Color.red : Color.secondary)
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
                    .foregroundStyle(finished == nil ? Color.red : Color.primary)
                    .fixedSize()
                    .padding(.horizontal, finished == nil ? 0 : 8)
                    .padding(.vertical, 5)
                    .background(finished == nil ? Color.clear : Color.primary.opacity(0.04), in: Capsule())
                Button { Task { if finished == nil { await finish() } else { await save() } } } label: {
                    Image(systemName: finished == nil ? "stop.fill" : "arrow.up")
                        .font(.system(size: finished == nil ? 15 : 20, weight: .semibold))
                        .foregroundStyle(finished == nil ? Color.red : Color.white)
                        .frame(width: 34, height: 30)
                        .background(finished == nil ? Color.clear : Color.accentColor, in: Capsule())
                }.disabled((!recording && finished == nil) || saving)
                    .accessibilityLabel(finished == nil ? "Finish recording" : "Send voice note")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .task {
            do {
                try await controller.startVoiceNoteRecording()
                recording = true
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    if recording {
                        elapsed = await controller.voiceNoteElapsed()
                        levels = await controller.voiceNoteLevels()
                        if elapsed >= 119.5 { await finish() }
                    }
                    if playing, preview?.isPlaying != true { playing = false }
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .onChange(of: phase) { _, value in
            if value == .background { Task { await finish() } }
        }
        .onDisappear {
            preview?.stop()
            let owned = finished
            Task {
                await controller.cancelVoiceNoteRecording()
                if let owned { try? FileManager.default.removeItem(at: owned) }
            }
        }
        .alert("Recording failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { }
        } message: { Text(error ?? "") }
    }
    private var cancelButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(finished == nil ? Color.secondary : Color.primary)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }.disabled(saving).accessibilityLabel("Cancel recording")
    }
    private func finish() async {
        guard recording else { return }
        recording = false
        do { finished = try await controller.finishVoiceNoteRecording() }
        catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let finished, !saving else { return }
        saving = true
        preview?.stop(); playing = false
        defer { saving = false }
        do { try await commit(finished); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// Decorative voice-note identity when audio is synthesized on demand; live
/// recording passes measured peaks instead. It is not a synthetic audio trace.
struct VoiceNoteWaveform: View {
    var levels: [Float] = []
    var seed: String
    var active = false
    private var bars: [Float] {
        if !levels.isEmpty { return levels }
        if active { return Array(repeating: 0.02, count: 64) }
        let bytes = Array(seed.utf8)
        return (0..<48).map { index in
            let value = bytes.isEmpty ? 17 : Int(bytes[index % bytes.count])
            return Float((value * 31 + index * 17) % 65 + 15) / 100
        }
    }
    var body: some View {
        Canvas { context, size in
            let samples = bars
            let step = size.width / CGFloat(samples.count)
            for (index, sample) in samples.enumerated() {
                let level = levels.isEmpty ? CGFloat(sample) : min(1, CGFloat(sample) * 5)
                let height = max(3, level * size.height)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                  width: max(1, min(3, step - 2)), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .foreground)
            }
        }.accessibilityHidden(true)
    }
}
