import Foundation

struct ModelArtifact: Equatable, Sendable {
    let name: String
    let repository: String
    let revision: String
    let filename: String
    let byteCount: UInt64
    let sha256: String
    let maximumContextTokens: Int
    let supportsAudio: Bool
    let enableMTP: Bool

    // The publisher's cards establish the runtime format and capabilities,
    // but do not identify these artifacts as the newer QAT checkpoints.
    var provenance: String { "LiteRT mixed-int4/int8; QAT provenance unverified" }

    static let gemma12B = ModelArtifact(
        name: "Gemma 4 12B IT · LiteRT",
        repository: "litert-community/gemma-4-12B-it-litert-lm",
        revision: "7a0b1ce0ea821bcd01c5f72af84155e02191152f",
        filename: "gemma-4-12B-it.litertlm",
        byteCount: 6_883_278_368,
        sha256: "58fd31b778ca2c21c80d634fb34fc5a89d11d563a38dfd3cbf1b40dbf252a8b6",
        maximumContextTokens: 131_071,
        supportsAudio: true,
        enableMTP: true
    )

    static let gemmaE4B = ModelArtifact(
        name: "Gemma 4 E4B IT · LiteRT",
        repository: "litert-community/gemma-4-E4B-it-litert-lm",
        revision: "e6a3892a8c22cf87ff99583996149cf3cb32452b",
        filename: "gemma-4-E4B-it.litertlm",
        byteCount: 3_659_530_240,
        sha256: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0",
        maximumContextTokens: 32_000,
        supportsAudio: true,
        enableMTP: false
    )
}

struct PreparedModel: Sendable {
    let modelURL: URL
    let modelID: String
    let revision: String
    let contextTokens: Int
    let artifactSHA256: String
    let supportsAudio: Bool
    let enableMTP: Bool
    let provenance: String
}
