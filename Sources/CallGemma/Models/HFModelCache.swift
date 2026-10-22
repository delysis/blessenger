import Foundation
import HuggingFace

/// Use the same content-addressed snapshots as Python and other HF clients.
/// HubCache resolves HF_HUB_CACHE, HF_HOME and the platform's default HF cache.
enum HFModelCache {
    static var root: URL { HubCache.default.cacheDirectory }

    static func snapshot(repository: String, revision: String, files: [String],
                         progress: (@MainActor @Sendable (Progress) -> Void)? = nil) async throws -> URL {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        let repo = Repo.ID(namespace: parts[0], name: parts[1])
        let cache = HubCache.default
        if let directory = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: revision),
           files.allSatisfy({ FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }) {
            return directory
        }
        let client = HubClient(cache: cache)
        let snapshot = try await client.downloadSnapshot(of: repo, revision: revision,
            matching: files, progressHandler: progress)
        // A cached repository listing can omit optional assets requested later.
        // Do not treat an existing partial snapshot as completion: fetch every
        // missing pinned path through the same HF content-addressed cache.
        for file in files where !FileManager.default.fileExists(atPath: snapshot.appending(path: file).path) {
            try Task.checkCancellation()
            _ = try await client.downloadFile(at: file, from: repo, revision: revision)
        }
        return snapshot
    }

    /// FluidAudio expects a small directory view. Its files stay in HF snapshots;
    /// the view contains only a symlink, never a second model download.
    static func fluidDirectory(repository: String, revision: String, folder: String, snapshot: URL) throws -> URL {
        let base = root.appending(path: ".callgemma/fluidaudio/\(revision)")
        let link = base.appending(path: "Models/\(folder)")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: link.path) {
            guard link.resolvingSymlinksInPath().standardizedFileURL.path == snapshot.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw CallAudioError.unavailable("The speech cache view points to a different snapshot.")
            }
        } else {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: snapshot)
        }
        return base
    }
}
