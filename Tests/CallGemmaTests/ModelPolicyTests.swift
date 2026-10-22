import Testing
@testable import CallGemma

struct ModelPolicyTests {
    @Test func testDesktopRetainsQualified12BAndSmallDevicesUseCompactModel() {
        #expect(ModelPolicy.artifact(physicalBytes: 16 * ModelPolicy.gibibyte - 1) == .gemmaE4B)
        #expect(ModelPolicy.artifact(physicalBytes: 16 * ModelPolicy.gibibyte) == .gemma12B)
        #expect(ModelPolicy.artifact(physicalBytes: 128 * ModelPolicy.gibibyte) == .gemma12B)
    }

    @Test func testEachRemainderUsesTheSameMetalCapacity() throws {
        for remainder in 0...3 {
            #expect(try ModelPolicy.alignedContextCapacity(
                requested: 4_096 + remainder, maximum: 8_192) == 4_096)
        }
    }

    @Test func testInvalidRequestsCannotBeRescuedByRounding() {
        for request in [Int.min, -1, 0, 1, 2, 3, 2_047, 8_193] {
            #expect(throws: ModelStoreError.self) {
                try ModelPolicy.alignedContextCapacity(requested: request, maximum: 8_192)
            }
        }
        #expect(throws: ModelStoreError.self) {
            try ModelPolicy.alignedContextCapacity(requested: 4, maximum: 4, minimum: 0)
        }
        #expect(throws: ModelStoreError.self) {
            try ModelPolicy.alignedContextCapacity(requested: 2_049, maximum: 4_096, minimum: 2_049)
        }
        #expect(throws: ModelStoreError.self) {
            try ModelPolicy.alignedContextCapacity(requested: 4_096, maximum: 2_047)
        }
    }

    @Test func testSmallestAlignedCapacityAndUpperBoundary() throws {
        #expect(try ModelPolicy.alignedContextCapacity(requested: 4, maximum: 4, minimum: 4) == 4)
        #expect(try ModelPolicy.alignedContextCapacity(requested: 131_071, maximum: 131_071) == 131_068)
    }

    @Test func testAvailableMemoryCanBlockAnOtherwiseSuitableMac() {
        #expect(throws: ModelStoreError.self) {
            try ModelPolicy.contextTokens(
                for: .gemma12B,
                memory: MemoryBudget(physicalBytes: 16 * ModelPolicy.gibibyte, availableBytes: 8 * ModelPolicy.gibibyte))
        }
        #expect(throws: ModelStoreError.self) {
            try ModelPolicy.contextTokens(
                for: .gemmaE4B,
                memory: MemoryBudget(physicalBytes: 8 * ModelPolicy.gibibyte, availableBytes: 4 * ModelPolicy.gibibyte))
        }
    }

    @Test func testBudgetIsMonotonicAndKeepsContextAligned() throws {
        let physical = 16 * ModelPolicy.gibibyte
        var previous = 0
        for extraTokens in stride(from: 2_048, through: 8_200, by: 127) {
            let context = try ModelPolicy.contextTokens(
                for: .gemma12B,
                memory: MemoryBudget(
                    physicalBytes: physical,
                    availableBytes: 9 * ModelPolicy.gibibyte + UInt64(extraTokens) * ModelPolicy.bytesPerContextToken
                )
            )
            #expect(context % 4 == 0)
            #expect(context >= previous)
            #expect(context <= 8_192)
            previous = context
        }
    }

    @Test func testEightGiBMacRetainsAConservativeContext() throws {
        #expect(try ModelPolicy.contextTokens(
            for: .gemmaE4B,
            memory: MemoryBudget(physicalBytes: 8 * ModelPolicy.gibibyte, availableBytes: 6 * ModelPolicy.gibibyte)
        ) == 4_096)
    }
}
