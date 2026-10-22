import Foundation

struct MemoryBudget: Sendable {
    let physicalBytes: UInt64
    let availableBytes: UInt64
}

enum ModelPolicy {
    static let gibibyte: UInt64 = 1 << 30
    static let minimumContextTokens = 2_048
    static let bytesPerContextToken: UInt64 = 160 * 1_024

    static func artifact(physicalBytes: UInt64) -> ModelArtifact {
        // Preserve the qualified desktop model: its streaming audio encoder and
        // MTP verifier have different latency from the compact model. Actual
        // available-memory admission still runs before either model is loaded.
        return physicalBytes >= 16 * gibibyte ? .gemma12B : .gemmaE4B
    }

    /// This estimate is an admission policy, not an allocation guarantee. The
    /// runtime still reports allocation failures and system memory can change.
    static func contextTokens(for artifact: ModelArtifact, memory: MemoryBudget) throws -> Int {
        // Leave at least 3 GiB of physical RAM for macOS and other applications,
        // and 1 GiB of the currently reclaimable budget for speech and headroom.
        let systemReserve = max(3 * gibibyte, memory.physicalBytes / 4)
        let available = min(memory.availableBytes, memory.physicalBytes)
        guard memory.physicalBytes > systemReserve, available > gibibyte else {
            throw ModelStoreError.insufficientMemory
        }
        let modelBudget = min(memory.physicalBytes - systemReserve, available - gibibyte)

        // Rounded above the publisher's macOS GPU footprints. These include
        // weights, fixed KV rows, audio and drafter working space. The additional
        // 160 KiB/token allowance remains conservative pending physical-phone
        // qualification. Capture now bounds changed bytes to 32 MiB per snapshot
        // plus a 32-byte hash per 4 KiB block, rather than full KV byte arrays.
        // E4B's live cache uses 28 KiB/token; do not infer jetsam headroom from Mac tests.
        let fixedBytes = artifact == .gemma12B ? 8 * gibibyte : 7 * gibibyte / 2
        guard modelBudget > fixedBytes else { throw ModelStoreError.insufficientMemory }
        let affordableTokens = (modelBudget - fixedBytes) / bytesPerContextToken
        let policyMaximum: Int
        switch memory.physicalBytes {
        case ..<(12 * gibibyte): policyMaximum = 4_096
        case ..<(24 * gibibyte): policyMaximum = 8_192
        case ..<(32 * gibibyte): policyMaximum = 16_384
        default: policyMaximum = 32_768
        }
        let maximum = min(policyMaximum, artifact.maximumContextTokens)
        let requested = Int(min(affordableTokens, UInt64(maximum)))
        guard requested >= minimumContextTokens else { throw ModelStoreError.insufficientMemory }
        return try alignedContextCapacity(requested: requested, maximum: maximum)
    }

    /// Metal KV persistence currently requires a capacity divisible by four.
    /// Check bounds before rounding so an invalid request cannot become valid
    /// by silently reducing it. This value must be used before engine creation.
    static func alignedContextCapacity(
        requested: Int, maximum: Int, minimum: Int = minimumContextTokens
    ) throws -> Int {
        guard minimum >= 4, maximum >= minimum,
              requested >= minimum, requested <= maximum else {
            throw ModelStoreError.invalidContextCapacity
        }
        let aligned = requested - requested % 4
        guard aligned >= minimum else { throw ModelStoreError.invalidContextCapacity }
        return aligned
    }
}

enum ModelStoreError: LocalizedError {
    case requiredQATUnavailable
    case preparationInProgress
    case insufficientMemory
    case memoryQueryFailed
    case invalidContextCapacity
    case invalidArtifact
    case artifactChanged
    case insufficientDiskSpace

    var errorDescription: String? {
        switch self {
        case .requiredQATUnavailable:
            return "An official LiteRT bundle with verified QAT provenance, audio and MTP has not been identified. You can explicitly choose the available LiteRT model."
        case .preparationInProgress:
            return "A model is already being prepared."
        case .insufficientMemory:
            return "There is not enough available memory for this model and a 2,048-token context. Close other applications and try again."
        case .memoryQueryFailed:
            return "Available system memory could not be measured. Try again before loading the model."
        case .invalidContextCapacity:
            return "The requested context is outside the supported bounds or too small after Metal alignment."
        case .invalidArtifact:
            return "The downloaded model does not match its pinned size and SHA-256. Its local download was removed; try again."
        case .artifactChanged:
            return "The model file changed while it was being verified. Try again."
        case .insufficientDiskSpace:
            return "There is not enough free disk space for the model download and its temporary files."
        }
    }
}
