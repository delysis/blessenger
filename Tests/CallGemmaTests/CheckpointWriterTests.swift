import Foundation
import Testing
@testable import CallGemma

private final class WriteProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var values: [Int] = []
    func waitForStart() { started.wait() }
    func append(_ value: Int) { lock.withLock { values.append(value) } }
    func read() -> [Int] { lock.withLock { values } }
}

@Test func checkpointWriterDoesNotBlockAdmissionAndCoalescesPending() async throws {
    let writer = CheckpointWriter()
    let probe = WriteProbe()
    try await writer.submit {
        probe.started.signal()
        probe.release.wait()
        probe.append(1)
    }
    await Task.detached { probe.waitForStart() }.value
    // The disk write remains blocked throughout both admissions.
    try await writer.submit { probe.append(2) }
    try await writer.submit { probe.append(3) }
    #expect(probe.read().isEmpty)
    probe.release.signal()
    try await writer.flush()
    #expect(probe.read() == [1, 3])
}

@Test func checkpointWriterSurfacesFailureAndRejectsFurtherAdmission() async {
    enum Failed: Error { case disk }
    let writer = CheckpointWriter()
    do {
        try await writer.submit { throw Failed.disk }
        try await writer.flush()
        Issue.record("A failed durable write was hidden")
    } catch {}
    do {
        try await writer.submit { Issue.record("Write accepted after failure") }
        Issue.record("Writer admitted after durability failure")
    } catch {}
}

@Test func checkpointWriterRetryRetainsTheUnpublishedSnapshot() async throws {
    enum Failed: Error { case disk }
    let writer = CheckpointWriter()
    let probe = WriteProbe()
    try await writer.submit {
        probe.append(1)
        if probe.read().count == 1 { throw Failed.disk }
    }
    do { try await writer.flush(); Issue.record("Expected initial I/O failure") } catch {}
    try await writer.retryAndFlush()
    #expect(probe.read() == [1, 1])
}
