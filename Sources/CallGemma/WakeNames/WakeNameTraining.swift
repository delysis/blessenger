import Foundation
import FluidAudio
import class FluidAudio.AudioConverter

/// Purely local synthesis and fitting. Never owns a microphone or playback node.
enum WakeNameTraining {
    struct Receipt: Codable, Sendable {
        var positives = 0
        var correct = 0
        var wrong = 0
        var negatives = 0
        var falseActivations = 0
        var clips = 0
        var accepted: Bool { positives > 0 && correct * 100 >= positives * 95 && wrong == 0 && negatives >= 24 && falseActivations == 0 }
    }
    struct Result: Codable, Sendable {
        let model: WakeNameModel
        let receipt: Receipt
    }
    struct Voice: Sendable { let name: String; let validation: Bool }
    static let voices = ["bessel_van_der_kolk", "gabor_mate", "peter_levine", "richard_schwartz",
        "janina_fisher", "christine_courtois", "robert_miller", "arnold_popky", "jim_knipe", "shirley_jean_schmidt"]
        .map { Voice(name: $0, validation: false) }
        + [Voice(name: "francine_shapiro", validation: true), Voice(name: "dolores_mosquera", validation: true)]
    // Judith and Ad conditioning are reserved for external evaluation.
    static let trainingNegatives = ["Hello there.", "Thank you.", "Please continue.", "What do you think?",
        "I understand.", "Can you explain?", "Tell me more.", "Let me think.",
        "That makes sense.", "I am still here.", "A little better.", "Please repeat that.",
        "The vessel is empty.", "The heater is running.", "The gate is open.",
        "Just add some water.", "The fisherman left.", "It is Christmas soon.",
        "I met her yesterday.", "We should go home.", "No, not yet.", "Yes, that's right.",
        "I need a moment.", "The room is quiet.", "Surely you understand.", "The picture is clear.",
        "The dollar is stronger.", "The garden looks lovely.", "We reached the station.", "I like your jacket."]
    // Disjoint texts, not merely unseen speakers pronouncing training sentences.
    static let validationNegatives = ["Can we start over?", "My friend called this morning.",
        "There is a bird outside.", "Could you lower your voice?", "I've been feeling tired lately.",
        "It happened a long time ago.", "I don't know what to say.", "My mother was worried.",
        "We talked about this yesterday.", "I'm not ready to answer.", "The door is still open.",
        "Would you give me another example?", "I heard something in the kitchen.",
        "It might be worth waiting.", "That's an interesting question.", "She was sitting by the window.",
        "I think the weather is changing.", "Let's take a short break.", "This is quite difficult.",
        "I can't remember exactly.", "There's nothing else to add.", "It feels better now.",
        "They live a few miles away.", "Could we try something different?"]

    static func fingerprint(_ contacts: [Persona]) throws -> String {
        try fingerprint(contacts, version: "wake-v6|")
    }

    private static func fingerprint(_ contacts: [Persona], version: String) throws -> String {
        struct Input: Codable { let id: UUID; let name: String; let voice: String; let pcm: String }
        let inputs = try contacts.sorted { $0.id.uuidString < $1.id.uuidString }.map { contact in
            let url = contact.voice.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : BlessengerResources.voiceURL($0) }
            let hash = try url.map { try VoiceSample.read(from: $0).withUnsafeBytes { digest(Data($0)) } } ?? "default"
            return Input(id: contact.id, name: contact.wakeName, voice: contact.voice ?? "", pcm: hash)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(inputs) + Data((version + PocketSpeechAssets.identity + AudioModelPins.alignerIdentity).utf8))
    }

    static func train(contacts: [Persona], fingerprint: String, cacheDirectory: URL? = nil,
                      progress: @Sendable (Int, Int) async -> Void) async throws -> Result {
        let names = contacts.sorted { $0.id.uuidString < $1.id.uuidString }.filter { WakeNameModel.words($0.wakeName).joined().count >= 3 }
            .map { WakeNameModel.Name(id: $0.id, name: $0.wakeName) }
        guard !names.isEmpty, names.count <= 32,
              Set(names.map { WakeNameModel.words($0.name).joined(separator: " ") }).count == names.count else {
            throw GemmaError(message: "Wake names must be distinct and contain at least three letters.")
        }
        await AudioModelPins.configure()
        let directory = AudioModelPins.pocketDirectory(in: AppQualificationEnvironment.messaging)
        try await AudioModelPins.preparePocketCache(at: directory)
        try await AudioModelPins.prepareVoiceEncoder(at: directory)
        let manager = PocketTtsManager(directory: directory, placement: .ane,
            computeUnits: PocketTtsComputeUnits(conditioner: .cpuAndNeuralEngine, flowLM: .cpuAndNeuralEngine,
                flowDecoder: .cpuAndNeuralEngine, mimiDecoder: .cpuOnly, mimiEncoder: .cpuOnly))
        try await manager.initialize()
        let phonetics = WakePhonetics()
        // Decision-policy changes do not require resynthesizing identical PCM.
        let features = try cacheDirectory?.appending(path: Self.fingerprint(contacts, version: "wake-v5|"))
        if let features { try FileManager.default.createDirectory(at: features, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var training: [WakeNameClassifier.Example] = []
        var validation: [(String, String)] = []
        var voiceHashes = Set<String>()
        var count = 0
        let customVoices = contacts.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { contact -> Voice? in
            guard let voice = contact.voice, voice.hasPrefix("/") else { return nil }
            return Voice(name: voice, validation: false)
        }
        let sources = voices + customVoices
        let total = sources.reduce(0) { $0 + names.count * 4 + ($1.validation ? validationNegatives.count : trainingNegatives.count) }
        do {
            for voice in sources {
                try Task.checkCancellation()
                guard let url = voice.name.hasPrefix("/") ? URL(fileURLWithPath: voice.name) : BlessengerResources.voiceURL(voice.name) else { throw CallAudioError.invalidVoice }
                let pcm = try VoiceSample.read(from: url)
                let voiceHash = pcm.withUnsafeBytes { digest(Data($0)) }
                guard voiceHashes.insert(voiceHash).inserted else { continue }
                let conditioning = try await manager.cloneVoice(from: pcm)
                var examples = (voice.validation ? validationNegatives : trainingNegatives).map { ($0, "other") }
                for name in names {
                    examples += ["\(name.name).", "Hey \(name.name).", "\(name.name), what do you think?", "Thank you, \(name.name)."]
                        .map { ($0, name.id.uuidString.lowercased()) }
                }
                for (text, label) in examples {
                    try Task.checkCancellation()
                    // Short standalone synthetic names can lose their initial
                    // phonemes. Protect both ends during training only, then
                    // retain the target's unconstrained acoustic decode.
                    let spokenText = "Hello there. " + text + " Can you help me?"
                    let key = digest(Data("\(voiceHash)|\(count + 70_000)|\(spokenText)".utf8))
                    let file = features?.appending(path: key + ".json")
                    let decoded: String
                    if let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
                       let bytes = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(String.self, from: bytes) {
                        decoded = cached
                    } else {
                    let session = try await manager.makeSession(voiceData: conditioning, seed: UInt64(count + 70_000))
                    session.enqueue(spokenText); session.finish()
                    var samples: [Float] = []
                    do {
                        for try await frame in session.frames {
                            try Task.checkCancellation()
                            guard samples.count + frame.samples.count <= 360_000, frame.samples.allSatisfy(\.isFinite) else { throw CallAudioError.invalidVoice }
                            samples.append(contentsOf: frame.samples)
                        }
                        await session.cancel()
                    } catch { await session.cancel(); throw error }
                    let input = try AudioConverter(sampleRate: 16_000).resample(samples, from: 24_000)
                    decoded = try await phonetics.decode(input, trainingText: spokenText, trailingTrainingWords: 4)
                        try Task.checkCancellation()
                        if let file { try JSONEncoder().encode(decoded).write(to: file, options: .atomic) }
                    }
                    if voice.validation { validation.append((decoded, label)) }
                    else if !decoded.isEmpty { training.append(.init(text: decoded, label: label)) }
                    count += 1
                    await progress(count, total)
                }
            }
            let head = try WakeNameClassifier.train(training)
            let candidate = WakeNameModel(fingerprint: fingerprint, names: names, classifier: head, accepted: false)
            var receipt = Receipt(); receipt.clips = count
            let roster = Set(names.map(\.id))
            for (decoded, label) in validation {
                let prediction = try candidate.recipient(decoded, roster: roster)?.uuidString.lowercased() ?? "other"
                if label == "other" { receipt.negatives += 1; if prediction != "other" { receipt.falseActivations += 1 } }
                else {
                    receipt.positives += 1
                    if prediction == label { receipt.correct += 1 }
                    else if prediction != "other" { receipt.wrong += 1 }
                }
            }
            await phonetics.close()
            return Result(model: WakeNameModel(fingerprint: fingerprint, names: names, classifier: head, accepted: receipt.accepted), receipt: receipt)
        } catch { await phonetics.close(); throw error }
    }
}
