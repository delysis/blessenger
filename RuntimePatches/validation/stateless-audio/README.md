# Completed-turn audio checkpoints

This evidence records why the LLM cache can omit the audio context for the
published Gemma 4 12B artifact. It does not claim that native audio inference or
macOS checkpoint tests ran in this environment.

## Actual model layouts

The files were inspected by bounded HTTP ranges from immutable Hugging Face
revisions. Every retrieved range has a SHA-256 receipt and its absolute byte
offset. No multi-gigabyte model was downloaded.

| Artifact | Revision | Encoder signature | Adapter | Upstream audio path |
| --- | --- | --- | --- | --- |
| Gemma 4 12B IT LiteRT | `7a0b1ce0ea821bcd01c5f72af84155e02191152f` | Float32 `src_inputs[1,1,640]` to Float32 `features[1,1,3840]` | None | Streaming wrapper around a stateless encoder |
| Gemma 4 E4B IT LiteRT | `e6a3892a8c22cf87ff99583996149cf3cb32452b` | Float32 `src_inputs[1,1,816,128]` and Bool `mask[1,1,816]`; outputs `features[1,204,1536]` and `mask[1,204]` | Present | Static encoder, with no `AudioContext` |

`12b-audio-signatures.json`, `e4b-audio-signatures.json`, and the two range
receipts contain the exact inputs and outputs. The 12B container section list
is also recorded in the earlier Gemma 12B evidence; `e4b-sections.json` contains
the smaller artifact's section list. Audio inspection fetched 32 KiB for 12B
and 96 KiB for E4B.

## Why no audio state is lost

All runtime source references below are pinned to
`5f25078c9439e176615af5ba42636ed904fca847`; exact Git blob identifiers are in
`source-receipts.json`.

The existing `IsStreamingEncoder` in
[`audio_executor_utils.cc`](https://github.com/google-ai-edge/LiteRT-LM/blob/5f25078c9439e176615af5ba42636ed904fca847/runtime/executor/audio/audio_executor_utils.cc)
classifies every encoder without an adapter as streaming. That causes
`ResourceManager::CreateContextHandler` to create an audio context for 12B,
even when a complete utterance is submitted at once. E4B has an adapter and no
`prev_` input; it follows the static path and needs no relaxation.

In
[`audio_litert_compiled_model_executor.cc`](https://github.com/google-ai-edge/LiteRT-LM/blob/5f25078c9439e176615af5ba42636ed904fca847/runtime/executor/audio_litert_compiled_model_executor.cc),
`CreateNewContext` and `CloneContext` exclude the recognized audio inputs. For
the verified 12B signature there are no other input buffers to retain.
`SwapInternalStateBuffers` has no matching input/output name to swap.
`streaming_chunk_overlap_size` defaults to zero, and the adapter-less property
path leaves it zero. The first-chunk flag changes only when overlap is positive.

Audio buffering defaults to false in
[`audio_executor_settings.h`](https://github.com/google-ai-edge/LiteRT-LM/blob/5f25078c9439e176615af5ba42636ed904fca847/runtime/executor/audio/audio_executor_settings.h).
With buffering disabled, `Encode` passes `is_flush=true` to
`EncodeSpecsAndMasks`, which processes a final partial window and clears the
buffered spectrogram. Thus the next utterance needs only newly supplied audio;
the previous input and features are scratch buffers.

`InputAudioEnd` in the execution managers calls `Flush`, not `Reset`. The patch
therefore does not assume that an end marker resets a recurrent encoder.
Instead its checkpoint-only admission requires the actual single audio input
and single features output, no adapter, no overlap, buffering disabled, and an
empty live and stored audio context. Other encoders retain the default
unsupported result.

## Synchronization and boundary

Cache acquisition first tries the existing LLM mutex, then the audio mutex if
either context uses audio. Failure returns before any context switch. The live
encoder and target context are validated under that audio lease. The existing
context-switch helper reuses the lease, so it cannot block on a second audio
acquisition. Normal acquisition still uses its existing blocking behavior; the
same-context inference return occurs before the new audio handling.

The existing session checks continue to require a completed successful decode
and no active task. Conversation cache validation additionally requires full
user/assistant turns. Advanced audio sessions are rejected explicitly:
`AudioSessionAdvanced::EncodeAudio` and `FlushAudio` can update partial audio
without changing the ordinary session state, so that state cannot establish
their completion boundary. The patch adds no per-token bookkeeping or audio
state copies.

## Regression coverage and limits

The existing 18,424-byte `dummy_audio_no_mask.litertlm` fixture was retrieved
from the same runtime revision and verified against Git blob
`de87e4b0b36963ee779a8bd98f5144739258b324`. It has one `src_inputs[1,10,8]`
input and one `features[1,5,5]` output, matching the state contract. Added tests
check continuation with a fresh encoder, a non-multiple final audio window,
buffered and recurrent model rejection, and nonempty stored context rejection.
Resource-manager tests check nonblocking audio acquisition, retry after a busy
lease, live and stored partial-state rejection, and switching between contexts.
Both execution managers test advanced-audio rejection before calling LLM cache
serialization or load.

`git diff --check` passed. Bounded syntax-only attempts using real existing
headers stopped at missing `litert/cc/litert_compiled_model.h` and
`runtime/components/model_resources.h`. `syntax-check.json` records the exact
commands and diagnostics. Native unit tests and the model/device round trip
remain required; no replacement headers or simulated hardware were used.
