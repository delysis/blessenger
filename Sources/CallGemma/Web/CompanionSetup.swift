#if os(macOS)
import Foundation

/// Local credentials only; installation never adds a root certificate to system trust.
enum CompanionSetup {
    static func create(at root: URL) throws {
        if FileManager.default.fileExists(atPath: root.appending(path: "configuration.json").path) { return }
        let parent = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: root.path) else { throw GemmaError(message: "An incomplete companion setup already exists.") }
        let temporary = parent.appending(path: ".companion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let hostData = try run("/usr/sbin/scutil", ["--get", "LocalHostName"], at: temporary)
        let host = String(decoding: hostData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) + ".local"
        guard host.count > 6, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else {
            throw GemmaError(message: "The Mac needs a valid local hostname.")
        }
        let ca = """
        [req]
        distinguished_name=dn
        x509_extensions=ca
        prompt=no
        [dn]
        CN=Blessenger \(host)
        [ca]
        basicConstraints=critical,CA:true,pathlen:0
        keyUsage=critical,keyCertSign,cRLSign
        subjectKeyIdentifier=hash
        nameConstraints=critical,permitted;DNS:\(host)
        """
        let leaf = """
        [req]
        distinguished_name=dn
        prompt=no
        [dn]
        CN=\(host)
        [server]
        basicConstraints=critical,CA:false
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectKeyIdentifier=hash
        authorityKeyIdentifier=keyid,issuer
        subjectAltName=DNS:\(host)
        """
        try Data(ca.utf8).write(to: temporary.appending(path: "ca.cnf"))
        try Data(leaf.utf8).write(to: temporary.appending(path: "server.cnf"))
        _ = try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650", "-sha256", "-config", "ca.cnf", "-keyout", "ca.key", "-out", "ca.pem"], at: temporary)
        _ = try run("/usr/bin/openssl", ["req", "-newkey", "rsa:2048", "-nodes", "-config", "server.cnf", "-keyout", "server.key", "-out", "server.csr"], at: temporary)
        _ = try run("/usr/bin/openssl", ["x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "0x" + UUID().uuidString.replacingOccurrences(of: "-", with: ""), "-days", "365", "-sha256", "-extfile", "server.cnf", "-extensions", "server", "-out", "server.pem"], at: temporary)
        let password = secret()
        _ = try run("/usr/bin/openssl", ["pkcs12", "-export", "-in", "server.pem", "-inkey", "server.key", "-certfile", "ca.pem", "-out", "server.p12", "-passout", "env:BLESSENGER_P12_PASSWORD"], at: temporary, password: password)
        _ = try run("/usr/bin/openssl", ["x509", "-in", "ca.pem", "-outform", "DER", "-out", "Blessenger.cer"], at: temporary)
        let configuration: [String: Any] = ["host": host, "port": 8943, "password": password, "invite": secret(), "session": secret()]
        try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted]).write(to: temporary.appending(path: "configuration.json"))
        let keep = Set(["ca.key", "ca.pem", "server.p12", "Blessenger.cer", "configuration.json"])
        for file in try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
            if keep.contains(file.lastPathComponent) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            else { try FileManager.default.removeItem(at: file) }
        }
        try FileManager.default.moveItem(at: temporary, to: root)
    }
    private static func secret() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "") }
    private static func run(_ executable: String, _ arguments: [String], at directory: URL, password: String? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = directory
        if let password { process.environment = ["BLESSENGER_P12_PASSWORD": password] }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GemmaError(message: "Local certificate setup failed: \(URL(fileURLWithPath: executable).lastPathComponent).") }
        return data
    }
}
#endif
