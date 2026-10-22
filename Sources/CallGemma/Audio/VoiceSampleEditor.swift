@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class VoiceSampleEditorModel: ObservableObject {
    @Published var source: URL?
    @Published var duration = 0.0
    @Published var start = 0.0
    @Published var end = 10.0
    @Published var name = "Recording"
    @Published var busy = false
    @Published var recording = false
    @Published var playing = false
    @Published var elapsed = 0.0
    @Published var error: String?
    private var scoped = false
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var clock: Task<Void, Never>?
    private let scratch = FileManager.default.temporaryDirectory.appending(path: "VoiceEditor-\(UUID().uuidString)")

    var endLower: Double { min(duration, max(0, start.isFinite ? start : 0) + 1) }
    var endUpper: Double { max(endLower, min(duration, max(0, start.isFinite ? start : 0) + 10)) }
    var valid: Bool { source != nil && start.isFinite && end.isFinite && start >= 0 && end <= duration && end - start >= 1 && end - start <= 10.001 }

    func load(_ url: URL) async {
        stopPlayback()
        busy = true
        defer { busy = false }
        let access = url.startAccessingSecurityScopedResource()
        do {
            let seconds = try await Task.detached { try VoiceSample.duration(of: url) }.value
            guard seconds.isFinite, seconds >= 1 else { throw CallAudioError.invalidVoice }
            if scoped { source?.stopAccessingSecurityScopedResource() }
            if let old = source, old != url, old.deletingLastPathComponent() == scratch {
                try? FileManager.default.removeItem(at: old)
            }
            source = url
            scoped = access
            duration = seconds
            start = 0
            end = min(10, seconds)
            name = url.deletingPathExtension().lastPathComponent
        } catch {
            if access { url.stopAccessingSecurityScopedResource() }
            self.error = error.localizedDescription
        }
    }

    func moveStart(_ value: Double) {
        stopPlayback()
        let length = min(10, max(1, end - start))
        start = min(max(0, value.isFinite ? value : 0), max(0, duration - 1))
        end = min(duration, start + length)
    }

    func export() async throws -> URL {
        guard valid, let source else { throw CallAudioError.invalidVoice }
        let begin = start, length = min(10, end - start)
        let output = FileManager.default.temporaryDirectory.appending(path: "VoiceSelection-\(UUID().uuidString).wav")
        do {
            try await Task.detached(priority: .userInitiated) {
                try VoiceSample.export(from: source, start: begin, duration: length, to: output)
            }.value
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    func preview() async {
        if playing { stopPlayback(); return }
        busy = true
        defer { busy = false }
        do {
            let url = try await export()
            defer { try? FileManager.default.removeItem(at: url) }
            player = try AVAudioPlayer(data: Data(contentsOf: url))
            guard player?.play() == true else { throw CallAudioError.invalidVoice }
            playing = true
            clock?.cancel()
            clock = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !Task.isCancelled else { return }
                    if self.player?.isPlaying != true { self.playing = false; return }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func record() async {
        guard !busy, !recording else { return }
        busy = true
        defer { busy = false }
        stopPlayback()
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = CallAudioError.microphoneDenied.localizedDescription
            return
        }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let url = scratch.appending(path: "Recording-\(UUID().uuidString).wav")
            recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false])
            guard recorder?.record(forDuration: 60) == true else { throw CallAudioError.invalidVoice }
            recording = true
            elapsed = 0
            clock = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !Task.isCancelled else { return }
                    if self.recorder?.isRecording != true { await self.finishRecording(); return }
                    self.elapsed = self.recorder?.currentTime ?? 0
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func finishRecording() async {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        recording = false
        clock?.cancel()
        clock = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        await load(url)
        if source == url { name = "Recording" }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playing = false
        if !recording { clock?.cancel(); clock = nil }
    }

    func close() {
        clock?.cancel()
        recorder?.stop()
        recorder = nil
        stopPlayback()
        if scoped { source?.stopAccessingSecurityScopedResource(); scoped = false }
        try? FileManager.default.removeItem(at: scratch)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

struct VoiceSampleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VoiceSampleEditorModel()
    @State private var choosing = false
    let initialURL: URL?
    let save: (URL, String) -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Voice").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .help("Cancel").accessibilityLabel("Cancel voice sample")
                    .disabled(model.busy)
            }
            HStack {
                Button { choosing = true } label: { Image(systemName: "folder") }
                    .help("Open audio file").accessibilityLabel("Open audio file")
                    .disabled(model.recording || model.busy)
                Button {
                    Task { if model.recording { await model.finishRecording() } else { await model.record() } }
                } label: { Image(systemName: model.recording ? "stop.fill" : "mic.fill").foregroundStyle(model.recording ? .red : .primary) }
                    .help(model.recording ? "Stop recording" : "Record up to one minute, then select a sample")
                    .accessibilityLabel(model.recording ? "Stop recording" : "Record voice sample")
                    .disabled(model.busy)
                if model.recording { Text(model.elapsed, format: .number.precision(.fractionLength(1))).monospacedDigit() }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            if model.source != nil && !model.recording {
                TextField("Name", text: $model.name).accessibilityLabel("Voice name")
                Slider(value: Binding(get: { model.start }, set: { model.moveStart($0) }), in: 0...max(0.001, model.duration - 1))
                    .accessibilityLabel("Selection start").help("Select the beginning of the voice sample")
                HStack {
                    Text("Start")
                    TextField("Start", value: Binding(get: { model.start }, set: { model.moveStart($0) }), format: .number.precision(.fractionLength(2)))
                        .accessibilityLabel("Start seconds")
                    Text("End")
                    TextField("End", value: Binding(get: { model.end }, set: { model.end = min(model.endUpper, max(model.endLower, $0.isFinite ? $0 : model.endLower)) }), format: .number.precision(.fractionLength(2)))
                        .accessibilityLabel("End seconds")
                }.monospacedDigit()
                Slider(value: $model.end, in: model.endLower...model.endUpper)
                    .accessibilityLabel("Selection end").help("Choose one to ten seconds")
                HStack {
                    Button { Task { await model.preview() } } label: { Image(systemName: model.playing ? "stop.fill" : "play.fill") }
                        .accessibilityLabel(model.playing ? "Stop preview" : "Preview selection")
                        .help("Preview selection").disabled(!model.valid || model.busy)
                    Spacer()
                    Text("\(max(0, model.end - model.start), specifier: "%.1f") / \(model.duration, specifier: "%.1f") s")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        Task {
                            model.busy = true
                            defer { model.busy = false }
                            do {
                                let url = try await model.export()
                                save(url, model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : model.name)
                                dismiss()
                            } catch { model.error = error.localizedDescription }
                        }
                    } label: { Image(systemName: "checkmark") }
                        .help("Use selected sample").accessibilityLabel("Use selected sample")
                        .disabled(!model.valid || model.busy)
                }
            }
        }
        .padding(24).frame(minWidth: 300, idealWidth: 380)
        .interactiveDismissDisabled(model.busy || model.recording)
        .task { if let initialURL { await model.load(initialURL) } }
        .onDisappear { model.close() }
        .onChange(of: model.start) { _, _ in model.stopPlayback() }
        .onChange(of: model.end) { _, _ in model.stopPlayback() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): Task { await model.load(url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .alert("Voice sample", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
