import Testing
@testable import CallGemma

struct ForcedTextAlignmentTests {
    @Test func repeatedTokensRequireBlank() throws {
        let spans = try ForcedTextAlignment.align(logProbabilities: [
            [-8, 0], [0, -8], [-8, 0], [0, -8]
        ], tokens: [1, 1], blank: 0)
        #expect(spans == [.init(firstFrame: 0, endFrame: 1), .init(firstFrame: 2, endFrame: 3)])
    }

    @Test func unalignableRepeatedTokensFail() {
        #expect(throws: GemmaError.self) {
            try ForcedTextAlignment.align(logProbabilities: [[-8, 0], [-8, 0]],
                                          tokens: [1, 1], blank: 0)
        }
    }

    @Test func silenceIsNotAssignedToAnotherToken() throws {
        let spans = try ForcedTextAlignment.align(logProbabilities: [
            [0, -8, -8], [-8, 0, -8], [0, -8, -8],
            [0, -8, -8], [-8, -8, 0], [0, -8, -8]
        ], tokens: [1, 2], blank: 0)
        #expect(spans == [.init(firstFrame: 1, endFrame: 2), .init(firstFrame: 4, endFrame: 5)])
    }

    @Test func invalidProbabilitiesFail() {
        #expect(throws: GemmaError.self) {
            try ForcedTextAlignment.align(logProbabilities: [[0, .nan]], tokens: [1], blank: 0)
        }
    }
}
