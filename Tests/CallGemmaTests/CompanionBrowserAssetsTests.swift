#if os(macOS)
import XCTest
@testable import CallGemma

final class CompanionBrowserAssetsTests: XCTestCase {
    func testManifestAdmissionAndVersionedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = String(repeating: "a", count: 64)
        let body = Data([0, 97, 115, 109])
        try body.write(to: root.appending(path: "module.wasm"))
        func writeManifest(name: String, bytes: Int) throws {
            let value: [String: Any] = ["revision": revision, "files": [name: ["sha256": revision, "bytes": bytes]]]
            try JSONSerialization.data(withJSONObject: value).write(to: root.appending(path: "manifest.json"))
        }
        try writeManifest(name: "module.wasm", bytes: body.count)
        let assets = try CompanionBrowserAssets(root: root)
        let response = try XCTUnwrap(assets.response(path: assets.basePath + "module.wasm"))
        XCTAssertEqual(response.type, "application/wasm")
        XCTAssertEqual(response.body, body)
        XCTAssertNil(try assets.response(path: "/runtime/old/module.wasm"))
        XCTAssertNil(try assets.response(path: assets.basePath + "manifest.json"))
        XCTAssertNil(try assets.response(path: assets.basePath + "../module.wasm"))
        try writeManifest(name: "module.wasm", bytes: body.count + 1)
        XCTAssertThrowsError(try CompanionBrowserAssets(root: root).response(path: assets.basePath + "module.wasm"))
        for name in ["../secret", "/secret", "sub//file", "sub/./file", "sub\\file"] {
            try writeManifest(name: name, bytes: 0)
            XCTAssertThrowsError(try CompanionBrowserAssets(root: root))
        }
    }
}
#endif
