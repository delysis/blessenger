#if os(macOS)
import Foundation

/// Only manifest-listed build artifacts are served. The revision is part of
/// every URL so a cached voice/model cannot silently outlive an app update.
struct CompanionBrowserAssets: Sendable {
    struct Manifest: Decodable, Sendable {
        struct File: Decodable, Sendable { let sha256: String; let bytes: Int }
        let revision: String
        let files: [String: File]
    }
    let root: URL
    let manifest: Manifest

    init(root: URL) throws {
        self.root = root
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appending(path: "manifest.json")))
        guard manifest.revision.count == 64, manifest.revision.allSatisfy(\.isHexDigit),
              manifest.files.count <= 128,
              manifest.files.allSatisfy({ name, file in
                  !name.hasPrefix("/") && !name.contains("\\") &&
                  name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) &&
                  file.bytes >= 0 && file.bytes <= 300_000_000 &&
                  file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit)
              }) else { throw GemmaError(message: "Invalid browser runtime manifest.") }
    }

    var basePath: String { "/runtime/\(manifest.revision)/" }
    func response(path: String) throws -> CompanionResponse? {
        guard path.hasPrefix(basePath) else { return nil }
        let name = String(path.dropFirst(basePath.count))
        guard let record = manifest.files[name] else { return nil }
        let url = root.appending(path: name)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            throw GemmaError(message: "Browser asset escaped its bundle.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == record.bytes else { throw GemmaError(message: "Browser asset size mismatch.") }
        let type: String
        switch url.pathExtension {
        case "js", "mjs": type = "text/javascript"
        case "wasm": type = "application/wasm"
        case "json": type = "application/json"
        default: type = "application/octet-stream"
        }
        return CompanionResponse(type: type, body: data)
    }
}
#endif
