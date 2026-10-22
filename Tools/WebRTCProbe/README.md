# Native/browser WebRTC qualification

These diagnostics use generated tones and never capture a microphone. Native
peers open no hardware audio unit; the browser's AudioContext renders zeros,
so its output remains silent. They are not part of the installed app or a
production signaling service.

First prepare the pinned M155 framework, validate its archive, and check the
native custom audio-device API:

    python3 Tools/WebRTCProbe/qualify.py WORK RECEIPT

Add `--roundtrip` to test two native peers exchanging different tones via Opus
and echoing a reliable data-channel message. Both receivers must detect the other
peer's tone, not their own. ProbeSupport.h is shared by the native and browser
tests and is hashed in receipts.

For the browser/native test, compile browser.m with clang, Objective-C ARC,
Foundation, AudioToolbox and the prepared macOS WebRTC framework. Include WORK
for RTCAudioDevice.h and set the executable's rpath to the framework directory.
Then run:

    python3 Tools/WebRTCProbe/browser-server.py PATH_TO_BROWSER_EXECUTABLE

Open http://127.0.0.1:8952/ and press Run. Signaling is restricted to the exact
loopback origin and host. Each child peer is bounded to 25 seconds. Do not expose
this diagnostic server on the LAN or internet.

The first actual Chromium run received RTP in both directions, but browser
WebAudio saw zero decoded samples. RTP counters showed 115 received packets,
while totalSamplesReceived and totalAudioEnergy stayed zero. Adding a silent
HTML audio consumer caused decoding and WebAudio measurement to run. The same
otherwise unchanged test then passed both tones and the data-channel echo.

The reusable adapter is Browser/RTC/remote-audio.mjs. It keeps its media element
muted; the WebAudio destination owns output. Abort tears down both consumers,
including when play admission is still pending. Tools/test-remote-audio.mjs
checks admission/cancellation races and cleanup. This corresponds to Chromium
issue https://issues.chromium.org/issues/40094084, but Safari has not been tested.

Current limits: host ICE only; no TURN, ICE restart, iPhone, real microphone,
echo cancellation, app call controller or public signaling acceptance. The
production companion still uses its existing local HTTPS PCM transport.
