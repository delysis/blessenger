import Foundation

enum RuntimeIdentity {
    static func load() throws -> String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        #if os(iOS)
        let resource = "runtime-ios"
        #else
        let resource = "runtime"
        #endif
        guard let url = bundle.url(forResource: resource, withExtension: "json"),
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String],
              let sha = value["sha256"], sha.count == 64,
              sha.allSatisfy({ $0.isHexDigit }) else {
            throw GemmaError(message: "Build the patched runtime with Tools/build-runtime.sh, then rebuild Blessenger.")
        }
        return sha
    }
}
