import Foundation
import FluidAudio

/// Installs the bundled, corrected exports without modifying the upstream snapshot.
actor PocketSpeechAssets {
    static let shared = PocketSpeechAssets()
    static let identity = "da8b5b05160abf06a8882d2c7bc6c44f9a635538b0ba57c23e2fa040c938ea3c"
    private var prepared: Set<URL> = []
    private struct Manifest: Decodable { let identity: String; let files: [String: String] }

    func prepare(directory: URL, snapshot: URL) throws {
        guard !prepared.contains(directory) else { return }
        let manager = FileManager.default
        guard let resources = Bundle.main.resourceURL,
              let manifestURL = Bundle.main.url(forResource: "pocket-speech-models", withExtension: "json") else {
            throw CallAudioError.unavailable("The bundled speech model is missing.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.identity == Self.identity else {
            throw CallAudioError.unavailable("The speech model identity does not match this build.")
        }
        let assets = HFModelCache.root.appending(path: ".callgemma/speech-models/\(Self.identity)")
        func validate(_ root: URL) throws {
            for (name, hash) in manifest.files {
                guard !name.contains(".."), !name.hasPrefix("/"),
                      digest(try Data(contentsOf: root.appending(path: name), options: .mappedIfSafe)) == hash else {
                    throw CallAudioError.unavailable("The speech model failed its integrity check.")
                }
            }
        }
        if !manager.fileExists(atPath: assets.path) {
            try validate(resources)
            let staging = assets.deletingLastPathComponent().appending(path: UUID().uuidString)
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: staging) }
            for name in ["PocketConditioning16.mlmodelc", "PocketConditioning256.mlmodelc", "PocketGeneration.mlmodelc"] {
                try manager.copyItem(at: resources.appending(path: name), to: staging.appending(path: name))
            }
            do { try manager.moveItem(at: staging, to: assets) }
            catch { if !manager.fileExists(atPath: assets.path) { throw error } }
        }
        try validate(assets)
        let repo = directory.appending(path: "Models/\(Repo.pocketTts.folderName)")
        let english = repo.appending(path: "v2.1/english")
        try manager.createDirectory(at: english, withIntermediateDirectories: true)
        func link(_ name: String, to destination: URL, in parent: URL) throws {
            let url = parent.appending(path: name)
            if (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                guard url.resolvingSymlinksInPath().standardizedFileURL.path == destination.resolvingSymlinksInPath().standardizedFileURL.path else {
                    throw CallAudioError.unavailable("The speech cache view has an unexpected target.")
                }
            } else {
                try manager.createSymbolicLink(at: url, withDestinationURL: destination)
            }
        }
        for source in try manager.contentsOfDirectory(at: snapshot.appending(path: "v2.1/english"), includingPropertiesForKeys: nil) {
            guard !["cond_prefill_ane.mlmodelc", "flowlm_step_ane.mlmodelc"].contains(source.lastPathComponent) else { continue }
            try link(source.lastPathComponent, to: source, in: english)
        }
        try link("cond_prefill_ane.mlmodelc", to: assets.appending(path: "PocketConditioning256.mlmodelc"), in: english)
        try link("cond_prefill_ane_small.mlmodelc", to: assets.appending(path: "PocketConditioning16.mlmodelc"), in: english)
        try link("flowlm_step_ane.mlmodelc", to: assets.appending(path: "PocketGeneration.mlmodelc"), in: english)
        try link("mimi_encoderv2.mlmodelc", to: snapshot.appending(path: "mimi_encoderv2.mlmodelc"), in: repo)
        prepared.insert(directory)
    }
}
