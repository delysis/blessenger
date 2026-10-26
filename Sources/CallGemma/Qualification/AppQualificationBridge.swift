import Foundation
@preconcurrency import AVFoundation

/// Explicit launch-only automation. Uses isolated app storage and the same live
/// controllers as SwiftUI; no listener, polling, or fixture injection in normal launches.
enum AppQualificationEnvironment {
    static let root = ProcessInfo.processInfo.environment["BLESSENGER_QUALIFICATION_DIRECTORY"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    // Acoustic qualification must exercise the microphone after VoiceProcessingIO.
    // Normal automation remains synthetic and muted unless explicitly opted in.
    static let usesSyntheticInput = root != nil &&
        ProcessInfo.processInfo.environment["BLESSENGER_QUALIFICATION_MICROPHONE"] != "1"
    static var hidesAutomationWindow: Bool {
        usesSyntheticInput && ProcessInfo.processInfo.environment["BLESSENGER_QUALIFICATION_VISIBLE"] != "1"
    }
    static var runtime: URL { root?.appending(path: "Runtime") ?? URL.applicationSupportDirectory.appending(path: "CallGemma") }
    static var messaging: URL { root?.appending(path: "Messaging") ?? URL.applicationSupportDirectory.appending(path: "Blessenger") }
}

@MainActor
enum AppQualificationBridge {
    private static var jobs: [String: String] = [:]
    private struct Command: Decodable {
        let operation: String
        var id: UUID?
        var contacts: [UUID]?
        var path: String?
        var text: String?
        var fraction: Double?
        var referenceEnd: Int?
    }

    static func run(controller: CallController, model: MessagingModel) async {
        guard let root = AppQualificationEnvironment.root else { return }
        let inbox = root.appending(path: "Commands")
        do {
            try await Task.detached {
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }.value
            while !Task.isCancelled {
                let request = try await Task.detached { () -> (URL, Data)? in
                    let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "request" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    guard let file = files.first else { return nil }
                    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65_536 else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    let data = try Data(contentsOf: file)
                    try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("running"))
                    return (file, data)
                }.value
                guard let (file, data) = request else {
                    try await Task.sleep(for: .milliseconds(50)); continue
                }
                let response: Data
                do {
                    let command = try JSONDecoder().decode(Command.self, from: data)
                    let result = try await execute(command, controller: controller, model: model)
                    response = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
                } catch {
                    response = try JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])
                }
                try await Task.detached {
                    try response.write(to: file.deletingPathExtension().appendingPathExtension("response"), options: .atomic)
                }.value
            }
        } catch is CancellationError {} catch {
            AudioTrace.logger.error("App qualification bridge failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func readFixture(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= 480_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CallAudioError.invalidVoice
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CallAudioError.invalidVoice }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func execute(_ command: Command, controller: CallController, model: MessagingModel) async throws -> [String: Any] {
        switch command.operation {
        #if os(macOS)
        case "companion_status":
            return await WebCompanion.shared.diagnostics()
        #endif
        case "status":
            return ["ready": controller.ready, "inCall": controller.inCall, "dialing": controller.dialing,
                    "busy": controller.busy, "microphoneMuted": controller.microphoneMuted, "status": controller.status, "notice": controller.notice ?? "",
                    "audio": controller.audioDiagnostics, "selected": model.selected?.uuidString ?? "",
                    "playingNote": controller.playingVoiceNote?.uuidString ?? "",
                    "notePosition": controller.voiceNotePosition, "noteDuration": controller.voiceNoteDuration,
                    "participant": controller.activeCallParticipant?.uuidString ?? "",
                    "model": controller.qualificationModelID, "syntheticInput": AppQualificationEnvironment.usesSyntheticInput,
                    "outputMuted": AutomatedAudioOutput.volume == 0,
                    "endpoint": CallAudio.qualificationEndpointSettings,
                    "pendingTurns": controller.qualificationPendingTurns,
                    "fixtureRemainingFrames": controller.qualificationRemainingFrames,
                    "participantHandoffs": controller.qualificationParticipantHandoffs,
                    "callWakeFingerprint": controller.qualificationCallWakeFingerprint,
                    "callID": controller.qualificationCallID,
                    "responding": controller.qualificationResponding,
                    "recovering": controller.qualificationRecovering,
                    "completedTurns": controller.qualificationCompletedTurns,
                    "jobs": jobs]
        case "wake_status":
            return ["status": WakeNameEnrollment.shared.help,
                    "ready": WakeNameEnrollment.shared.model != nil,
                    "fingerprint": WakeNameEnrollment.shared.model?.fingerprint ?? ""]
        case "wake_retry": WakeNameEnrollment.shared.retry()
        case "wake_pause": await WakeNameEnrollment.shared.pause()
        case "wake_resume": WakeNameEnrollment.shared.resume()
        case "set_wake_name":
            guard let id = command.id, let text = command.text,
                  var contact = model.state.contacts.first(where: { $0.id == id }) else { throw CheckpointError.invalidMetadata }
            contact.wakeName = text
            await model.save(contact)
        case "contacts":
            return ["contacts": model.state.contacts.map { ["id": $0.id.uuidString, "name": $0.name] }]
        case "create_chat":
            guard let contacts = command.contacts, !contacts.isEmpty,
                  contacts.allSatisfy({ id in model.state.contacts.contains { $0.id == id } }),
                  let id = await model.createChat(contacts: contacts) else { throw CheckpointError.invalidMetadata }
            return ["id": id.uuidString]
        case "select":
            guard let id = command.id, model.state.threads.contains(where: { $0.id == id && $0.deleted != true }) else { throw CheckpointError.invalidMetadata }
            model.selected = id
        case "prepare_contact":
            guard let id = command.id,
                  let contact = model.state.contacts.first(where: { $0.id == id }) else {
                throw CheckpointError.invalidMetadata
            }
            try await controller.prepareCall(contact: contact)
        case "call":
            guard !controller.inCall, let thread = model.state.threads.first(where: { $0.id == model.selected }),
                  let contact = ConversationRouting.initialResponder(in: thread, state: model.state) else { throw CheckpointError.invalidMetadata }
            let participants = thread.participants.compactMap { id in model.state.contacts.first { $0.id == id } }
            let initial = command.id ?? contact.id
            guard participants.contains(where: { $0.id == initial }) else { throw CheckpointError.invalidMetadata }
            controller.dial(participants: participants, initialSpeaker: initial, memoryStore: model.store)
        case "mute": controller.toggleMicrophoneMute()
        case "hangup":
            if controller.inCall { controller.toggleCall() }
        case "participant":
            guard let id = command.id else { throw CheckpointError.invalidMetadata }
            guard controller.requestCallParticipant(id) else { throw CheckpointError.invalidMetadata }
        case "inject_audio":
            guard let path = command.path else { throw CheckpointError.invalidMetadata }
            let samples = try await Task.detached { try readFixture(URL(fileURLWithPath: path)) }.value
            try controller.qualificationInject(samples, referenceEnd: command.referenceEnd)
        case "record_start": try await controller.startVoiceNoteRecording()
        case "record_finish": return ["path": try await controller.finishVoiceNoteRecording().path]
        case "record_cancel": await controller.cancelVoiceNoteRecording()
        case "stop_note": await controller.stopVoiceNotePlayback()
        case "seek_note": controller.seekVoiceNote(to: command.fraction ?? 0)
        case "messages":
            await model.load()
            return ["messages": model.state.messages.filter { $0.thread == model.selected }.map {
                ["id": $0.id.uuidString, "text": $0.text, "voiceNote": $0.voiceNote == true] as [String: Any]
            }]
        case "play_note":
            guard let message = model.state.messages.first(where: { $0.id == command.id }) else { throw CheckpointError.invalidMetadata }
            let contact = model.state.contacts.first { $0.id == message.sender }
            controller.toggleVoiceNote(message, contact: contact)
        case "send_text", "send_audio":
            guard let selected = model.selected else { throw CheckpointError.invalidMetadata }
            var attachments: [MessageAttachment] = []
            if command.operation == "send_audio" {
                guard let path = command.path else { throw CheckpointError.invalidMetadata }
                attachments = [try await AttachmentLibrary().importFile(URL(fileURLWithPath: path))]
            }
            guard jobs.count < 64 else { throw CocoaError(.fileWriteOutOfSpace) }
            let job = UUID().uuidString
            jobs[job] = "running"
            Task {
                let accepted = await model.send(command.text ?? "", threadID: selected, mentions: [], attachments: attachments, controller: controller)
                jobs[job] = accepted ? "completed" : "failed"
            }
            return ["job": job]
        default: throw CocoaError(.featureUnsupported)
        }
        return [:]
    }
}
