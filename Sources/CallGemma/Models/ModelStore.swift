import Combine
import Foundation
import HuggingFace

@MainActor
final class ModelStore: ObservableObject {
    enum Status: Equatable {
        case idle
        case needsModelChoice
        case downloading
        case verifying
        case cancelling
        case cancelled
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var progress: Double?
    @Published private(set) var selectedArtifact: ModelArtifact

    private let directory: URL
    private var preparation: Task<URL, Error>?
    private var activeID: UUID?

    init(directory: URL? = nil) {
        self.directory = directory ?? HFModelCache.root
        selectedArtifact = ModelPolicy.artifact(physicalBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// Opting into the available bundle is a separate, visible user choice;
    /// these exact artifacts have not been verified as the requested QAT release.
    func prepare(
        authToken: String? = nil, allowUnverifiedQAT: Bool = false
    ) async throws -> PreparedModel {
        guard preparation == nil else { throw ModelStoreError.preparationInProgress }
        guard allowUnverifiedQAT else {
            status = .needsModelChoice
            throw ModelStoreError.requiredQATUnavailable
        }
        let memory: MemoryBudget
        do {
            memory = try SystemMemory.sample()
            selectedArtifact = ModelPolicy.artifact(physicalBytes: memory.physicalBytes)
            _ = try ModelPolicy.contextTokens(for: selectedArtifact, memory: memory)
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }

        let artifact = selectedArtifact
        let root = directory
        let id = UUID()
        activeID = id
        progress = nil
        status = .verifying
        let store = self
        let task = Task.detached(priority: .userInitiated) {
            try await Self.obtain(artifact, root: root, authToken: authToken) { event in
                Task { @MainActor [weak self = store] in
                    guard let self, self.activeID == id, self.status != .cancelling else { return }
                    switch event {
                    case .downloading(let fraction):
                        self.status = .downloading
                        self.progress = fraction
                    case .verifying(let fraction):
                        self.status = .verifying
                        self.progress = fraction
                    }
                }
            }
        }
        preparation = task
        defer {
            activeID = nil
            preparation = nil
        }
        do {
            let file = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard !task.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            // Downloading can take minutes. Re-sample immediately before the
            // caller creates its engine instead of reusing the initial budget.
            let context = try ModelPolicy.contextTokens(for: artifact, memory: SystemMemory.sample())
            status = .ready
            progress = 1
            return PreparedModel(
                modelURL: file,
                modelID: artifact.repository,
                revision: artifact.revision,
                contextTokens: context,
                artifactSHA256: artifact.sha256,
                supportsAudio: artifact.supportsAudio,
                enableMTP: artifact.enableMTP,
                provenance: artifact.provenance
            )
        } catch {
            if error is CancellationError || task.isCancelled {
                status = .cancelled
            } else {
                status = .failed(error.localizedDescription)
            }
            progress = nil
            throw error
        }
    }

    func cancel() {
        guard let preparation else { return }
        status = .cancelling
        preparation.cancel()
    }

    private enum TransferEvent: Sendable {
        case downloading(Double?)
        case verifying(Double)
    }

    nonisolated private static func obtain(
        _ artifact: ModelArtifact, root: URL, authToken: String?,
        event: @escaping @Sendable (TransferEvent) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let manager = FileManager.default
        let parts = artifact.repository.split(separator: "/", maxSplits: 1).map(String.init)
        let repo = Repo.ID(namespace: parts[0], name: parts[1])
        let cache = HubCache(cacheDirectory: root)
        let receiptDirectory = root.appending(path: ".callgemma/verified")
        try manager.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        let receipt = receiptDirectory.appending(path: artifact.sha256 + ".json")
        event(.downloading(nil))
        let client = authToken.map {
            HubClient(host: URL(string: "https://huggingface.co")!, bearerToken: $0, cache: cache)
        } ?? HubClient(cache: cache)
        let snapshotFile = try await client.downloadFile(at: artifact.filename, from: repo, revision: artifact.revision)
        // Standard HF snapshot files are symlinks to immutable content blobs.
        // Verify the actual blob, and never delete shared cache contents on failure.
        let file = snapshotFile.resolvingSymlinksInPath()
        try Task.checkCancellation()
        if ModelFileVerifier.hasValidReceipt(file: file, receipt: receipt, artifact: artifact) { return snapshotFile }
        event(.verifying(0))
        try ModelFileVerifier.verify(file: file, receipt: receipt, artifact: artifact) {
            event(.verifying($0))
        }
        return snapshotFile
    }
}
