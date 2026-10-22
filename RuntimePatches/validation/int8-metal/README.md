# Gemma E4B INT8 Metal checkpoint transfer

The pinned E4B export has INT8 K/V tensors. Its native Metal representation is a shared byte buffer, so the FP16-only checkpoint exception did not cover it. LiteRT patch 0005 extends the two existing validated Shared transfer/preflight branches to exactly `MetalBuffer` with the original `Int8` element type. The matching LiteRT-LM codec patch admits its unpadded converted layout. Allocators, model kernels, and decode/prefill loops are unchanged.

## Exact source chain

Sources below use LiteRT commit `9b8c7f77e7a29e6073e614a05e1e38be7b761229` and its ML Drift dependency `1b18771f44c0be3d972847b31a80f6dc3d6964b5`. Full immutable URLs and independently recomputed Git blob/SHA-256 receipts are in `source-receipts.json`.

| Stage | Source | Consequence |
| --- | --- | --- |
| Quantized cache graph | LiteRT `composite/add_values_to_cache_parser.cc:87–120` | Restores the original INT8 TFLite references, removes the intermediate quantization metadata, and sets the GPU graph values to `kUint8`: one physical byte per element. |
| Cache update | LiteRT `composite/add_values_to_cache_kernel.cc:93–114,151–203` | The quantized path writes `uchar4` values to the blocked K/V layout. This is existing inference support for byte KV storage. |
| External descriptor | LiteRT `delegate_kernel_litert.cc:64–85,435–482` | Uses the graph's dtype; only Float32 is changed by precision selection. KV takes the external buffer path. |
| Metal requirements | LiteRT `gpu_backend_metal_litert.mm:106–133` | A byte buffer selects `MetalBuffer`, with the same physical `{16}` marker as other external Metal buffers. It does not select `MetalBufferFp16` or Packed. |
| Allocation and kernel binding | ML Drift `metal_spatial_tensor.mm:63–85`; LiteRT `gpu_backend_metal.mm:306–322` | Buffer allocation explicitly uses Shared storage. The kernel wrapper applies the graph's Uint8 descriptor to the same MTLBuffer, so the original host descriptor's signedness causes no binding mismatch. |
| Host descriptor | LiteRT `buffer_handler_utils.cc:80–86,111–128,137–140,164–167` | The original LiteRT Int8 tensor produces an Int8 HWC/BHWC descriptor; upload and download use `int8_t`. |
| Host permutation | ML Drift `tensor_desc.h:169–221,538–590`, `tensor_desc.cc:1831–1864` | Upload/download use inverse address permutations with equal one-byte element types. They preserve all 256 byte values, including negative signed values and both extremes; no dequantization or float conversion occurs. |
| Checked restore | ML Drift `metal/common.mm:404–425`; LiteRT patch 0005 | The old helper's unchecked staging blit cannot establish restore success. The existing checked Shared descriptor-byte memcpy now covers Int8 too. Private/Managed Int8 buffers reject before host mapping. |

## Admission and tests

The codec requires rank 2–4, positive dimensions, a final dimension divisible by four, only the recognized optional `{16,0,…}` marker, exact physical/logical allocation size, zero offset, and at most `INT_MAX` byte elements. With these bounds the descriptor permutation covers every physical byte; padding cannot hide bytes used by the blocked KV kernels. No other element type is admitted by this extension.

`testCheckpointAllocatedInt8KvBuffers` exercises E4B's four K/V shapes at the app's 2,048-token minimum: `[1,2,2048,256]`, its V transpose, and the corresponding 512-wide pair. It seeds all 256 byte patterns via a GPU blit, saves and releases host staging, creates a fresh allocation, restores through an imported alias with no device, and compares every byte through GPU readback. The absent-device alias makes the old unchecked upload path fail the test rather than relying on injected GPU errors.

`testCheckpointRejectsInvalidInt8Buffers` checks Private/Managed and undersized Shared preflight rejection. It also bypasses preflight for the undersized Shared case and verifies that Unlock rejects before changing the destination. Managed storage is omitted on Apple-family GPUs, where that resource mode is unavailable. Codec tests separately reject padding, strides, size and element-type mismatches, and assert the public Metal allocation API's zero-offset invariant.

The appended patch also strengthens the existing FP16 Gemma roundtrip: an odd multiplier generates all 65,536 raw half-word patterns, including NaNs, infinities, subnormals and signed zeros. The comparison checks physical bytes, so any canonicalization fails the test.

All five LiteRT patches applied sequentially with whitespace checks and reproduced all 91 materialized source files exactly. **Native Metal/XCTest execution was not available here.** This trace establishes the byte-storage and transfer contract from pinned sources; it does not establish successful whole-model inference, audio behavior, performance, or device qualification. `Qualification/kernels.sh` requires explicit passes for both new XCTest methods on the native target.
