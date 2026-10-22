# Remote companion transport

Status: design constraints, not an implemented remote-access feature. The current
companion uses authenticated local HTTPS and PCM exchanges. It contains no ICE,
STUN, TURN, or RTCPeerConnection implementation on either endpoint.

The QR pairing relationship should survive changing networks. A network session
must not be treated as the pairing identity. Reopening the installed PWA must be
able to reconnect without the Mac's .local hostname resolving on that network.

Required implementation:

- Persist a device key established during local QR pairing and support revocation.
- Use an internet-reachable authenticated signaling channel for fresh sessions and
  ICE restarts; exchange offers/candidates only between paired devices.
- Add a native WebRTC endpoint to the Mac and RTCPeerConnection to the browser.
  Use Opus media for audio and an authenticated data channel for app operations.
  Preserve the existing model/controller path; do not capture or render through
  the Mac's physical microphone/speakers for a remote call.
- Prefer direct ICE connectivity, with credentialed TURN fallback. Obtain short-
  lived relay credentials through a trusted service; no provider admin key in JS.
- Preserve call identity, cancellation epochs, bounded ingress and backpressure.
  Network receipt is not playback completion. Late audio from a cancelled reply
  must never be rendered or committed to retained conversation history.
- Cache the public PWA shell for reopening away from home. Private API calls and
  media must use the connected peer, not fall back to unreachable local HTTP.
- Handle Wi-Fi/cellular migration, app suspension, reconnect, host sleep/wake,
  and explicit hang-up without replaying previous audio or duplicating messages.

Native implementation candidates inspected:

- https://github.com/stasel/WebRTC : packaged native WebRTC including macOS.
  Must verify custom PCM input/output support on macOS before choosing it. A
  default hardware audio device would route audio to the wrong endpoint.
- https://libdatachannel.org/ : C/C++ library with C bindings, macOS support,
  data channels and media transport. Media transport alone does not supply an
  audio codec, playout timing, or the app's render-completion semantics.

The stasel M155 archive has now been downloaded into a scratch probe, verified
against its published SHA256, and exercised on macOS arm64. It has not been added
to the application. The macOS package omits RTCAudioDevice.h even though the
factory implements that interface. Supplying the matching header from the same
archive's iOS slice lets the native peer initialize a custom audio device, obtain
both PCM callbacks, and generate an Opus SDP offer. No hardware device is opened.

Reproduce with Tools/WebRTCProbe/qualify.py WORK_DIRECTORY RECEIPT_JSON.
Evidence: outputs/companion-qualification/webrtc-native-probe.json (relative to
the enclosing workspace). This is an API qualification, not a connected media
roundtrip or app acceptance. The next probe now passes bidirectional PCM through
Opus and a control data-channel echo between two native peers. Each receiver
detects the other peer's distinct tone, not its own tone; neither opens hardware.
Reproduce with the same tool and --roundtrip. Evidence is
outputs/companion-qualification/webrtc-native-roundtrip.json. Browser
interoperability now also passes a generated-tone Opus exchange in both
directions plus data-channel echo with Chromium 155. Its first failure exposed
a remote decoding issue: packets arrived, but WebAudio received no PCM until a
silent media-element consumer was attached. Browser/RTC/remote-audio.mjs owns
that consumer and handles cancellation during playback admission. Evidence is
webrtc-browser-native.json and the preserved first/render failures in the same
receipt directory. These are diagnostic connections, not the production app.
TURN, ICE restart, Safari/iPhone and actual app integration remain open.

Acceptance requires actual phone tests: pair on Wi-Fi, converse, switch to
cellular, reconnect after closing/reopening, force TURN-only connectivity,
interrupt a reply, then verify cancellation/history and hang-up. A local peer
handshake or an API harness does not satisfy this gate.

Provider options checked 2026-10-21:
- https://developers.cloudflare.com/realtime/turn/faq/ : free public STUN,
  1000 GB monthly free Realtime allowance, then $0.05/GB TURN egress.
- https://www.metered.ca/tools/openrelay/ : account-backed free TURN allowance
  of 20 GB/month. No external provider account has been created for this app.

## Updated requested architecture (2026-10-21)

User selected Cloudflare STUN/TURN and browser-local PocketTTS plus VAD, with a
Gemma 4 E2B WebGPU fallback during disconnection. This supersedes the earlier
assumption that the Mac must synthesize and transmit all spoken replies.

- Online: Mac Gemma 4 12B generates validated text; browser PocketTTS synthesizes
  the selected contact's voice. Capture, echo cancellation, VAD, endpoint state,
  cancellation epochs and playback acknowledgements remain coordinated. Mac
  generation cancellation must follow local barge-in, not await queued playback.
- Offline: cache the exact persona prompts, voice conditioning, model artifacts
  and conversation needed for E2B. Keep temperature 1. Preserve the existing
  two-stage speculative endpointing. Reconcile committed offline turns once,
  without replaying audio or starting simultaneous remote and local replies.
- Assume E2B at 4-bit precision pending clarification of the user's “4b” wording.
  Safari 26/iOS 26 has WebGPU; model memory, supported operators, audio inputs,
  sustained performance and cache persistence still require device qualification.
  WebLLM 0.2.86 now has a pinned E2B q4f16 browser candidate in Browser/Gemma.
  Actual browser-worker text generation, cancellation and cache-only reloading
  pass on this Mac. Float16 audio produced incorrect ages in three request forms;
  float32 computes all three correctly. Across eight recordings, float16 scores
  2/8, float32 6/8 and the distinct Google QAT unquantized CPU checkpoint 7/8.
  The candidate now defaults to q4f32_1 (still 4-bit weights). The exact numerical
  fault is not isolated, and target-device acceptance remains open. This is a
  new E2B runtime test, not evidence of a new failure in the native 12B app.
- Use Cloudflare's public STUN and short-lived TURN credentials. The new native
  CloudflareTURN broker reads a TURN key from Keychain service
  Blessenger.CloudflareTURN / account credentials, JSON {id,token}. It does not
  read a general account API token. Authenticated POST /api/ice exposes only
  expiring ICE credentials. No provider key is configured yet; live TURN and
  refresh/reconnect remain untested. The source is built/tested but not installed
  into the running companion candidate at this checkpoint.
- PocketTTS WASM candidate is gradium-ai/xn-ptts/ptts-wasm, linked by upstream
  Kyutai. Must preserve the fourteen supplied voices and compare generated PCM
  against upstream, including onset, EOS, padding and multi-clause regressions.
  All fourteen contact states now synthesize in an actual browser worker and
  reproduce their first PCM frame after cancellation. Muted AudioWorklet tests
  also pass bounded playout, cancellation and restarting with another voice.
  The phone and the production companion are not yet using this path.
- Earshot WASM is now built from the exact native revision. Node WASM vs native
  Rust predictions on 228 clinical-age frames differ by at most 2.98e-8. This
  validates detector portability, not Safari capture, endpointing or integration.
  Source and adapter are in Browser/Earshot; receipt is browser-vad.json.

Reference sources:
https://webkit.org/blog/17333/webkit-features-in-safari-26-0/
https://ai.google.dev/gemma/docs/core
https://github.com/kyutai-labs/pocket-tts
https://github.com/gradium-ai/xn-ptts/tree/main/ptts-wasm
https://developers.cloudflare.com/realtime/turn/generate-credentials/
