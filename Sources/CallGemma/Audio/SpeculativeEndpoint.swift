import Foundation

/// Generation may run before confirmation; playback and durable admission may not.
@MainActor
final class SpeculativeEndpoint {
    let id: UUID
    private enum State { case pending, confirmed, revoked }
    private var state = State.pending
    private var inputAdmission: (@Sendable () async throws -> Void)?
    private(set) var inputConfirmed = false
    private var waiter: CheckedContinuation<Void, Error>?

    init(id: UUID) { self.id = id }

    // The user input becomes accepted at the strict endpoint, independently
    // of whether any generated reply has reached the speaker.
    func bindInputAdmission(_ action: @escaping @Sendable () async throws -> Void) async throws {
        precondition(inputAdmission == nil)
        inputAdmission = action
        if inputConfirmed { try await action() }
    }

    func confirm() async throws {
        guard case .pending = state else { return }
        inputConfirmed = true
        try await inputAdmission?()
        // A barge-in during the durable write can revoke playback, but cannot
        // undo acceptance of the preceding user utterance.
        guard case .pending = state else { return }
        state = .confirmed
        waiter?.resume()
        waiter = nil
    }

    func revoke() {
        state = .revoked
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            switch state {
            case .confirmed: return
            case .revoked: throw CancellationError()
            case .pending:
                try await withCheckedThrowingContinuation { waiter = $0 }
            }
            try Task.checkCancellation()
        } onCancel: { Task { @MainActor in self.revoke() } }
    }
}
