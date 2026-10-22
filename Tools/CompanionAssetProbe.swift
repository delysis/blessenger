// Compile with the actual CompanionHTTP and CompanionBrowserAssets sources.
// Diagnostic listener: existing TLS identity and pairing cookie, assets only.
import Foundation
struct GemmaError: Error { let message: String }

@main struct CompanionAssetProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("Expected asset root and companion configuration directory") }
        let root = URL(fileURLWithPath: args[2])
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: root.appending(path: "configuration.json")))
        let assets = try CompanionBrowserAssets(root: URL(fileURLWithPath: args[1]))
        let server = try CompanionHTTP(identity: Data(contentsOf: root.appending(path: "server.p12")), password: config.password, port: 8944) { request in
            guard request.method == "GET", request.headers["host"] == "\(config.host):8944",
                  request.headers["cookie"] == "blessenger=\(config.session)" else {
                return .json(["error": "Unauthorized"], status: 401)
            }
            do { return try assets.response(path: request.path) ?? .json(["error": "Not found"], status: 404) }
            catch { return .json(["error": "Asset unavailable"], status: 500) }
        }
        server.start { error in
            let line = error == nil ? "ready\n" : "listener failed\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        try await Task.sleep(for: .seconds(120))
        server.stop()
    }
    struct Config: Decodable, Sendable { let host: String; let password: String; let session: String }
}
