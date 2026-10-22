import Foundation
import XCTest
@testable import CallGemma

final class ModelFileVerifierTests: XCTestCase {
    private let artifact = ModelArtifact(
        name: "Tiny integrity fixture", repository: "test/model", revision: String(repeating: "a", count: 40),
        filename: "model.litertlm", byteCount: 3,
        sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        maximumContextTokens: 4_096, supportsAudio: false, enableMTP: false
    )

    func testVerifiedFileReusesReceiptAndReplacementInvalidatesIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "model.litertlm")
        let receipt = directory.appending(path: "verified.json")
        try Data("abc".utf8).write(to: file)
        XCTAssertFalse(ModelFileVerifier.hasValidReceipt(file: file, receipt: receipt, artifact: artifact))
        try ModelFileVerifier.verify(file: file, receipt: receipt, artifact: artifact)
        XCTAssertTrue(ModelFileVerifier.hasValidReceipt(file: file, receipt: receipt, artifact: artifact))
        let replacement = directory.appending(path: "replacement")
        try Data("abc".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        XCTAssertFalse(ModelFileVerifier.hasValidReceipt(file: file, receipt: receipt, artifact: artifact))
    }

    func testCorruptAndTruncatedFilesNeverReceiveReceipts() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "model.litertlm")
        let receipt = directory.appending(path: "verified.json")
        for contents in ["ab", "abd"] {
            try Data(contents.utf8).write(to: file)
            XCTAssertThrowsError(try ModelFileVerifier.verify(file: file, receipt: receipt, artifact: artifact))
            XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        }
    }

    func testMalformedReceiptDoesNotBypassVerification() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "model.litertlm")
        let receipt = directory.appending(path: "verified.json")
        try Data("abc".utf8).write(to: file)
        try Data(repeating: 0x20, count: 4_097).write(to: receipt)
        XCTAssertFalse(ModelFileVerifier.hasValidReceipt(file: file, receipt: receipt, artifact: artifact))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
