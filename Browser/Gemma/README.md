# Browser E2B qualification candidate

Pinned @mlc-ai/web-llm 0.2.86, Gemma 4 E2B IT q4f32_1, model revision
db5bcb53aa58acb27777ba02a891ff5c95d26ccf and compiled-library revision
00fe7a40e57e5e8eb9fef87526a4bf28ad5846c0. Temperature is 1. The adapter
requires WebGPU and the model's storage-buffer limit. It does not
silently select a different model or CPU runtime. The upstream catalog estimates
3863 MB GPU memory with 4096-token context; no iPhone memory qualification yet.
The weights remain 4-bit; float32 is the arithmetic precision. The failing
q4f16_1 build remains available only for explicit diagnostic comparison, pinned
to 633df598b7a473759367855273c63912c9e2bc9a. It additionally requires shader-f16.

The runtime JS is copied from the package identified by package-lock.json. To
reproduce it: npm ci --ignore-scripts, then copy
node_modules/@mlc-ai/web-llm/lib/index.js to web-llm.js. build.json records hashes.
The initial browser download was roughly 2.7 GB. No model files are in this folder.

qualify.html runs real module-worker generation, mid-reply cancellation and the
existing clinical-age audio fixture. offline.html applies connect-src 'self' to
block external network connections while loading previously cached artifacts.
Both are diagnostic pages, not the product companion interface.

Observed on this Mac:
- Text completion, cancellation and the following text request pass.
- Cached model reload works with external connections blocked.
- **Float16 audio content fails qualification.** The recording says forty, but three
  request forms returned four, two and five. These are retained failures, not
  successful fallback acceptance. They do not establish a native 12B regression.
- The float32 build answers forty correctly in all three forms. On the eight
  existing synthetic audio fixtures, float16 answers 2/8 correctly and float32
  answers 6/8. A CPU float32 reference answers 7/8, also missing the planet
  question. The CPU reference uses Google's QAT unquantized checkpoint, not
  identical MLC weights; RNGs also differ. These results narrow the issue to
  build/precision differences but do not isolate the faulty numerical operator.
- Float32 text generation, interruption and restart pass. Its corpus also runs
  from cached assets with external network connections blocked.
- Float16 first text was 3242 ms cold, 58-62 ms warm; float32 was 1797 ms cold,
  74-82 ms warm. These are
  tiny diagnostic prompts, not full-persona or phone latency measurements.

Receipts are in outputs/companion-qualification in the enclosing workspace:
gemma-e2b-browser-text.json, gemma-e2b-browser-audio-failed.json and
gemma-e2b-browser-audio-comparison.json. The latter records all three failed
audio request forms. Do not enable automatic voice fallback based on text success.
gemma-e2b-browser-fp32.json, gemma-e2b-corpus-fp16.json,
gemma-e2b-corpus-fp32.json and gemma-e2b-cpu-corpus.json contain the subsequent
comparisons. corpus.html?precision=fp16 or fp32 reproduces the browser corpus;
Tools/BrowserGemma/reference.py CHECKPOINT RECEIPT runs the CPU comparison with
Transformers 5.20.2, Torch 2.7.1 and torchvision 0.22.1.

Remaining gates: explain audio-content failure against a known-good reference,
qualify target iPhone memory and sustained performance, cache persona/history and
voice state, integrate bounded endpointing/playback, and reconcile disconnected
turns exactly once after reconnect. The running Blessenger app is unchanged.

Adaptive loading is available through `loadAdaptiveBlessengerModel`. It prefers
E2B, then pinned Qwen3.5 2B and 0.8B q4f32 builds, subject to individual buffer
limits, estimated storage, and a conservative half-of-reported-memory budget.
When memory is unreported, it starts with 0.8B. These are eligibility heuristics,
not a measurement of free GPU memory or protection against an OS tab kill.
Failed loaders terminate their worker before trying the next eligible model.
No model changes happen during generation. Cached tensors bypass only the
download-space check; they do not prove all offline dependencies are present.

`node Tools/test-adaptive-browser-models.mjs` checks the selection and sequential
failure behavior. Qwen inference, iPhone performance, and application fallback
are not qualified yet. Qwen text generation also does not establish an offline
speech-input path; it needs a separately qualified local recognizer.
