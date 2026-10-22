# Cloud call cancellation and immediate retry

Run `python3 Tools/RTCCloudRetry/server.py` from the CallGemma directory and open
http://localhost:8955/ in a browser. Press Run. The test refuses to begin while
the installed app has a call active. Do not manually use the app during the run.

This loopback-only page uses the production CompanionRTC and call AudioWorklet,
with paired HTTPS signaling forwarded through the configured Cloudflare origin.
The existing cookie stays in the local proxy; it is never embedded in the page.
It dials the existing Peter conversation in the installed app, supplies synthetic
silent input, renders output at zero gain, intentionally hangs up once audio has
rendered, and immediately repeats. It does not create a diagnostic conversation.
Calls can append greeting records to the existing conversation.

Acceptance: both rounds deliver finite playback through the production worklet,
close, and admit the immediate retry without errors. This is a transport and
teardown test, not a full-greeting, microphone, echo cancellation or physical
iPhone qualification. The first-frame cutoff is deliberate for cancellation.
The original failing receipt is companion-qualification/cloud-call-retry-before.json
in the enclosing outputs directory. Preserve failures; do not automatically retry.

Enable **Speech** to inject `heldout-0.wav` (the documented synthetic Daniel
voice asking how many days are in a week) through the outgoing WebRTC audio track
after greeting playback and its acoustic tail settle (the synthetic track has no AEC). Each round must render at least 200 ms from a new response
epoch after that input finishes. Output remains muted. This checks post-input
progress and immediate redial; it does not assert the answer's semantic content,
real microphone echo cancellation, or physical iPhone behavior. The receipt also
records the browser user agent so engine coverage is explicit.

The spoken check exposed a production stall that the first-frame check missed:
clearing an already-drained playback ledger created a fictitious echo tail on
non-AEC capture, resetting a speculative utterance before its confirmation. The
original failure is `cloud-spoken-retry-before.json` in companion-qualification.

The native clock must also pass `check_clock.py <saved-system-log>` after both
calls. Save unified log entries containing `Blessenger remote audio clock` for
only the installed process under test. The check requires two calls of at least
three seconds, at least90 ten-ms frames/second (allows negotiation overhead),
no faster than101, and no sleep reaching50ms. This catches the background timer
coalescing regression even when a greeting-only browser check passes. Keep a
failed receipt; do not substitute a successful retry for it. The checker rejects
the recorded pre-repair baseline. It does not qualify acoustic AEC or Safari.
