# Native runtime qualification

This directory contains an executable qualification suite for an Apple Silicon
Mac. It compares the pinned baseline runtime, the patched runtime with cache
persistence unused, and the patched runtime after save or process restart and
restore. It loads the actual C API from the explicitly selected dylib.

Local Mac model, Metal, voice, and persistence results are retained in `Local/`.
See [incremental persistence qualification](Local/incremental-cache/README.md)
for measured application pauses, fresh-process restoration, and crash-recovery
checks. These results do not qualify physical iPhones or every gate below.

## Build both runtimes

Use macOS 14 or later on Apple Silicon, Xcode with its selected command-line
tools, and Bazelisk available as `bazel`. Run from the CallGemma project root:

```sh
bash Tools/build-runtime.sh baseline "$PWD/.build/native/baseline"
bash Tools/build-runtime.sh patched  "$PWD/.build/native/patched"
```

The builder pins LiteRT-LM to
`5f25078c9439e176615af5ba42636ed904fca847` and LiteRT to
`9b8c7f77e7a29e6073e614a05e1e38be7b761229`. It applies the delivered patch series
only to the patched variant. Both variants receive the same upstream WORKSPACE
repository-label substitution needed by `--override_repository`. Both use
`--config=macos --config=macos_arm64 -c opt` and `//swift:CLiteRTLM_mac`.

Each build produces:

```text
.build/native/VARIANT/product/CLiteRTLM_mac/libCLiteRTLM_mac.dylib
.build/native/VARIANT/product/runtime-receipt.tsv
```

The comparison checks each binary's SHA-256 against its receipt, both source
pins, and equal compiler, SDK, Xcode, target, and normalized build flags. The
driver verifies that the C API actually resolves from the requested dylib. Use
new build directories after changing the patch series; the builder rejects a
changed set of inputs in a previously prepared checkout.

## Run the native Metal gates

Run these against the exact prepared checkouts used to build the two dylibs:

```sh
bash Qualification/kernels.sh --variant baseline \
  --lm "$PWD/.build/native/baseline/LiteRT-LM" \
  --litert "$PWD/.build/native/baseline/LiteRT" \
  --out "$PWD/.build/qualification-metal-baseline"
bash Qualification/kernels.sh --variant patched \
  --lm "$PWD/.build/native/patched/LiteRT-LM" \
  --litert "$PWD/.build/native/patched/LiteRT" \
  --out "$PWD/.build/qualification-metal-patched"
```

The script verifies the declared variant and both staged source digests, rejects
unstaged changes, and proves the baseline's relevant Metal sources equal their
pinned originals. It runs a real Metal device/blit probe and the existing native
`buffer_handler_metal_test_macos` XCTest target with test-result caching disabled.
An explicit passed line is required for every mandatory method; a missing device,
skipped method, missing method, or failed build does not pass.

| Required tests | What they establish when executed |
| --- | --- |
| `testCopyKvCacheMetalReduce`, `testCopyKvCacheMetalBroadcast` on both variants | Existing GPU KV copy operations still produce the expected bytes. |
| `testCheckpointAllocatedGemmaKvBuffers` on patched | Actual Shared `MetalBufferFp16` allocations, requirement marker `{16}`, four aligned Gemma K/V shapes, GPU-written contents, host checkpoint, fresh allocation, and GPU readback preserve every word. The pattern covers all 65,536 FP16 bit patterns, including NaNs, infinities, subnormals, and signed zeros. |
| `testWriteImportedSharedFp16WithoutDevice`, `testCheckpointRejectsInvalidFp16Buffers` on patched | Shared writes do not rely on an unchecked staging blit; invalid storage/capacity is rejected. |
| `testCheckpointAllocatedInt8KvBuffers`, `testCheckpointRejectsInvalidInt8Buffers` on patched | E4B's four aligned INT8 K/V layouts at capacity 2048 preserve all 256 byte values through GPU seed, checkpoint, fresh allocation, and imported Shared restore. Private/Managed and undersized Shared preflight fail; an undersized write cannot alter the destination. |

The checkpoint tests inspect physical GPU bytes, including the custom cache
kernel's ordering. Their GPU operations are explicit blits. The model runs below
exercise the actual decoder/cache-update kernels. These are distinct checks;
passing the provider tests alone does not qualify end-to-end inference.

## Select an inspected model

The runner verifies the complete local file hash and admits only these two
inspected artifacts. It performs no model download.

| Artifact | Immutable revision | SHA-256 | Workload geometry |
| --- | --- | --- | --- |
| `gemma-4-12B-it.litertlm` | `7a0b1ce0ea821bcd01c5f72af84155e02191152f` | `58fd31b778ca2c21c80d634fb34fc5a89d11d563a38dfd3cbf1b40dbf252a8b6` | FP16 KV; local ring capacity 1152, attention window 1024, verifier length 4; full-position global KV. |
| `gemma-4-E4B-it.litertlm` | `e6a3892a8c22cf87ff99583996149cf3cb32452b` | `0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0` | INT8 KV; full-position capacity placeholder 32003, two KV heads, head widths 256/512, verifier length 4. |

The repositories are
[Gemma 4 12B LiteRT-LM](https://huggingface.co/litert-community/gemma-4-12B-it-litert-lm/tree/7a0b1ce0ea821bcd01c5f72af84155e02191152f)
and
[Gemma 4 E4B LiteRT-LM](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/tree/e6a3892a8c22cf87ff99583996149cf3cb32452b).
Model-card, hash, and provenance details are in
`../Documentation/model-receipts.json`; bounded artifact metadata and the exact
source trace accompany the runtime patches. The supplied artifacts have **not**
been established to be the requested QAT/QAT Mobile exports. Qualification of
these files cannot establish that missing provenance.

Requested context capacity is rounded down to a multiple of four **before**
engine compilation and allocation. Both binaries receive the same effective
capacity. Existing KV bytes are never truncated. For the 12B full suite use at
least 4096 tokens so the fixture can cross two local-ring wraps. E4B accepts an
effective capacity from 2048 through 32000. A new model hash needs its own
metadata and layout admission before extending these tests.

## Run functional and performance qualification

Choose the acceptable save/load latency budgets before collecting measurements.
The suite intentionally supplies no arbitrary product latency budget. The
inference-regression and retained-memory allowances default to **zero**. Do not
raise a limit after inspecting a failed or inconclusive result.

```sh
# Set these to the product's predeclared budgets, in milliseconds.
: "${QUALIFY_SAVE_BUDGET_MS:?Set the save latency budget before running}"
: "${QUALIFY_LOAD_BUDGET_MS:?Set the load latency budget before running}"
: "${QUALIFY_MODEL:?Set an absolute path to one inspected .litertlm file}"

bash Qualification/run.sh \
  --baseline "$PWD/.build/native/baseline/product/CLiteRTLM_mac/libCLiteRTLM_mac.dylib" \
  --patched "$PWD/.build/native/patched/product/CLiteRTLM_mac/libCLiteRTLM_mac.dylib" \
  --baseline-receipt "$PWD/.build/native/baseline/product/runtime-receipt.tsv" \
  --patched-receipt "$PWD/.build/native/patched/product/runtime-receipt.tsv" \
  --headers "$PWD/.build/native/patched/LiteRT-LM" \
  --model "$QUALIFY_MODEL" --capacity 4096 \
  --out "$PWD/.build/qualification-model" \
  --max-save-ms "$QUALIFY_SAVE_BUDGET_MS" \
  --max-load-ms "$QUALIFY_LOAD_BUDGET_MS" \
  --max-regression-percent 0 --max-retained-bytes 0 \
  --blocks 12 --warmup-blocks 1 --confidence 0.99 --bootstrap 20000
```

Use a new output directory for each run and each artifact. This is a substantial
qualification run: the default performance matrix alone starts 624 isolated
processes, followed or preceded by additional functional fixtures and cache
writers. Every process initializes the actual runtime. Engine initialization is
recorded separately from continuation timing. Keep the Mac's power mode and
foreground workload stable; thermal state is recorded before and after the run.
No observation is discarded as an outlier.

The functional matrix runs MTP off and on. It compares baseline inference,
patched inference without persistence, continuation after a save, and
continuation after a different process restores the saved cache. It checks:

- Exact continuation text and runtime token counts. A second set of processes
  compares every teacher-forced token's float32 log-score bits and the total
  score. The public C API does not expose full-vocabulary logits or generated
  token IDs, so those are not claimed.
- A separate patched MTP-off versus MTP-on check reuses the same stable prompts
  and reports exact prefix/continuation text, counts, and selected-score agreement.
  Decode and verify have different batch shapes; the source does not promise
  bit-identical floating-point scores across those shapes. A difference is
  retained as `DIFFERENT_REQUIRES_REVIEW` and stops automatic qualification. It
  does not silently widen a tolerance or assert that every difference is a bug.
- 12B prompts around local-ring boundaries and two wraps; E4B prompts around
  prefill-block boundaries and near the selected capacity. The exact input
  token count is verified with the actual tokenizer.
- Checksum corruption and a changed compatibility key return the expected
  status before a fresh session is changed. Its subsequent output is compared
  with an untouched fresh session.
- Cancellation after an actual streamed chunk, completion of cancellation,
  destruction of that session and engine, and recovery of the prior completed-turn
  cache in a new process. The callback storage outlives the engine's worker joins;
  Session deletion alone has only a bounded wait. Callback/start failures or a
  missing final callback fail the isolated process without unwinding borrowed
  storage. Cancelled state is never saved or reused.
- Real C Conversation text and direct-audio turns, including its template and
  published history. Completed history is bound into the compatibility key by
  SHA-256 of its exact JSON bytes. Restore checks those bytes and public token
  counts before the next turn. Changed history bytes, malformed JSON, an orphan
  assistant message, and a populated restore target must reject without changing
  the target's subsequent result.
- On the patched runtime, `conversation_count_tokens` preprocesses each selected
  text/audio input before it is sent. It must return a positive count while
  exact history bytes and `GetTokenCount` remain unchanged. This additive API is
  absent from the baseline; count-preprocessing time is recorded separately.
- Requested capacities `4n`, `4n+1`, `4n+2`, and `4n+3` all produce the same
  effective geometry and continuation. This tests the driver policy. Run the
  application's native `ModelPolicy` unit tests separately to verify its actual
  implementation and memory admission.

The default audio fixtures use macOS `say` and `afconvert` to make two 16 kHz
mono WAV inputs. Both are delivered to the model's audio encoder: audio first
turn, save, fresh process restore, audio next turn. To use selected recordings,
add `--audio-input /absolute/first.wav --next-audio /absolute/next.wav`. The files'
hashes and exact message JSON are recorded. The test compares behavior across
runtime variants; it does not grade transcription or semantic answer quality.

## Read the timing and memory result

There are exactly 12 required groups: three comparisons, MTP off/on, and a short
and long history. The long history is 1151 input tokens for 12B and
`effective_capacity - 513` for E4B. Each block runs **A1, B1, B2, A2**, with a new
process for every leg:

| Group | A | B |
| --- | --- | --- |
| `baseline-vs-patched` | Baseline, ordinary inference | Patched, ordinary inference with persistence unused |
| `post-save` | Patched, ordinary inference | Patched, explicit save before continuation |
| `post-restore` | Patched, ordinary inference | Patched, fresh process restoring before continuation |

The analyzer requires all groups, correct libraries/modes/settings, distinct
process IDs, completed save/load evidence, byte-equivalent continuations, and
at least eight continuation tokens. A mislabeled all-reference data set or an
omitted persistence group is rejected.

Median and p95 statistics use a paired bootstrap of whole ABBA blocks. Resampling
keeps the two A and two B observations together. The default interval is 99%,
with a fixed resampling seed; minimums are 12 measured blocks, 10,000 bootstrap
replicates, and 95% confidence. More blocks can be predeclared to tighten tail
estimates. Twelve blocks are a minimum, not a guarantee of a precise p95 estimate.

- Continuation prefill wall time and decode wall time per runtime-reported token
  are candidate/reference ratios. The zero-regression limit is 1.0.
- Idle process physical footprint before and after continuation is a candidate
  minus reference byte difference. Each observation is a median of three short
  idle samples from `TASK_VM_INFO.phys_footprint`. No cache purge or allocator
  reset is performed. The default retained-memory limit is zero bytes.
- Save and load wall times are absolute milliseconds, including synchronous
  checkpoint work. Median and p95 are checked against the separately predeclared
  budgets. These runs do not flush the filesystem cache and do not claim
  cold-disk or power-loss behavior.

**PASS** requires the confidence interval's upper endpoint to satisfy the limit.
**FAIL** means its lower endpoint exceeds the limit. Otherwise the result is
**INCONCLUSIVE**, which returns a nonzero exit status. A zero-margin test can
remain inconclusive even when measured performance is similar. Neither a pass
nor a tight interval proves literally zero effect under every workload.

`report.tsv` contains reference/candidate statistics, units, interval endpoints,
limits, and decisions. Exit 0 means all timing/memory gates passed; exit 1 means
a failure or rejected evidence; exit 2 means an inconclusive result or runner
configuration error. Consult `analysis.log` and each process's stderr for the
specific reason. Native qualification is complete only when **both Metal runs,
this model run, and the app's native tests pass**.

All runtime tests use greedy sampling, seed 7319, max output 64, thinking
disabled, and channel filtering disabled. They establish deterministic
continuation evidence. They do not qualify restoration of an application's
stochastic sampler RNG sequence or every app UI/audio lifecycle transition.

## Evidence and portable checks

Each run retains predeclared parameters, model/binary/build receipts, host/SDK
information, audio hashes, compiler commands and header dependency lists, source
hashes, process commands/stdout/stderr, exact functional outputs, warmup data,
the complete measured manifest, and the final report. Representative caches are
hashed and removed after use by default. `--keep-caches 1` keeps functional and
prepared restore caches; large per-trial temporary caches are still removed.

To compile the actual driver and test the analyzer on Linux or macOS without
loading a model:

```sh
bash Qualification/build.sh --headers /absolute/pinned/LiteRT-LM \
  --out /absolute/qualification-bin
/absolute/qualification-bin/analyze --self-test yes
bash -n Qualification/build.sh Qualification/run.sh Qualification/kernels.sh
```

For the full portable admission checks, including malformed gate parameters and
refusal to qualify a non-Mac host:

```sh
bash Qualification/portable-checks.sh --headers /absolute/pinned/LiteRT-LM \
  --out /absolute/new-portable-results
```

The compiler must support C++17. `CXX` can select it. The build uses the real
selected C headers and emits its exact commands, header dependency files, and
source hashes; it links no LiteRT-LM runtime implementation. The synthetic
self-test explicitly reports that no inference, Metal, or persistence test ran.

The driver and analyzer can also be invoked separately for diagnosis. Preserve
the original evidence and limits when investigating a failure. Do not turn a
failed native gate into a pass by replacing it with these portable checks.

### Interrupted-prefix reuse

`Tools/qualify-app-prefix-reuse.py DIRECTORY --question QUESTION.wav` drives the
isolated packaged 12B app through three interrupted replies. It requires muted
synthetic input, checks connection survival, and inspects `checkpoint.prefix_selected`
receipts: a recovery may replay newly committed material but may not start behind
an already rebuilt canonical prefix. It fails if fewer than two rebuilds occurred.
Use a spoken question that elicits enough speech to interrupt; keep the fixture
and the failing journey, not only the final result.

This check does not qualify physical echo cancellation. Speaker acceptance also
requires repeated audible greetings, a live spoken correction during playback,
and explicit hang-up. Preserve the user's audible observations alongside the
processed-microphone capture and timing trace. Exercise quiet-volume playback
separately from quiet human speech; a clean warm call does not explain a previous
self-interruption.
