# Call Gemma

A native Swift macOS voice-call demo for the patched LiteRT-LM runtime. One red call/hangup button, a system-prompt menu, and a voice-sample drop target. Gemma receives audio directly; there is no transcription service or chat view.

**This is a source handoff, not a qualified Mac binary.** The Swift app, Metal tests, real Gemma inference, and ANE execution have not run in the Linux development environment. The executable qualification suite is included so a Mac agent can establish correctness and performance before calling this ready.

## Model availability

The requested **12B IT QAT** and **E4B IT QAT Mobile** packages have not been verified as downloadable LiteRT bundles containing both audio and MTP. The app therefore shows an explicit “Use available LiteRT model” choice before downloading the alternatives below. It remembers that choice. It does not label these alternatives QAT.

| Physical RAM | Selected available artifact | Download size |
| --- | --- | --- |
| At least 16 GiB | `litert-community/gemma-4-12B-it-litert-lm` | 6,883,278,368 bytes |
| Below 16 GiB | `litert-community/gemma-4-E4B-it-litert-lm` | 3,659,530,240 bytes |

The catalog pins the repository revision, filename, byte count, and SHA-256. Both published packages include audio and a drafter. See [model receipts](Documentation/model-receipts.json), the [12B card](https://huggingface.co/litert-community/gemma-4-12B-it-litert-lm), the [E4B card](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm), and the upstream [QAT package clarification](https://github.com/google-ai-edge/LiteRT-LM/issues/2497).

Downloads use the pinned `swift-transformers` Hub implementation. A first-use streaming hash verifies the artifact. A local file-identity receipt avoids hashing gigabytes again on every launch. Downloads and cancellation retain the upstream cache; interrupted-download byte resume depends on its transport. An authentication or license-access error is reported without substituting a different model. `HF_TOKEN` can be provided through the normal Hugging Face environment mechanism if needed.

Context capacity depends on physical and currently available memory. It is rounded **down to a multiple of four before engine creation**. The policy reserves memory for macOS, speech, and transient allocations; its estimates need device qualification. Low available memory produces an actionable error instead of attempting an unbounded allocation. A safe existing capacity is reused across restarts when the remaining configuration matches.

## Build on an Apple Silicon Mac

Requirements: macOS 14 or newer, Xcode 16 or newer with the selected macOS SDK, Git, and Bazelisk available as `bazel`. The pinned runtime selects Bazel 7.6.1. The build fetches the exact upstream sources and Swift dependencies; no runtime binary or Gemma/PocketTTS weights are included here.

Run from this directory:

```sh
bash Tools/build-runtime.sh baseline
bash Tools/build-runtime.sh patched
bash Tools/test-app.sh
bash Tools/build-app.sh
open dist/CallGemma.app
```

The baseline build is needed for qualification, not for launching the app. The runtime builder uses isolated checkouts, applies the ordered patch files, and records the source revisions, build flags, toolchain, and actual dylib hash. A prepared checkout whose inputs change is rejected. Choose a new work directory to rebuild changed inputs.

`Tools/build-app.sh` uses the checked-in Xcode project. Xcode embeds the native library and Swift package resources in the app bundle. `Package.swift` also supports source-level `swift test` workflows; do not manually turn the SwiftPM command-line executable into an app bundle. The XCTest scheme suppresses first-run model setup in its host application.

The three direct Swift dependencies are pinned. Retain Xcode's generated `Package.resolved` and the complete build log with the native qualification results; transitive dependency resolution and native app compilation have not been exercised here.

The runtime identity in `Resources/runtime.json` fingerprints the **built input dylib**. Xcode may change its code-signature bytes when embedding it; the identity does not claim a hash of the subsequently signed bundle. The app also binds model contents, system prompt, context capacity, sampler settings, audio backend, MTP setting, OS, and Metal device to each checkpoint.

## Call behavior

Press the red button to start or end a call. Microphone permission is requested when starting. The three prompt choices use spoken English, matching the selected PocketTTS assets. Drop an audio file to choose a voice; the first ten seconds condition PocketTTS. A sample must contain at least one second of valid audio and fit the 20 MiB import bound. The reset control restores Alba. Voice conditioning is committed only if both decoding and the persistent file update succeed.

Voice import uses bounded reads and resamples once. A packetized MP3/AAC file can report a length beyond its decodable tail; a failed final read retains the valid prefix, following the pinned FluidAudio converter. Four native file-decoder tests cover the ten-second bound, short AAC, subsecond rejection, and nonfinite PCM. They require the Mac and have not run here.

Gemma runs on the GPU with MTP enabled; its audio encoder runs on two CPU threads. FluidAudio VAD detects bounded utterances. Each utterance is limited to 30 seconds and passed to Gemma as a mono 16 kHz WAV. Temporary recordings are removed after the response.

Generated text enters a bounded sentence/clause buffer. PocketTTS synthesizes one sentence at a time and delivers 80 ms PCM frames while the audio player is already playing earlier frames. Queue backpressure bounds memory; text is never silently dropped. The pinned PocketTTS rank-4 assets use CPU/ANE placement, with the Mimi decoder on CPU. The TTS path never requests GPU compute. An explicit Neural Engine error selects CPU execution using the same assets. If a sentence has already started playing, an error stops it rather than replaying words. A process-level Core ML crash cannot be recovered by a Swift error handler.

Voice processing attempts acoustic echo cancellation. With AEC available, new speech can interrupt a response. If AEC is unavailable, listening pauses during playback and its echo tail; the UI explains this. Cancellation drains the native callback/task lifetime before destroying handles. The C API permits cancellation from the generation callback, so a long prefill may delay native cancellation until its first callback.

The app checkpoints after a complete response has finished playing. Generation, save/load, and handle operations are serialized on a dedicated queue. Failed or interrupted turns recover the last completed checkpoint. Saving creates an immutable generation containing both the cache and exact conversation history; an atomic, synced `CURRENT` pointer publishes the pair. A failed device restore causes a fresh engine to be built. There is no prompt replay on a successful restore.

When the context cannot accommodate another bounded utterance and reply, the app starts a new conversation and explicitly says that earlier turns are no longer in Gemma's context. It durably retires the exhausted checkpoint so restarting cannot re-enter the same failure. A 30-second silent-input token-count probe runs once during setup; both pinned audio preprocessors derive geometry from frame count. Subsequent turns only query the current token count. The reserve includes the actual system preface, reply allowance, and conservative prefill/MTP padding.

This is **completed-turn context persistence**. It does not resume an interrupted utterance or generation, and it does not serialize the random generator. Top-p sampling starts from the new session's seed after restore; exact future stochastic text is not promised. Native equivalence tests use greedy decoding and teacher-forced scores to isolate cache correctness.

## Kernel and persistence scope

No Metal kernel or allocation policy is modified. There is no per-token snapshotting. Explicit checkpoint operations transfer the existing buffers and release host staging afterward; save/load costs still need measurement.

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

1. Move `dist/CallGemma.app` outside the checkout, temporarily rename the build directory, and launch it. Verify package resources, microphone permission, speech, and offline restart without relying on developer paths.
2. Complete an audio turn, quit, relaunch, and ask an audio question that depends on that turn. Repeat with MTP enabled and after an interrupted response. Fill a small context until the explicit reset notice appears; confirm the next turn works and the exhausted checkpoint does not return after restart.
3. Test download cancellation and retry; quit while model setup, microphone permission, voice import, and generation are in progress. Check that no late operation reopens the microphone or publishes a cancelled setup as ready.
4. Test the default voice and an imported sample. Exercise explicit ANE errors with a native test seam or documented Core ML failure; verify CPU fallback and no TTS GPU work in Instruments. Also verify the no-AEC fallback on the intended audio devices.
5. Run with `CALL_GEMMA_TRACE=1` and collect Instruments Audio/Core ML/Metal traces. Events mark utterance completion, first Gemma text, sentence stream delivery, first PCM and first scheduled playback. Confirm actual synthesis/playback overlap, sentence gaps, peak memory, thermal behavior, and end-to-end startup/response latency. “Sentence synthesis stream” includes consumer backpressure; it is not an isolated Core ML compute timer. Tracing is disabled by default.

Source/API provenance is in [Documentation](Documentation), runtime regression evidence in [RuntimePatches/validation](RuntimePatches/validation), and portable check results in [validation.json](Documentation/validation.json). Portable harness/parser passes do not establish native correctness or a zero-regression claim.
