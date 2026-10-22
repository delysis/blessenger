# Runtime patch stack

Apply each repository's `series` in order. `Tools/build-runtime.sh` performs the checkout, patch application, and matched baseline/patched build.

| Repository | Base commit | Patch count |
| --- | --- | --- |
| google-ai-edge/LiteRT-LM | `5f25078c9439e176615af5ba42636ed904fca847` | 28 |
| google-ai-edge/LiteRT | `9b8c7f77e7a29e6073e614a05e1e38be7b761229` | 5 |

LiteRT pins ML Drift at `1b18771f44c0be3d972847b31a80f6dc3d6964b5`. The runtime builder applies LiteRT-LM's existing external-repository label adjustment to **both** variants, because `--override_repository` bypasses the original archive's patch command.

The original ten LM and four LiteRT patches retain their exact bytes from `litert-kv-cache-patches.zip` (SHA-256 `47138d30573a5e919ee056520a0c4d4474900ec92dc7aa51b63895f1eafd4c31`). This bundle appends:

| Patch | Purpose |
| --- | --- |
| LM 0011 | Completed Gemma4 Conversation save/load and owned JSON history; thin C wrapper for existing input token counting. No prompt replay or per-token checkpoint work. |
| LM 0012 | Checkpoint-only stateless audio admission and nonblocking audio-context lease. Rejects unsupported or partial audio state before mutation. |
| LiteRT 0005 | Checked Shared-memory INT8 host upload, native physical-byte tests, and full FP16 bit-pattern coverage. |
| LM 0013 | Matching exact INT8 Metal transfer admission and rejection tests; corrects the stale public MTP restriction comment. |

The Conversation API requires complete canonical history, the original configuration, and a compatibility key bound to the exact history JSON. This includes history rebuilt by completed prefill, without generating an extra assistant turn. Patch LM 0029 preserves the session's prefilled/decoded phase in versioned, checksum-protected cache metadata; restoring a prefilled session must not pretend a decode occurred. Active, failed, and cancelled tasks remain rejected by executor admission. Missing or unknown phase metadata is rejected before loading executor state. Mid-generation random state is not persisted.

Private/managed packed Metal paths remain unsupported because their existing helpers do not propagate all relevant transfer failures. The inspected Gemma4 FP16/INT8 paths use Shared storage. Aligned capacity must be selected before compilation and allocation; the codec does not truncate or reinterpret an incompatible live buffer.

`SHA256SUMS` identifies the patch files. `validation` contains incremental application checks, source receipts, bounded model-metadata evidence, and explicit native-test limitations. The original patch validation is historical evidence; new native qualification uses the assembled stack. Neither source review nor portable parser tests prove Metal/ANE/device behavior.
