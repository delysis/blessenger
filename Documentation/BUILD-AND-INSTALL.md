# Build and install Blessenger on Mom's Mac

This is a handoff for the agent running **on her Mac**. Do the commands, diagnose
failures, and install the app; do not ask her to export models or edit source.
Only OS/account permissions require her participation. Preserve existing chats,
model caches, credentials, and installed app until the replacement is verified.

## 1. Check the machine

This target requires **Apple Silicon and macOS 26 or later**, with full Xcode
and its macOS SDK. The working build uses **Xcode 27.0 (27A266a)**; use that
version or newer for the first build. Older toolchains are unqualified. Intel
and older macOS are not supported by this target.
The source currently uses a 12B Gemma default; check available memory before
promising that model on a smaller Mac. The app applies a memory-capacity policy.
A build and model download can consume tens of GB: check free space first.

```sh
uname -m
sw_vers
xcode-select -p
xcodebuild -version
sysctl -n hw.memsize
df -h .
```

Install full Xcode from Apple if absent. If necessary select it using
`sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.
Xcode first launch/license acceptance may require the user's interaction.
Command Line Tools alone are insufficient.

Install Git, Python 3, Bazelisk, and a current Rust toolchain. With an existing
Homebrew installation: `brew install git python bazelisk rustup` then
`rustup default stable`. Verify `git`, `python3`, `bazel`, `cargo`, and `rustup`
are on PATH. Do not overwrite an existing Rust setup. Bazelisk supplies the
runtime checkout's pinned Bazel version. No PyTorch, Core ML conversion,
PocketTTS Python package, or manual model export is required.

## 2. Clone and bootstrap

```sh
git clone https://github.com/delysis/blessenger.git
cd blessenger
bash Tools/bootstrap-mac.sh
```

The bootstrap does the following, stopping on the first failure:

1. Downloads the immutable `speech-assets-v1` GitHub release archive and checks
   its pinned size, SHA-256, complete file inventory, and each file's SHA-256.
2. Installs the corrected native PocketTTS exports and browser model/voice states.
   Existing matching files are reused. Conflicting local files are not replaced.
3. Fetches exact upstream LiteRT/LiteRT-LM revisions, applies the repository's
   patches, and compiles the native runtime with Bazel. This can take a while.
4. Builds native Earshot and its browser WASM module using pinned dependencies.
5. Resolves pinned Swift packages, applies the FluidAudio patches, builds the
   Release macOS app, verifies its signature, and installs it under
   `~/Applications/Blessenger.app`.

The speech exports are supplied ready to use. **Do not use upstream's uncorrected
ANE transformer exports instead. Do not ask Mom to run model conversion.** The
archive contains no Gemma weights, account credentials, or user conversations.
Licenses and attribution are in `Documentation/Licenses/`.

If an archive was downloaded separately, installation can be resumed with
`python3 Tools/fetch-speech-assets.py --archive /absolute/path/to/archive.tar.gz`.
It still performs all integrity checks. Full runtime rebuild inputs are strict:
if runtime patches changed, use a new work directory rather than erasing evidence.

## 3. Existing installation and signing

The default macOS build is locally ad-hoc signed; it does **not** require George's
Apple developer identity. It is not a notarized public distribution. Never
remove macOS security protections to force it to launch. Local Xcode builds and
normal system permission flows should be used.

If `~/Applications/Blessenger.app` already exists, the installer deliberately
refuses to overwrite it. Build to a fresh destination instead:

```sh
CALL_GEMMA_APP_DESTINATION="$HOME/Applications/Blessenger-next.app" bash Tools/build-app.sh
```

Verify the new build, ensure no call is active, quit the old app, and preserve it
as a backup before replacing it. Never run two copies against the same app data.
For stable microphone/Keychain identity across updates, use her own available
Apple Development signing identity. Do not copy George's certificate or secrets.
Ad-hoc rebuilds can require renewed OS permissions.

## 4. Models and first launch

```sh
open "$HOME/Applications/Blessenger.app"
```

Allow microphone access when macOS asks. The agent cannot substitute for that
OS consent. Model loading may initially take time.

Gemma uses its pinned Hugging Face repository/revision/file. It reuses the shared
HF cache, downloads on a miss, and checks size and SHA-256. PocketTTS's upstream
encoder/decoder/tokenizer assets also download from a pinned HF snapshot when
missing. The corrected transformer assets installed by bootstrap are bundled
into the app and copied to its cache namespace automatically.

The default HF cache is `~/.cache/huggingface/hub`. `HF_HUB_CACHE` or `HF_HOME`
overrides are supported; Finder-launched apps do not inherit arbitrary shell
exports. If she uses a nondefault cache, launch with the intended environment
or arrange the app's launch environment explicitly. Do not move/delete her
shared model cache. If HF reports gated access, she must accept the relevant
model terms using her own account. Never put an HF token in Git or chat.

## 5. Acceptance on her actual Mac

Do not equate build success with functioning voice calls. Verify:

- The sidebar contains the persona prompts, portraits, and all fourteen voice
  references from the repo. No duplicates are created by repeated calls.
- Call Peter, hear a complete greeting, speak a two-sentence request, and obtain
  a relevant response. Interrupt a reply and confirm it stops without replay.
- Hang up, call Gabor, and repeat; verify prompt pickup and stable connection.
- Record a voice note, stop, preview and scrub it, cancel it, then record/send one.
- Leave the app idle while another app plays audio: its volume must stay normal.
- Quit/relaunch; chats persist and model assets are reused.

Keep failures and exact build identifiers. Read `Cloud/IMPLEMENTATION.md` for
known limits; this handoff does not certify all devices or group calling.
Native logs live under `~/Library/Application Support/CallGemma/Diagnostics/`.
Use `Tools/blessenger-control.py --help` for available app diagnostics.
Do not upload her conversations or microphone recordings to public issues.

## 6. Optional iPhone PWA / Cloudflare

The native Mac app does not need Cloudflare. Do not deploy the checked-in
`wrangler.jsonc` against George's account from her Mac. The existing public
companion is paired to George's host; it does not automatically discover hers.
For her own deployment, use her Cloudflare account, change the Worker/account
configuration, and provision fresh gateway and TURN secrets using the supplied
Cloud tools. Run `npm ci`, `node build-assets.mjs`, and the tests in `Cloud/`
before deployment. Model assets remain served by the Mac's authenticated gateway.

Use `Tools/setup-companion.py --help` and read `Cloud/IMPLEMENTATION.md` before
provisioning. The Mac must remain awake and reachable for hosted Gemma calls.
HTTPS is required for iPhone browser microphone access. Local HTTP alone is not
a microphone solution; never tell her to bypass a certificate warning.
Browser-local TTS/VAD and offline Gemma fallback remain under development; do not
promise them as a replacement for the connected Mac yet.
