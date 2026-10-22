import Darwin
import Foundation

/// At most one active write and one replacement snapshot. The pending snapshot
/// supersedes older pending turns; only complete durable generations are exposed.
actor CheckpointWriter {
    typealias Write = @Sendable () throws -> Void
    private var pending: Write?
    private var worker: Task<Void, Never>?
    private var failure: (any Error)?

    func submit(_ write: @escaping Write) throws {
        try check()
        pending = write
        if worker == nil {
            worker = Task { await run() }
        }
    }

    func check() throws {
        if let failure { throw failure }
    }

    func flush() async throws {
        while let worker { await worker.value }
        try check()
    }

    /// Explicit shutdown/setup retry retains the latest immutable snapshot.
    /// Normal turn admission never hides a prior durability failure.
    func retryAndFlush() async throws {
        if failure != nil {
            failure = nil
            if pending != nil, worker == nil { worker = Task { await run() } }
        }
        try await flush()
    }

    private func take() -> Write? {
        let result = pending
        pending = nil
        return result
    }

    private func run() async {
        while let write = take() {
            let result = await Task.detached(priority: .utility) { () -> Result<Void, any Error> in
                Result { try write() }
            }.value
            if case .failure(let error) = result {
                failure = error
                if pending == nil { pending = write }
                break
            }
        }
        worker = nil
    }
}

/// Advisory only: publication and recovery never wait for cache warming.
/// APFS clones can be durable while their pages are cold in the VM cache.
/// Replacing the hint cancels the old traversal between bounded requests.
final class CheckpointReadAhead: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func schedule(_ url: URL) {
        lock.withLock {
            task?.cancel()
            task = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return }
                let fd = open(url.path, O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { return } // A hint must never alter durability status.
                defer { Darwin.close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_size > 0 else { return }
                let start = LatencyTrace.now()
                defer { AudioTrace.latency.duration("checkpoint.read_ahead", since: start) }
                var offset: off_t = 0
                while offset < info.st_size && !Task.isCancelled {
                    let count = Int32(min(off_t(8 * 1024 * 1024), info.st_size - offset))
                    var advice = radvisory(ra_offset: offset, ra_count: count)
                    guard fcntl(fd, F_RDADVISE, &advice) == 0 else { return }
                    offset += off_t(count)
                }
            }
        }
    }

    func cancel() {
        lock.withLock { task?.cancel(); task = nil }
    }

    deinit { task?.cancel() }
}
