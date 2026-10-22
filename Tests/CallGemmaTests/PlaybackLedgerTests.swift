import Foundation
import Testing
@testable import CallGemma

struct PlaybackLedgerTests {
    @Test func generatedAndQueuedTextIsNotDelivered() throws {
        let response = UUID(), segment = UUID()
        var ledger = PlaybackLedger(response: response)
        try ledger.beginSegment(segment, text: "Never played.")
        _ = try ledger.schedule([1, 2, 3, 4], segment: segment)
        try ledger.seal(segment)
        #expect(ledger.receipt().completedText.isEmpty)
        #expect(ledger.receipt().partialPCM.isEmpty)
    }

    @Test func interruptionKeepsExactDeliveredPCMWithoutInventingWords() throws {
        let response = UUID(), first = UUID(), second = UUID()
        var ledger = PlaybackLedger(response: response)
        try ledger.beginSegment(first, text: "Heard.")
        _ = try ledger.schedule([1, 2], segment: first)
        try ledger.seal(first)
        try ledger.beginSegment(second, text: "Partly heard sentence.")
        _ = try ledger.schedule([3, 4, 5, 6], segment: second)
        ledger.delivered(through: 4, response: response)
        let receipt = ledger.receipt()
        #expect(receipt.completedText == ["Heard."])
        #expect(receipt.partialText == "Partly heard sentence.")
        #expect(receipt.partialPCM == [3, 4])
        #expect(receipt.deliveredFrames == 4)
        #expect(receipt.scheduledFrames == 6)
    }

    @Test func lateCallbacksAndRenderPositionsCannotOverCommit() throws {
        let response = UUID(), segment = UUID()
        var ledger = PlaybackLedger(response: response)
        try ledger.beginSegment(segment, text: "Done.")
        _ = try ledger.schedule([1, 2], segment: segment)
        ledger.delivered(through: 999, response: UUID())
        #expect(ledger.deliveredFrames == 0)
        ledger.delivered(through: 999, response: response)
        #expect(ledger.deliveredFrames == 2)
        #expect(ledger.receipt().completedText.isEmpty) // Synthesis not sealed.
        try ledger.seal(segment)
        ledger.delivered(through: 0, response: response)
        #expect(ledger.receipt().completedText == ["Done."])
        #expect(ledger.receipt().partialPCM.isEmpty)
    }
}
