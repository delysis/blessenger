# CompanionRTC

Candidate macOS bridge for browser microphone audio (Opus) and an ordered
`control` data channel. It opens no microphone or speaker. Browser PocketTTS
will render replies locally; this bridge receives audio only.

The WebRTC binary is pinned by release and SHA-256 in Package.swift. Its
custom-device header is copied from the iOS slice of the identical archive:
the macOS slice exports this API but omits the header.

One offer is accepted per peer. Reconnection creates a fresh peer. Callbacks
are not on the main thread. The app must supply a bounded ingress queue,
reject callbacks from obsolete session epochs, authenticate signaling, and
preserve explicit playback acknowledgements. Receiving a control packet is
not evidence that speech played.

`Tools/WebRTCProbe/companion.m` tests the actual bridge with three sequential
trickle-ICE sessions, generated 440 Hz input, control echo, 16 kHz frame checks,
and shutdown. The default host-ICE run passes; `--relay` accepts ephemeral ICE
configuration on stdin. Neither mode qualifies physical audio or app call routing.
The separate browser/native probe covers Chromium interoperability.

Linked into the macOS app target and root Swift package. Packaged-host tests
cover malformed configuration and repeated construction/close without hardware
audio. Paired HTTPS signaling now connects the browser microphone and control channel
to the call engine. Browser replies still use Mac-generated PCM; browser PocketTTS
and its retained-audio journal remain to be integrated. ICE restart on an existing peer is deliberately
unsupported in this first bridge; session recovery requires authenticated
signaling and a new peer. Internet signaling and iPhone qualification remain
open work.

Cloudflare relay qualification (2026-10-22): the installed app successfully
issued credentials, rejected unauthenticated issuance, and supplied two native
relay-only peers with working bidirectional Opus/control. Failures are retained
alongside passes in `outputs/companion-qualification/cloudflare-turn-*.json`.
The timed failure had 23 relay candidates, first available after 76 ms, but ICE
gathering was not complete at 5 seconds. The bridge now answers after setting its local description and signals
candidates incrementally, with bounded early-candidate admission. WebRTC calls
run outside the bridge lock; candidate delivery is queued off signaling callbacks
to avoid cross-peer lock cycles. Three host-ICE sessions and three packaged-host
tests pass after this change. The updated signed app is installed, including the total provider timeout.
Its paired credential route supplied three successful relay-only bridge sessions
(audio, control echo, and shutdown), connected in 151-228 ms; the unpaired route
returned 401. See `cloudflare-companion-installed-deadline.json`. These are
transport timings, not persona latency. Earlier request failures remain retained;
a successful run after restart does not establish their cause. This does not explain native persona
call regressions: those calls do not currently use this RTC bridge.

`Web/CompanionRTCSession.swift` owns one peer and bounded ingress for the app.
Its owner must authenticate signaling before construction and call `close()`
on teardown. Audio and control drain independently; 500 ms of pending 10 ms
PCM frames is a hard cap, not a target latency. Overflow signals the control
consumer and fails the session instead of silently dropping speech. Candidate
reads use repeatable cursors so a lost HTTP response cannot lose an ICE candidate.
The owner is connected through `CompanionRTCCall` and paired `/api/rtc/*` routes.
The browser closes its peer on hang-up; the host also watches control liveness,
since native audio callbacks can continue yielding silence after peer loss.

Actual app qualification exposed an actor-isolation crash on the native candidate
queue (incident 2F0EF1E3-0511-4350-963D-A46703E65759). The public Objective-C callback
contract now uses NS_SWIFT_SENDABLE, preventing Swift from inferring main-actor
isolation for native-thread callbacks. The regression test invokes the real
Objective-C delegate entry and awaits delivery from its native dispatch queue.
Sixteen selected packaged-host tests pass. The signed normal app then completed
a browser call with generated silence input and 21,120 muted AudioWorklet-rendered
output frames. This is not speaker/AEC/iPhone or latency acceptance.

Identity discipline: the normal app uses Library/Application Support/Blessenger/
Companion. Qualification launches have an isolated certificate AND pairing
identity under their qualification directory. Never give the qualification QR
or certificate as the normal app's pairing setup, or relaunch the normal user
bundle with a qualification directory while the phone is being qualified.
