import Foundation
import XCTest
@testable import CallGemma

final class ModelStoreTests: XCTestCase {
    @MainActor
    func testRequiredQATDoesNotCreateDownloadDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ModelStore(directory: directory)
        do {
            _ = try await store.prepare()
            XCTFail("Unverified QAT provenance must require an explicit model choice")
        } catch ModelStoreError.requiredQATUnavailable {
            XCTAssertEqual(store.status, .needsModelChoice)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
}
