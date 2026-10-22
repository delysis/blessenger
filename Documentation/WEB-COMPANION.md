# Blessenger web companion

The Mac hosts the existing Gemma 4 12B runtime, persona prompts/voices, and message store. A paired iPhone connects on the same Wi-Fi. No cloud relay or public port forwarding is configured. The Mac must remain awake and running Blessenger.

## Setup

1. Open **Connect iPhone** in the Mac app's menu. First use creates this Mac's local HTTPS identity and starts the server. Later launches retain the hostname, port, and pairing credentials.
2. Use the shield button to reveal **Blessenger.cer**. AirDrop that certificate to the iPhone. Install its profile in Settings, then enable its trust under General → About → Certificate Trust Settings. This is a one-time trust decision on the phone. The app does not alter device trust automatically. The generated CA is constrained to this Mac's `.local` hostname.
3. Scan the pairing QR code. Open the page in Safari, then Share → Add to Home Screen. Allow microphone access when starting a call or recording a voice note.

Certificate/private keys and pairing credentials are stored in the Mac's private application-support directory. Do not copy the private key or configuration JSON to the phone. The current leaf certificate expires after one year; automated renewal is still pending. Changing the Mac's local hostname also requires certificate reissuance. A production release must address that maintenance before calling setup permanent.

## Implemented

- Responsive standalone shell, light/dark appearance, safe-area spacing and keyboard viewport handling.
- Existing contacts with actual avatars; recipient autocomplete accepts Tab and Enter.
- Shared direct/group conversations and real model text replies.
- Phone microphone voice notes, in-composer preview/cancel/send, waveform playback and seeking.
- Live call PCM transport through the existing call controller. Browser render acknowledgements drive retained playback history; cancellation changes epochs and discards queued old audio. Phone connection loss ends the call rather than replaying stale audio later.
- Persistent QR pairing over TLS, same-origin checks, secure HttpOnly cookies, bounded request bodies and concurrent connections. The service worker caches shell resources only, never conversation data or audio.

## Qualification boundary

See `outputs/companion-qualification` at the task workspace root. Verified with the actual app and 12B: HTTPS authentication checks, text replies, voice-note admission and byte-preserved download, two remote greetings with timed simulated renderer acknowledgements, and the existing muted native handoff/cancellation/redial regression. Component tests cover old-epoch acknowledgements and audio-worklet cancellation/final capture flushing.

The phone layout and Tab acceptance were checked in a localhost UI fixture. That fixture is not an authenticated web end-to-end result. Browser automation could not resolve the Mac's `.local` address. Physical iPhone certificate installation, Home Screen installation, Wi-Fi discovery, microphone permission, speaker echo cancellation, barge-in, and foreground/background behavior are not accepted yet.

The HTTP audio transport currently uses repeated bounded exchanges, not WebRTC. Do not infer Wi-Fi latency or acoustic reliability from local client measurements. Other native features (contact editing, full reaction menu, group editing and wake-name enrollment) are not yet replicated in the web UI. Rename/reaction API routes exist but the controls are pending.

## Original ANE cache-write repair

`ModelPatches/mobius/0001-exclude-padding-from-cache-writes.patch` fixes padded-token cache writes at the exporter source, before conversion. The locally generated conditioner assets use it. This is a maintained local upstream-source patch; no upstream PR or merge is claimed.
