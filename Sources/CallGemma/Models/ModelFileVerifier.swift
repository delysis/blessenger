import CryptoKit
import Foundation

enum ModelFileVerifier {
    private struct Fingerprint: Codable, Equatable {
        let bytes: UInt64
        let modified: Date
        let inode: UInt64

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let date = attributes[.modificationDate] as? Date,
                  let fileNumber = attributes[.systemFileNumber] as? NSNumber else {
                throw ModelStoreError.invalidArtifact
            }
            bytes = size.uint64Value
            modified = date
            inode = fileNumber.uint64Value
        }
    }

    private struct Receipt: Codable {
        let version: Int
        let sha256: String
        let fingerprint: Fingerprint
    }

    /// A receipt avoids rereading gigabytes on each launch. It is valid only for
    /// the same pinned digest and unchanged local file identity, size and mtime.
    /// This trusts the app's local model directory; it is not tamper detection
    /// against another process that can rewrite the file and its timestamps.
    static func hasValidReceipt(file: URL, receipt: URL, artifact: ModelArtifact) -> Bool {
        guard let fingerprint = try? Fingerprint(url: file),
              fingerprint.bytes == artifact.byteCount,
              let handle = try? FileHandle(forReadingFrom: receipt) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_097), data.count <= 4_096,
              let saved = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
        return saved.version == 1 && saved.sha256 == artifact.sha256
            && saved.fingerprint == fingerprint
    }

    static func verify(
        file: URL, receipt: URL, artifact: ModelArtifact,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws {
        try Task.checkCancellation()
        let before = try Fingerprint(url: file)
        guard before.bytes == artifact.byteCount else { throw ModelStoreError.invalidArtifact }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var readBytes: UInt64 = 0
        var lastReported: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let count: Int = try autoreleasepool {
                let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
                hasher.update(data: chunk)
                return chunk.count
            }
            if count == 0 { break }
            readBytes += UInt64(count)
            guard readBytes <= artifact.byteCount else { throw ModelStoreError.artifactChanged }
            if readBytes - lastReported >= 64 * 1_048_576 || readBytes == artifact.byteCount {
                progress(Double(readBytes) / Double(artifact.byteCount))
                lastReported = readBytes
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard readBytes == artifact.byteCount, digest == artifact.sha256 else {
            throw ModelStoreError.invalidArtifact
        }
        let after = try Fingerprint(url: file)
        guard before == after else { throw ModelStoreError.artifactChanged }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(Receipt(version: 1, sha256: digest, fingerprint: after))
        try data.write(to: receipt, options: .atomic)
    }
}
