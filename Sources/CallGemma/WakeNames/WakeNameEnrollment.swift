import Combine
import Foundation

/// One cancellable training job for the contact catalog. A call takes a frozen
/// trained model, then pauses all enrollment work until the audio session ends.
@MainActor
final class WakeNameEnrollment: ObservableObject {
    static let shared = WakeNameEnrollment()
    enum State: Equatable { case idle, queued, training(Int, Int), ready, rejected, failed(String) }
    @Published private(set) var state: State = .idle
    private(set) var model: WakeNameModel?
    private var contacts: [Persona] = []
    private var task: Task<Void, Never>?
    private var worker: Task<WakeNameTraining.Result, Error>?
    private var suspensionReasons: Set<String> = []
    private var suspended: Bool { !suspensionReasons.isEmpty }
    private var revision = UUID()
    private let directory: URL
    init(directory: URL = AppQualificationEnvironment.messaging.appending(path: "WakeNames")) { self.directory = directory }

    func update(_ contacts: [Persona]) {
        let inputs = contacts.sorted { $0.id.uuidString < $1.id.uuidString }
        guard inputs.map({ "\($0.id)|\($0.wakeName)|\($0.voice ?? "")" }) != self.contacts.map({ "\($0.id)|\($0.wakeName)|\($0.voice ?? "")" }) else { return }
        self.contacts = inputs
        model = nil // An old head must never address an edited/deleted contact.
        schedule()
    }
    func retry() { model = nil; schedule() }
    private func schedule() {
        let previous = task
        task?.cancel(); worker?.cancel()
        revision = UUID()
        guard !contacts.isEmpty else { state = .idle; return }
        state = .queued
        guard !suspended else { return }
        let token = revision, inputs = contacts, directory = directory
        task = Task {
            await previous?.value
            do {
                try await Task.sleep(for: .seconds(2)) // Coalesce edits, outside audio paths.
                try Task.checkCancellation()
                let job = Task.detached(priority: .utility) {
                    let identity = try WakeNameTraining.fingerprint(inputs)
                    let file = directory.appending(path: identity + ".json")
                    if let data = try? Data(contentsOf: file),
                       let cached = try? JSONDecoder().decode(WakeNameTraining.Result.self, from: data),
                       cached.model.fingerprint == identity { return cached }
                    let result = try await WakeNameTraining.train(contacts: inputs, fingerprint: identity, cacheDirectory: directory.appending(path: "Features")) { done, total in
                        await self.progress(done, total, token: token)
                    }
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try JSONEncoder().encode(result).write(to: file, options: .atomic)
                    return result
                }
                worker = job
                let result = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                guard revision == token, !Task.isCancelled else { return }
                model = result.model.accepted ? result.model : nil
                state = result.model.accepted ? .ready : .rejected
            } catch is CancellationError {} catch {
                if revision == token { state = .failed(error.localizedDescription) }
            }
            if revision == token { worker = nil; task = nil }
        }
    }
    private func progress(_ done: Int, _ total: Int, token: UUID) {
        if revision == token, !suspended { state = .training(done, total) }
    }
    func pause(reason: String = "call") async {
        suspensionReasons.insert(reason)
        let token = revision, previous = task
        task?.cancel(); worker?.cancel()
        await previous?.value
        // A contact edit or resume may schedule a new revision during the join.
        guard revision == token else { return }
        task = nil; worker = nil
        if model == nil, !contacts.isEmpty {
            // Dialing can beat the coalescing delay. Pausing training must not
            // discard an already accepted on-disk head for this exact catalog.
            // Only load here: a cache miss never trains or delays pickup for TTS.
            let inputs = contacts, directory = directory
            let cached = await Task.detached(priority: .userInitiated) { () -> WakeNameModel? in
                guard let identity = try? WakeNameTraining.fingerprint(inputs),
                      let data = try? Data(contentsOf: directory.appending(path: identity + ".json")),
                      let result = try? JSONDecoder().decode(WakeNameTraining.Result.self, from: data),
                      result.model.fingerprint == identity, result.model.accepted,
                      result.receipt.accepted else { return nil }
                return result.model
            }.value
            guard revision == token, suspended else { return }
            model = cached
            state = cached == nil ? .queued : .ready
        }
    }
    func resume(reason: String = "call") {
        guard suspensionReasons.remove(reason) != nil else { return }
        if !suspended, model == nil { schedule() }
    }
    var help: String {
        switch state {
        case .idle: return "Set a wake name to train voice selection"
        case .queued: return "Wake-name training queued until the app is idle"
        case .training(let done, let total): return "Training wake names locally: \(done) of \(total)"
        case .ready: return "Wake names trained locally"
        case .rejected: return "Wake-name validation failed; automatic selection remains disabled"
        case .failed(let error): return "Wake-name training failed: \(error)"
        }
    }
}
