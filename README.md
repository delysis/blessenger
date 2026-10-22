# Blessenger

Native macOS/iOS persona messaging and voice calls, with a paired browser/PWA
companion and Cloudflare signaling/TURN support. Internal `CallGemma` target and
module names remain in the source.

## Repository status

This is the initial source-control snapshot of the working application on
2026-10-22. Earlier work was not committed in this directory; this repository
does not reconstruct that missing history. Development and device qualification
are ongoing. See [current companion implementation and evidence boundaries](Cloud/IMPLEMENTATION.md).

Source, runtime patches, model-conversion patches, dependency pins, tests,
browser runtime bindings, artwork, and build tools are included. Model weights,
compiled native libraries/Core ML models, user recordings, user databases,
credentials, and local qualification output are excluded. Nothing was deleted
from the working installation. Some older reports link to deliberately untracked
local evidence.

## Building

**Start here: [agent build/install handoff](Documentation/BUILD-AND-INSTALL.md).**
`bash Tools/bootstrap-mac.sh` acquires the corrected speech exports; no manual
PocketTTS conversion is required.


The current Swift package targets macOS 26 on Apple Silicon. Use a compatible
Xcode installation. Build the patched runtime with `Tools/build-runtime.sh`,
Earshot with `Tools/build-earshot.sh`, and the app with `Tools/build-app.sh`.
See `ModelPatches/`, `Browser/PocketTTS/README.md`, and `Tools/PocketWASM/` for
model/runtime preparation. The fourteen canonical native voice clips are versioned in
`Sources/CallGemma/Resources/Voices/`, alongside their integrity manifest. Persona
prompts, wake names, and portraits are also versioned. Browser conditioning
states are generated from those references. Corrected Core ML exports and browser speech assets are acquired by the pinned
bootstrap downloader, outside Git history. The macOS project defaults to local ad-hoc signing; an Apple Development
identity can be supplied for stable OS permissions across rebuilds.

For the Cloudflare companion, run `npm ci` and `node build-assets.mjs` in `Cloud/`.
Set deployment credentials through Wrangler/Keychain; never commit secrets.
The account ID in `Cloud/wrangler.jsonc` is configuration, not an API credential.

The following notes predate several repairs and describe historical model
qualification. They are retained for provenance, not a current acceptance claim.

---

# Historical Call Gemma implementation notes

A native Swift macOS/iOS voice-call app for the patched LiteRT-LM runtime. A green call / red hangup button, an editable system prompt, and a voice-sample picker and drop target. Gemma receives audio directly; there is no transcription service or chat view.

**Qualification is in progress.** Tracked-write persistence and voice-editor results are in [the current report](Qualification/Local/dirty-cache/README.md). The [bounded-scan report](Qualification/Local/bounded-cache/README.md) and [earlier full-copy report](Qualification/Local/incremental-cache/README.md) are retained. The macOS app builds; real E4B audio input and completed-turn KV save/restore have run on an M4 Max. Native Metal buffer tests pass for both baseline and patched builds. These component results do not establish full-call latency or physical-iPhone readiness. Retained evidence is in `Qualification/Local`; failed attempts are preserved alongside successful runs.

## Model selection

The user requirements are local voice calling on Mac and iPhone, responsiveness, and KV persistence across process shutdown. The original archive's QAT, 12B, speculative decoding and voice-cloning proposals are not additional user requirements.

The app defaults to the pinned `litert-community/gemma-4-E4B-it-litert-lm` artifact (3,659,530,240 bytes) on every device. It accepts audio directly. Speculative decoding is disabled: actual saves with MTP enabled correctly reject this artifact because it lacks the explicitly typed KV metadata required for safe rollback. Patch 0014 fixes a separate false rejection when MTP is disabled but an unused verifier signature exists. The 12B catalog entry remains available in source, but is not the default and has not been locally qualified.

Downloads use the pinned `swift-huggingface` client and its shared Python-compatible HF cache. `HF_HUB_CACHE` and `HF_HOME` are honored; the default on this unsandboxed Mac is `~/.cache/huggingface/hub`. Gemma, PocketTTS and VAD assets belong there. FluidAudio receives a symlink view under the HF cache, with no second asset copy. App Support retains conversation checkpoints, compiled-runtime state and the user-selected voice sample.

Gemma's content blob is verified against the pinned size and SHA-256; the runtime receives the snapshot filename because it uses `.litertlm` for format detection. A file-identity receipt avoids rehashing unchanged blobs on later launches. Invalid shared-cache contents are reported without deleting other applications' cached assets.

Context capacity depends on physical and currently available memory. It is rounded **down to a multiple of four before engine creation**. The policy reserves memory for macOS, speech, and transient allocations; its estimates need device qualification. Low available memory produces an actionable error instead of attempting an unbounded allocation. A safe existing capacity is reused across restarts when the remaining configuration matches.

## Build on an Apple Silicon Mac

Requirements: macOS 14 or newer, Xcode 16 or newer with the selected macOS SDK, Git, and Bazelisk available as `bazel`. The pinned runtime selects Bazel 7.6.1. The build fetches the exact upstream sources and Swift dependencies; the checked-in source does not embed model weights. This local working copy also contains generated binaries in Vendor and dist.

Run from this directory:

```sh
bash Tools/build-runtime.sh baseline
bash Tools/build-runtime.sh patched
bash Tools/test-app.sh
bash Tools/build-app.sh
open "$HOME/Applications/CallGemma.app"
```

The baseline build is needed for qualification, not for launching the app. The runtime builder uses isolated checkouts, applies the ordered patch files, and records the source revisions, build flags, toolchain, and actual dylib hash. A prepared checkout whose inputs change is rejected. Choose a new work directory to rebuild changed inputs.

`Tools/build-app.sh` uses the checked-in Xcode project. Build/test products live in `~/Library/Caches/CallGemma/DerivedData`, and the runnable app defaults to `~/Applications/CallGemma.app`, so launching it does not depend on Documents-folder access. Override these locations with `CALL_GEMMA_DERIVED_DATA` and `CALL_GEMMA_APP_DESTINATION`; choose an unused app destination to preserve earlier builds. Xcode embeds the native library and Swift package resources in the app bundle. `Package.swift` also supports source-level `swift test` workflows; do not manually turn the SwiftPM command-line executable into an app bundle. The XCTest scheme suppresses first-run model setup in its host application.

The three direct Swift dependencies are pinned. Retain Xcode's generated `Package.resolved` and the complete build log with the native qualification results; the resolved dependencies and native build logs are part of local qualification.

The runtime identity in `Resources/runtime.json` fingerprints a manifest of **all four input dylibs**, including the source-built Metal accelerator. Xcode may change its code-signature bytes when embedding it; the identity does not claim a hash of the subsequently signed bundle. The app also binds model contents, system prompt, context capacity, sampler settings, audio backend, MTP setting, OS, and Metal device to each checkpoint.

## Call behavior

Press the green button to start a call and the red button to end it. Microphone permission is requested when starting. The three prompt choices use spoken English, matching the selected PocketTTS assets. Open Voice or drop an audio file to select and preview one to ten seconds for PocketTTS. Large files are read only over the selected interval. The microphone control records up to one minute locally, after which the same selection controls apply. The reset control restores the default PocketTTS asset. Voice conditioning is committed only if both decoding and the persistent file update succeed.

Voice import uses bounded reads and resamples once. A packetized MP3/AAC file can report a length beyond its decodable tail; a failed final read retains the valid prefix, following the pinned FluidAudio converter. Four native file-decoder tests cover the ten-second bound, short AAC, subsecond rejection, and nonfinite PCM. They have passed on this Mac.

Gemma runs on the GPU with MTP disabled; its audio encoder runs on two CPU threads. FluidAudio VAD detects bounded utterances. Each utterance is limited to 30 seconds and passed to Gemma as a mono 16 kHz WAV. Temporary recordings are removed after the response.

Generated text enters a bounded sentence/clause buffer. PocketTTS synthesizes one sentence at a time and delivers 80 ms PCM frames while the audio player is already playing earlier frames. Queue backpressure bounds memory; text is never silently dropped. The pinned PocketTTS rank-4 assets use CPU/ANE placement, with the Mimi decoder on CPU. The TTS path never requests GPU compute. An explicit Neural Engine error selects CPU execution using the same assets. If a sentence has already started playing, an error stops it rather than replaying words. A process-level Core ML crash cannot be recovered by a Swift error handler.

Voice processing attempts acoustic echo cancellation. With AEC available, new speech can interrupt a response. If AEC is unavailable, listening pauses during playback and its echo tail; diagnostics report this. Cancellation drains the native callback/task lifetime before destroying handles. The C API permits cancellation from the generation callback, so a long prefill may delay native cancellation until its first callback.

The app checkpoints after a complete response has finished playing. Generation, save/load, and handle operations are serialized on a dedicated queue. Failed or interrupted turns recover the last completed checkpoint. Saving creates an immutable generation containing both the cache and exact conversation history; an atomic, synced `CURRENT` pointer publishes the pair. A failed device restore causes a fresh engine to be built. There is no prompt replay on a successful restore.

When the context cannot accommodate another bounded utterance and reply, the app starts a new conversation and explicitly says that earlier turns are no longer in Gemma's context. It durably retires the exhausted checkpoint so restarting cannot re-enter the same failure. A 30-second silent-input token-count probe runs once during setup; both pinned audio preprocessors derive geometry from frame count. Subsequent turns only query the current token count. The reserve includes the actual system preface, reply allowance, and conservative prefill/MTP padding.

This is **completed-turn context persistence**. It does not resume an interrupted utterance or generation, and it does not serialize the random generator. Top-p sampling starts from the new session's seed after restore; exact future stochastic text is not promised. Native equivalence tests use greedy decoding and teacher-forced scores to isolate cache correctness.

## Kernel and persistence scope

No Metal kernel or allocation policy is modified. There is no per-token snapshotting. Explicit checkpoint operations transfer the existing buffers and release host staging afterward; save/load costs are measured separately from inference.

The inspected 12B artifact uses FP16 Shared Metal KV buffers. E4B uses INT8 Shared Metal buffers, whose GPU graph descriptor treats the same physical bytes as unsigned. The appended patches admit the proven, unpadded converted-buffer layouts and use a bounds-checked Shared-memory upload. They do not convert INT8 cache values to floating point. Native tests compare every physical byte, including all 65,536 FP16 bit patterns and all 256 INT8 values. Private/managed packed transfers remain rejected; they are outside these inspected Gemma paths.

Capacity alignment applies before allocation. Truncating three tokens out of an already allocated blocked cache would not repair its physical layout, so the persistence codec still rejects incompatible existing layouts.

Gemma 12B's adapter-less audio encoder was classified as streaming even though its published signature has no recurrent state. A checkpoint-only validation hook now admits its empty, stateless completed context. Busy, buffered, recurrent, malformed, and advanced streaming-audio states remain rejected. Conversation persistence binds history to tensors and admits only the completed Gemma4 text/audio configuration used here.

The previous fourteen patches are retained byte for byte, with four small follow-ups appended. See [RuntimePatches](RuntimePatches/README.md) for revisions, order, and validation receipts.

## Qualification handoff

The platform-independent production Swift sources now compile and **19 tests pass** under Swift 6.2.3 on Linux, with complete concurrency checking, warnings as errors for our targets, and runtime actor checks. They exercise sentence/utterance buffers, queue cancellation and ordering, WAV/JSON encoding, model selection, memory admission, and context alignment. No Apple APIs or inference implementations are substituted. The three portable suites use Swift Testing; the Linux XCTest discovery path was observed to crash while casting generated method references.

Run the same dependency-free checks on Linux or macOS with Swift 6:

```sh
bash Tools/test-portable-swift.sh
```

The script retains its exact tested-source hashes, build/test log, XML results, and toolchain identity in the printed results directory. The delivered run is under [Qualification/Validation/swift-portable](Qualification/Validation/swift-portable). Parsing the remaining app sources does not typecheck their Apple APIs. Full app, checkpoint-storage, model-download, and voice-decoder tests still require `Tools/test-app.sh` on macOS.

Start with [Qualification/README.md](Qualification/README.md). It contains executable baseline-versus-patched comparisons, native Metal XCTest gates, and the exact commands. Run the complete suite independently for **both artifact hashes**, with MTP both off and on. Declare save/load latency budgets before collecting results. The default allowed inference regression is **0%**; uncertain measurements are reported as `INCONCLUSIVE`, not a pass.

The device gate covers untouched inference, post-save inference, fresh-process restore, teacher-forced token scores, cancellation, malformed history/cache rejection, direct audio turns across a restart, 12B ring boundaries, E4B context boundaries, retained memory, and median/p95 performance. The public C API exposes generated text, token counts and selected text-scoring values; it does not expose full generated token-ID/logit vectors. The suite states that limit rather than fabricating that coverage.

Additional app acceptance checks on the Mac:

1. Launch `~/Applications/CallGemma.app` with the checkout unavailable. Verify package resources, microphone permission, speech, and offline restart without relying on developer paths.
2. Complete an audio turn, quit, relaunch, and ask an audio question that depends on that turn. Repeat with MTP enabled and after an interrupted response. Fill a small context until the explicit reset notice appears; confirm the next turn works and the exhausted checkpoint does not return after restart.
3. Test download cancellation and retry; quit while model setup, microphone permission, voice import, and generation are in progress. Check that no late operation reopens the microphone or publishes a cancelled setup as ready.
4. Test the default voice and an imported sample. Exercise explicit ANE errors with a native test seam or documented Core ML failure; verify CPU fallback and no TTS GPU work in Instruments. Also verify the no-AEC fallback on the intended audio devices.
5. Run with `CALL_GEMMA_TRACE=1` and collect Instruments Audio/Core ML/Metal traces. Events mark utterance completion, first Gemma text, sentence stream delivery, first PCM and first scheduled playback. Confirm actual synthesis/playback overlap, sentence gaps, peak memory, thermal behavior, and end-to-end startup/response latency. “Sentence synthesis stream” includes consumer backpressure; it is not an isolated Core ML compute timer. Tracing is disabled by default.

Source/API provenance is in [Documentation](Documentation), runtime regression evidence in [RuntimePatches/validation](RuntimePatches/validation), and portable check results in [validation.json](Documentation/validation.json). Portable harness/parser passes do not establish native correctness or a zero-regression claim.

## iPhone build

`Tools/build-ios-runtime.sh` builds the patched C API for arm64 device and simulator. The `CallGemma-iOS` Xcode scheme shares the Swift call logic, adds an iOS audio session, and closes the live engine on backgrounding. Completed checkpoints are saved during each call, so restoration does not depend on receiving a termination callback. Physical-device memory, latency, interruptions and distribution signing still require device validation; a simulator build is not that validation.

## Build corrections and comparison scope

`RuntimeBuildFixes/normalize.py` applies identical open-source build wiring to baseline and patched sources. C++ and Objective-C++ use C++20 consistently; otherwise unresolved Abseil ABI calls can cause a native crash even when linking succeeds. Both builds use their own source-built Metal accelerator. Packaging the upstream prebuilt accelerator would bypass the provider patches and invalidate the comparison. The constraint provider and Metal sampler remain pinned upstream binaries and are included in the runtime identity.

The qualification harness supports `--mtp-modes off` for the actual app configuration. Its default `both` still requires both MTP modes; the explicit off scope does not qualify speculative decoding. The original handoff README is preserved under Documentation for provenance.

Conversation persistence is current-format only. There are no runtime predecessor allowlists or legacy journal migrations. This development format uses `Conversations-v3`; earlier conversation directories are not imported. Current-format restart and crash recovery remain required.

## Model acquisition

At runtime, Gemma uses the pinned Hugging Face repository/revision/file from the
model catalog. The HF client reuses its shared cache and downloads on a miss;
Blessenger verifies the content size and SHA-256 before loading. PocketTTS also
uses the shared HF cache, downloads its pinned upstream snapshot on a miss, and
fetches missing files from partial snapshots. `HF_HUB_CACHE` and `HF_HOME` are
honored. Repository access/license requirements still apply.

The corrected PocketTTS conditioning and generation exports are a separate
bundled dependency: `PocketConditioning16.mlmodelc`,
`PocketConditioning256.mlmodelc`, and `PocketGeneration.mlmodelc`, verified by
`Resources/pocket-speech-models.json`. The app installs them into its HF-cache
namespace. They are not downloadable from the pinned upstream snapshot; do not
replace them with its faulty transformer exports. See `ModelPatches/mobius/`.
The cache-miss download paths above were checked in source; an empty-cache
end-to-end build on another Mac has not yet been qualified.
