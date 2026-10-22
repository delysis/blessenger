import Foundation
import Security

// First-install bootstrap only. Blessenger imports this legacy item into its
// app-owned Keychain item on first use. This tool does not rotate an existing
// app-owned credential.
// Compile once, then pipe {"id":...,"token":...} to stdin. Never pass the
// credential in argv, environment variables, console output, or a shell script.
struct TURNKey: Codable { let id: String; let token: String }
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 2 else { fail("Usage: import-turn-key TRUSTED_APP_PATH | --validate") }
let input = FileHandle.standardInput.readData(ofLength: 16_385)
guard input.count <= 16_384, let key = try? JSONDecoder().decode(TURNKey.self, from: input),
      !key.id.isEmpty, key.id.count <= 128,
      key.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
      !key.token.isEmpty, key.token.count <= 8192,
      key.token.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else {
    fail("Invalid TURN credential input")
}
if CommandLine.arguments[1] == "--validate" { print("Credential format valid"); exit(0) }
let appPath = CommandLine.arguments[1]
guard appPath.hasPrefix("/"), appPath.hasSuffix(".app"),
      FileManager.default.fileExists(atPath: appPath) else { fail("Trusted app must be an existing absolute app path") }
var app: SecTrustedApplication?
guard SecTrustedApplicationCreateFromPath(appPath, &app) == errSecSuccess, let app else {
    fail("Could not establish the trusted app identity")
}
var access: SecAccess?
guard SecAccessCreate("Blessenger TURN relay credential" as CFString, [app] as CFArray, &access) == errSecSuccess,
      let access else { fail("Could not create Keychain access control") }
let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "Blessenger.CloudflareTURN", kSecAttrAccount as String: "credentials",
    kSecAttrLabel as String: "Blessenger Cloudflare TURN", kSecAttrAccess as String: access,
    kSecValueData as String: try JSONEncoder().encode(key)]
let status = SecItemAdd(item as CFDictionary, nil)
guard status == errSecSuccess else {
    // Do not replace an existing credential or weaken its access policy.
    fail(status == errSecDuplicateItem ? "TURN credential already exists; no change made" : "Keychain import failed (\(status))")
}
print("TURN credential stored in Keychain for Blessenger")
