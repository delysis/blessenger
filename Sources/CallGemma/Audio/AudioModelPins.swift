import FluidAudio
import Foundation

/// Configure once, before starting either FluidAudio actor. The SDK's registry is mutable global state.
enum AudioModelPins {
    static let pocket = "91748676fe3c8b2eb3007b3125253bcd898202c3"
    static let vad = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
    static let alignerIdentity = "2e746e6425966389c9474c1dd82f420de4053b0c1d023510b4048f77db64f981"
    static var alignerDirectory: URL {
        HFModelCache.root.appending(path: ".callgemma/aligner/\(alignerIdentity)/Wav2VecAligner.mlpackage")
    }
    @MainActor private static var configured = false

    @MainActor static func configure() {
        guard !configured else { return }
        var revisions = ModelRegistry.revisionOverrides
        revisions["FluidInference/pocket-tts-coreml"] = pocket
        revisions["FluidInference/silero-vad-coreml"] = vad
        ModelRegistry.revisionOverrides = revisions
        configured = true
    }

    static var legacyPocketDirectory: URL {
        HFModelCache.root.appending(path: ".callgemma/fluidaudio/\(pocket)")
    }

    static func pocketDirectory(in directory: URL) -> URL {
        HFModelCache.root.appending(path: ".callgemma/fluidaudio/\(pocket)-\(PocketSpeechAssets.identity)")
    }

    static func preparePocketCache(at directory: URL) async throws {
        let snapshot = try await ensure(files: pocketFiles)
        if directory != legacyPocketDirectory {
            try await PocketSpeechAssets.shared.prepare(directory: directory, snapshot: snapshot)
        }
    }

    static func prepareVoiceEncoder(at directory: URL) async throws {
        let snapshot = try await ensure(files: encoderFiles)
        if directory != legacyPocketDirectory {
            try await PocketSpeechAssets.shared.prepare(directory: directory, snapshot: snapshot)
        }
    }

    private static func ensure(files: [String: Int]) async throws -> URL {
        let snapshot = try await HFModelCache.snapshot(repository: "FluidInference/pocket-tts-coreml",
            revision: pocket, files: Array(files.keys))
        guard complete(at: snapshot, files: files) else {
            throw CallAudioError.unavailable("The pinned PocketTTS snapshot is incomplete.")
        }
        _ = try HFModelCache.fluidDirectory(repository: "FluidInference/pocket-tts-coreml",
            revision: pocket, folder: Repo.pocketTts.folderName, snapshot: snapshot)
        return snapshot
    }

    static func prepareVAD() async throws -> URL {
        let name = ModelNames.VAD.sileroVadFile
        let snapshot = try await HFModelCache.snapshot(repository: "FluidInference/silero-vad-coreml",
            revision: vad, files: ["analytics/coremldata.bin", "coremldata.bin", "metadata.json",
                "model.mil", "weights/weight.bin"].map { name + "/" + $0 })
        return try HFModelCache.fluidDirectory(repository: "FluidInference/silero-vad-coreml",
            revision: vad, folder: Repo.vad.folderName, snapshot: snapshot)
    }

    static func prepareStreamingVAD() async throws -> URL {
        let name = "silero-vad-unified-v6.0.0.mlmodelc"
        let snapshot = try await HFModelCache.snapshot(repository: "FluidInference/silero-vad-coreml",
            revision: vad, files: ["analytics/coremldata.bin", "coremldata.bin", "metadata.json",
                "model.mil", "weights/weight.bin"].map { name + "/" + $0 })
        return snapshot.appendingPathComponent(name)
    }

    /// Size checks detect incomplete caches without re-reading hundreds of MB on every start.
    /// Download URLs are pinned by revision; this is not a cryptographic check of later local edits.
    private static func complete(at directory: URL, files: [String: Int]) -> Bool {
        files.allSatisfy { path, size in
            guard let values = try? directory.appendingPathComponent(path).resolvingSymlinksInPath().resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink == false && values.fileSize == size
        }
    }

    // Pinned HF tree receipts are recorded in Documentation/audio-receipts.json.
    // Preloading BOS and Alba avoids FluidAudio's legacy default-main constant/voice backfills.
    private static let pocketFiles: [String: Int] = [
        "v2.1/english/cond_prefill_ane.mlmodelc/analytics/coremldata.bin": 243,
        "v2.1/english/cond_prefill_ane.mlmodelc/coremldata.bin": 1_388,
        "v2.1/english/cond_prefill_ane.mlmodelc/model.mil": 136_093,
        "v2.1/english/cond_prefill_ane.mlmodelc/weights/weight.bin": 132_187_392,
        "v2.1/english/constants_bin/alba.safetensors": 6_194_424,
        "v2.1/english/constants_bin/bos_before_voice.bin": 4_096,
        "v2.1/english/constants_bin/bos_emb.bin": 128,
        "v2.1/english/constants_bin/text_embed_table.bin": 16_388_096,
        "v2.1/english/constants_bin/tokenizer.model": 59_339,
        "v2.1/english/flow_decoder_fused.mlmodelc/analytics/coremldata.bin": 243,
        "v2.1/english/flow_decoder_fused.mlmodelc/coremldata.bin": 413,
        "v2.1/english/flow_decoder_fused.mlmodelc/model.mil": 333_331,
        "v2.1/english/flow_decoder_fused.mlmodelc/weights/weight.bin": 19_012_608,
        "v2.1/english/flowlm_step_ane.mlmodelc/analytics/coremldata.bin": 243,
        "v2.1/english/flowlm_step_ane.mlmodelc/coremldata.bin": 1_414,
        "v2.1/english/flowlm_step_ane.mlmodelc/model.mil": 156_945,
        "v2.1/english/flowlm_step_ane.mlmodelc/weights/weight.bin": 151_136_960,
        "v2.1/english/mimi_decoder.mlmodelc/analytics/coremldata.bin": 243,
        "v2.1/english/mimi_decoder.mlmodelc/coremldata.bin": 1_777,
        "v2.1/english/mimi_decoder.mlmodelc/metadata.json": 16_844,
        "v2.1/english/mimi_decoder.mlmodelc/model.mil": 107_403,
        "v2.1/english/mimi_decoder.mlmodelc/weights/weight.bin": 41_768_256,
    ]

    private static let encoderFiles: [String: Int] = [
        "mimi_encoderv2.mlmodelc/analytics/coremldata.bin": 243,
        "mimi_encoderv2.mlmodelc/coremldata.bin": 380,
        "mimi_encoderv2.mlmodelc/metadata.json": 2_091,
        "mimi_encoderv2.mlmodelc/model.mil": 24_543_097,
        "mimi_encoderv2.mlmodelc/weights/weight.bin": 19_842_240,
    ]
}
