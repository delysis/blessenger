# Browser PocketTTS runtime candidate

Pinned runtime: gradium-ai/xn-ptts at 49b9033e44ab0fbb935973eca3213757644d1bbb.
Source licenses are included. Generated bindings use wasm-bindgen 0.2.120.
Build hashes are recorded in build.json. The runtime is CPU, single-threaded,
baseline SIMD, deliberately without relaxed SIMD for Safari compatibility.

Rebuild from that revision (the script applies and verifies the recorded local
speaker-projection compatibility patch):

    python3 Tools/PocketWASM/build.py CHECKOUT WASM_BINDGEN_EXECUTABLE

The Blessenger adapter requires explicit PocketTTS weights, tokenizer, config
and fourteen contact voice files. It does not use upstream's default Phonon
checkpoint. Pinned April-English weights, tokenizer, config and fourteen upstream-exported
voice states are now in model/. Their hashes and original reference hashes are
recorded in assets.json and voices.json. The exporter uses at most the same first
ten seconds of each canonical 24 kHz mono reference as the native app.

Verified: release compilation, WASM instantiation in Node, rejection of implicit
model loading, 62 upstream JS wrapper tests. Real WASM synthesis now passes for all fourteen voice states in Node: finite,
non-silent output and exact first-frame reproducibility after cancellation.
The real browser module worker also passes all fourteen voice states, including
exact first-frame reproducibility after cancellation. On this Mac, warm first
audio was 47-68 ms, excluding model/voice loading and any language-model latency.
The receipt is outputs/companion-qualification/pocket-wasm-browser.json in the
enclosing workspace. This is muted synthesis, not acoustic acceptance.

playback.mjs adds serialized clauses, a four-frame playout bound and render
acknowledgements. Changing epochs aborts synthesis and clears the renderer before
waiting for worker teardown. Old-epoch acknowledgements cannot complete new audio.
Tools/test-browser-speech-playback.mjs exercises cancellation while backpressured,
out-of-order receipts, stale receipts and serialized restart.
The real browser AudioWorklet also passed clean rendering, cancellation after
the first rendered frame, and a different voice's subsequent reply. Output gain
was zero. pocket-wasm-browser-playback.json records that check; it does not
establish microphone, speaker acoustics or iPhone performance.

Not yet verified: perceptual voice parity, iOS Safari memory/performance, speaker
barge-in, or PWA integration.
The running app still uses its existing speech path.

Before integration: compare upstream PCM on
short phrases and multi-clause replies, test cancellation without queued replay,
then test on iPhone. Keep the existing native endpoint's speculation and playback
confirmation thresholds when moving detection and synthesis onto the phone.
