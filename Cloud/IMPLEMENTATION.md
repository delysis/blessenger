# Companion HTTPS deployment — current evidence

2026-10-22: deployed https://blessenger.georgewalkeriv.workers.dev using the
existing Workers subdomain on the user's Cloudflare account. No custom domain
or iPhone certificate installation is needed. Wrangler authorization uses
account:read, user:read and workers_scripts:write; login is stored in Keychain.

Workers static assets serve the public PWA shell. A Durable Object accepts one
authenticated outbound Mac WebSocket bridge. Private routes require the existing
normal Blessenger pairing/session credentials; Cloudflare stores SHA-256
verifiers only. The host credential is stored in the Mac Keychain under
Blessenger.CloudGateway / host. Requests are allowlisted, bounded and limited
to eight concurrent requests. Response chunks use an eight-credit window of fixed 48 KiB chunks (384 KiB per request), coalescing smaller TLS reads.
The bridge verifies the native localhost TLS certificate against its existing CA.

Deployment verification: public shell 200; unauthenticated state 401;
authenticated state 200 (ready true, inCall false); pairing 200 with Secure cookie.
A real browser paired and displayed the native conversation list without a
certificate warning. The user confirmed conversations load on the physical iPhone without a privacy warning. iPhone voice acceptance is pending. Browser calling,
media latency, reconnect, and large model downloads through this deployment
are not yet qualified. Do not equate this with completed offline inference.

The bridge runs as the user login service com.blessenger.gateway, installed by
install-gateway.py. launchd restarts it on failure; the WebSocket reconnects
with bounded backoff. After replacing the terminal process with the login
service, authenticated requests again returned 200 with native ready=true.
The native app must still be running for chat and voice. The installed signed app now selects the configured HTTPS origin for View >
Connect iPhone. Vision decoded the rendered native QR and matched it to the
normal identity and deployed HTTPS origin. The standalone cloud QR remains
valid. Public origin is optional; unconfigured installs retain the LAN route.

Six Cloud gateway tests pass, including a real workerd authenticated WebSocket
round trip, streamed response, duplicate-host rejection, host-disconnect error,
and successful replacement-host requests without replay. Receipts are in work/.

Sing comparison: its agent confirmed HTTP LAN QR + Bonjour for page rendering;
its microphone uses a separate native Swift app. Local HTTP was added on port
8942 with separate credentials and disabled microphone controls. The earlier listener reported Bonjour NoAuth. Reusing the existing declared
Bonjour service type repaired listener admission in the installed build. All
14 local HTTP checks pass, including separate credential boundaries, Host and
Origin rejection and disabled plaintext voice. Physical iPhone LAN browsing
remains unverified. Native TLS on 8943 retains the original stable identity.

Live asset qualification (Cloud/qualification/assets.mjs): Earshot WASM
86,136 bytes in 438 ms; PocketTTS WASM 5,021,288 bytes in 16,433 ms. Both
SHA-256 hashes exactly match the signed app's packaged manifest. Ten cancelled
model downloads each left authenticated state available. Receipt:
companion-qualification/cloud-live-assets.json. This establishes integrity and
continued availability after cancellation, not full-model loading performance.
The single outstanding 48 KiB credit incurs substantial WAN latency; bounded
multi-credit streaming should be evaluated before the 300 MB model load.


Transfer repair deployed: version 31d84dfa-3269-4951-9491-f9683e1d2378,
with the Mac bridge coalescing TLS reads into fixed chunks. PocketTTS WASM
transfer improved from 16,433 ms to 7,967 ms with the window, then 4,924 ms
with coalescing. Final hashes match exactly; ten cancelled model downloads
still leave state available. Ten tests pass, including serialized reads,
credits arriving during I/O, cancellation of pending reads, credit bounds,
coalescing integrity, authentication and reconnect. Receipt:
companion-qualification/cloud-window-assets.json. Full-model and on-device
synthesis are still pending; these are transfer measurements only.

TURN prompt repair: CloudflareTURN now retains a successfully loaded Keychain
key in an actor, coalesces simultaneous issuance and reuses credentials until
60 seconds before expiry. Six focused tests passed against unchanged production
source, including refresh, concurrent callers and retry after provider failure.
The full SwiftPM app test entry failed on existing duplicate compiled Core ML
resources; the signed Xcode Release build passed. The installed app returned
identical credentials over three requests (6678/2/2 ms), and after relaunch
(7299/4/3 ms). Existing Keychain item was updated to trust signed Blessenger.
Only non-secret status/timing receipts are retained.

Physical iPhone call remains FAILED: microphone frames reached the Mac but no
playback acknowledgements arrived. A later attempt recorded 316 input frames,
zero controls and requested close. This does not establish that speaking caused
the failure. Current native and web builds record native close reason and a
paired, bounded, once-per-call Safari error classification/SCTP cause report;
no SDP, network addresses or transcript are included. Root cause remains open.


2026-10-22 retry lifecycle repair: browser Call previously became available
before pending admission or RTC teardown finished. Call setup and teardown now
retain media ownership until completion, and RTC close returns one shared
server-disposal promise. The lifecycle test was stale (VM rejected the new
module import); it now executes the real RTC class with a fake browser peer and
checks late microphone permission, late admission, and delayed teardown/retry.
Both lifecycle and RTC tests passed. Cloud deployment version
9257879a-8fad-4355-a7d7-221c1c10822f serves exact matching source bytes.
Installed native app accepted four consecutive Cloudflare-mediated RTC setup
cycles alternating cancellation and invalid offers; each released admission,
and final inCall was false. Receipt: companion-qualification/rtc-admission-retry.json.
This proves admission cleanup, not physical iPhone playback or the original
SCTP failure. No new iPhone failure trace has arrived yet. Native packaged web
resources still require the next normal signed rebuild; deployed PWA is updated.

Full PocketTTS weights transfer completed: 219029196 bytes in 69252 ms, SHA256
473f47d99560bd50eb8b4509d3cacfe7f316ab20bdca86505403a2e6a936a6e9 matches
packaged manifest. Ten cancelled downloads left state available. Receipt:
companion-qualification/cloud-full-model.json. This verifies transport only;
iPhone model initialization and synthesis remain unqualified.


Deployed paired-browser speech check: /speech-check uses the production
/runtime.js loader, authenticated versioned runtime assets, real module worker
and WASM, and no call or audio output. Cloud version
97450883-d73f-4760-800c-2cef6ed3b25b. Mac in-app browser passed first load
(88822 ms), then worker recreation using browser cache (2373 ms); 17280 finite,
non-silent samples each, first audio 74.7/85.2 ms after synthesis request.
Receipts: companion-qualification/cloud-browser-speech.json and
cloud-browser-speech-cached.json; screenshot cloud-browser-speech.png.
This is Mac browser synthesis, NOT iPhone performance, acoustic acceptance,
or integration into active calls. Ten Cloud tests plus browser lifecycle,
RTC and bounded speech playback checks passed. Native web route source added
but not rebuilt/installed yet. Diagnostic page has no private data; runtime
and model downloads remain authenticated. Cloud clean-URL /speech-check alias
is explicitly allowed because static assets redirect .html to extensionless.


Native retry build installed 2026-10-22: signed Xcode Release build passed
(work/rtc-retry-native-build.log). Installed native /app.js, /rtc.js and
/speech-check.js all exactly match current sources; /api/state ready=true,
inCall=false. Signature verification initially found one stale extra bundle,
Contents/PlugIns/CallGemmaTests.xctest, retained by ditto's merge semantics.
Moved only that extra artifact to work/stale-companion-test-bundle-20261022.xctest;
strict deep signature verification then passed. Future install copies must
stage a fresh bundle and replace the old one, rather than merge directories.
Normal application data and Keychain identity remain unchanged. Additional RTC
regression proves browser error callback and subsequent UI cleanup share exactly
one pending server disposal promise. Physical iPhone call still awaits retest.


Actual-app immediate redial regression reproduced and repaired:
Tools/RTCCloudRetry uses the real browser RTC class/worklet and installed app,
with HTTPS signaling routed through Cloudflare, muted output and silent synthetic
input. Before native repair first call rendered audio, second failed Audio is busy
(cloud-call-retry-before.json). Native /rtc/end and /call/end had acknowledged
closure before CallController's asynchronous teardown completed. Added
waitForCallTeardown, joining the stopped call task (never an active new call),
and await it before server acknowledgement. Signed Release build passed and a
fresh staged bundle replaced the old bundle; strict signature verified.
Same scenario passed both rounds after installation (cloud-call-retry-after.json
and .png): peer opens 15873/495 ms; first render from start 18563/1877 ms.
These are transport tests, not iPhone or acoustic acceptance. Initial credential/
connection delay remains slow and needs breakdown. Second native close logs
control channel unavailable during the intentional client disconnect; the browser
reported no failure before intentional hang-up. Do not erase that trace.
Qualification proxy stopped after test. Previous app preserved at
work/Blessenger-before-teardown.app. Current app log work/blessenger-teardown-barrier.log.


First-call timing and relay qualification 2026-10-22:
Installed signed timing build (work/turn-timing-build.log, running log
work/blessenger-turn-timing.log). First saved-key read 11.323596 s;
Cloudflare issuance 0.176948208 s. User reports no prompt just then, but many
prompts during preceding hour. Do not attribute this delay to TURN networking.
Actual-app two-call retry passed with browser iceTransportPolicy=relay and
getStats selected local candidateType=relay on both calls. First /rtc/start
11632 ms vs second119 ms; peer open12203/636 ms, first render16132/2058 ms.
Receipt cloud-call-forced-turn.json and screenshot .png. Synthetic silent input
and muted rendering, NOT physical iPhone acoustic acceptance.

Read-only Keychain ACL inspection (work/inspect-turn-access.swift) found trusted
Blessenger app paths and /usr/bin/security, but partition plist Partitions only
[apple-tool:], missing current signed TeamIdentifier VB37TV2P46. This is a
concrete access-rule mismatch, plausible source of repeated prompts; causal
latency proof requires repair and cold read comparison. Attempt to preserve all
existing ACLs and append teamid:VB37TV2P46 to the partition via
SecKeychainItemSetAccess failed -25293 (authentication failed); no repair claimed.
Scripts/logs work/repair-turn-access.swift, turn-access-repair.log. Credential
bytes never read by these inspectors. Current in-process cache still works.
Forced relay test proxy stopped. Native app remains open and idle.


Browser VAD diagnostic deployed version98622f8f-3fea-448f-95f0-410c48bc7b56:
real production runtime loader resamples generated 24k speech via browser OfflineAudioContext
to16k, Earshot processes45 frames, max probability0.95694, exact reset repeat.
Receipt cloud-browser-speech-vad.json. First attempt failed host unavailable
(browser-vad-host-unavailable.json); native process had logged normal shutdown
coincident with stopping parent qualification exec. Relaunched via macOS CUA
getApp (LaunchServices), independently of proxy lifetime. Do not launch the app
as child of a short-lived test server exec session again.

User approved Keychain UI authorization and reported done; subsequent read-only
ACL inspection still shows only apple-tool partition, and first app credential
request still took7238 ms (turn-after-user-authorization.json). No corrected ACL
or resolved cold Keychain access claim is supported. User then reported idle
system-wide audio attenuation; this has become immediate priority.


Idle ducking repair (user reports other apps attenuated even with no call):
PreparedAudioEngine previously retained VoiceProcessingIO render resources at
startup (prepare) and after calls (pause). Changed prewarm to stop after prepare,
and changed hardware pause to stopWhenIdle using engine.stop, preserving the
graph but releasing render resources. AEC remains enabled for actual calls.
Signed Release build passed (idle-audio-final-build.log), fresh staged install
verified, launched through macOS. Live process22800 logs input=false/output=false
at idle after prewarm; receipt idle-voice-resources.log. User listening check is
pending; no acoustic resolution claim yet. Added resource-allocation fields to
hardwareSnapshot and assertions in opt-in recording qualification covering
prewarm and recording teardown. These new assertions are not yet executed and
are subsequent source changes beyond the installed binary's diagnostic fields.
Apple docs describe stop as releasing resources and default VPIO ducking behavior;
full absence of in-call attenuation is not established by this change.

Idle ducking follow-up: user reports other apps are STILL quieter with the
stop-after-prepare build. Resource allocation false is therefore insufficient
evidence of unducking. Confirmed no active call and fully quit PID 22800; awaiting
comparison with the process absent. No remaining CallGemma process was found.
The focused Release XCTest attempt failed before execution because imported
modules lacked enable-testing, not due to a test assertion. Rebuilding the test
bundle with ENABLE_TESTABILITY=YES; do not launch audio tests during the user
quit-versus-idle volume comparison.

Idle ducking root-cause evidence (2026-10-22): coreaudiod explicitly logged
PID 22800 unducking on process exit, matching the user hearing increased volume.
A minimal AVAudioEngine probe reproduced ducking at setVoiceProcessingEnabled(true)
before starting capture, scalar 0.177828. prepare/stop left voice mode enabled;
setVoiceProcessingEnabled(false) emitted unducking and scalar 1.0. Apple minimum
ducking was separately measured at 0.630957, so it is NOT a complete no-duck fix.
Source now disables voice mode after prewarm and on teardown, re-enables it before
capture, and reapplies diagnostic AGC selection. Added assertions for idle voice
mode off and active capture voice mode on. Testing/install remain pending.
User also reported volume fell again with the app absent; the bounded subsequent
coreaudiod log had no new DuckClientVolumeScalar event. Do not attribute that
second drop to Sing/WebKit merely because they were active output clients.

Idle voice-mode repair qualification: initial tests correctly caught redundant
graph rebuilds caused by the mode-switch configuration notifications. Reuse now
compares actual idle I/O formats; an initial 0-Hz output format is adopted when
first valid, and later format changes still rebuild the graph. The final real
microphone XCTest passed two recordings with voice mode ON while active, OFF and
resources released after each stop, and unchanged graph build count. Result:
work/IdleVoiceMode-stable-20261022.xcresult; no failures (8.517 s). Failed prior
receipts preserved. Signed product staged fresh, signature verified, installed
and launched through macOS as PID31358. Public state ready=true/inCall=false.
Installed process coreaudiod log shows duck at startup prewarm then explicit
unduck on completion at03:24:57.744 while process stays alive, not only on exit.
Receipt outputs/companion-qualification/idle-voice-mode-installed.log. There is
still a brief startup-prewarm duck and ducking during active native capture.
User listening confirmation and call latency/acoustic requalification remain
pending; no full voice-regression resolution claim.

Startup dip removed (2026-10-22): graph connections and capture buffers can be
constructed with voice processing disabled. build() no longer enables or prepares
the voice I/O unit; start() enables and verifies AEC before capture. An inability
to enable AEC now fails capture explicitly rather than silently falling back to
unprocessed speaker input. iOS category selection remains before format queries
and session activation before voice enablement; iOS not newly qualified.
Opt-in real-microphone repeated recording test passed again (5.829 s, zero
failures), including unchanged graph count and active/idle voice-mode assertions.
Measured startup graph construction45.377ms; voice activation947.707/897.643ms;
hardware start41.283/47.986ms. This added per-capture activation remains a native
pickup performance concern, not a latency victory. Receipt idle-voice-graph-timing.json.
Signed Release build passed and installed fresh as PID33055. Actual native UI:
selected Peter; recorded14s; finished to inline unsent preview; discarded; started
a second recording and cancelled. No message sent. CoreAudio logged duck only
for the actual captures and explicit unduck after each. Startup had no duck event
for this process. App API ready=true/inCall=false afterward. Receipts:
lazy-voice-startup-system.log and lazy-voice-native-recording-system.log.
Audio probes are now finished. User audible confirmation remains pending; earlier
volume judgments could be contaminated by diagnostic voice-engine activation.

Actual browser spoken-input qualification (2026-10-22): RTCCloudRetry now has an
optional Speech fixture, sent as an Opus track through the real app, and requires
rendered output in a new reply epoch before hanging up and immediately redialing.
It is muted Chromium, synthetic non-AEC input, not Safari or acoustic acceptance.
This caught a post-speech stall omitted by the previous greeting-only test:
clearPlayback renewed an echo tail even when no audio remained queued. That
false tail reset the pending speculative utterance and stranded TTS behind its
confirmation gate. Only genuinely queued playback now renews the cancellation
tail. Preserved before/after and separate non-AEC half-duplex fixture failures in
outputs/companion-qualification/cloud-spoken-retry-*.json. The fixture waits for
the greeting to finish before speaking because it explicitly declares no AEC.

The next timed run caught a distinct native RTC clock defect: its ordinary
NSThread wall-clock sleep delivered 507 ten-ms frames in12.142s, then674 in49.483s;
work took46.557/117.459ms total, but max sleeps120.414/126.200ms. Second call did
not reply. remote-clock-before.log and cloud-spoken-clock-before.json preserve
this failure. Added a thread-lifetime NSActivityLatencyCritical plus
NSActivityUserInitiatedAllowingIdleSystemSleep activity, balanced at thread exit,
without changing the timer or adding hardware audio capture. Comparison pending.

Clock comparison completed: activity-only run passed two spoken calls, max sleeps
13.457/18.216ms, but fresh relative deadlines still delivered only80fps. Switched
to an absolute monotonic mach clock with10ms increments; missed deadlines skip
forward rather than burst stale frames. Final signed installed process36788:
684frames/6.972s and618/6.352s (98.1/97.3fps including negotiation), maximum
sleeps12.509/15.920ms. Both spoken calls replied/rendered and immediately redialed;
first reply audio after fixture end563/537ms. check_clock.py rejects original
baseline and passes final log. Receipts remote-clock-final{,-check}.json/log and
cloud-spoken-clock-final.json. First cold rtc/start still12539ms, second308ms;
Keychain cold-read delay remains unresolved. This is Chromium + synthetic Opus
input + muted browser output, not renewed iPhone/speaker acceptance. App left
ready and idle. Native per-capture VP activation cost remains unresolved too.

2026-10-22 user acoustic acceptance: other-app volume is "Normal and staying
normal" with the idle repaired build. This qualifies the reported idle ducking
repair; does not qualify full-duplex phone calls or all remaining regressions.

Cold TURN access repair: securityd repeatedly logged ACL partition mismatch,
client teamid:VB37TV2P46 versus original item apple-tool:. loadKey now prefers an
app-owned Keychain item, imports the validated legacy key once by SecItemAdd
inside the signed app, preserves original, and checks the saved item. No secret
in files/logs or provider token sent to clients. New item ACL inspected read-only:
partition teamid:VB37TV2P46. First migration rtc/start11866ms; after full app exit
and fresh launch, rtc/start289ms including Cloudflare issuance, two ICE servers,
peer explicitly closed without starting a call. Receipt turn-owned-relaunch.json.
This is actual signed-app fresh-process acceptance, not a mocked Keychain test.
CLI import tool remains first-install-only (already refuses existing items);
credential rotation must update the app-owned item, not the preserved legacy
item. No automatic deletion of legacy credentials performed.
