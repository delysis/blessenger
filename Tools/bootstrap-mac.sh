#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Requires an Apple Silicon Mac.' >&2; exit 2; }
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]] || { echo 'Requires macOS 26 or later.' >&2; exit 2; }
xcodebuild -version
for command in python3 git cargo rustup bazel; do
  command -v "$command" >/dev/null || { echo "Missing prerequisite: $command (see Documentation/BUILD-AND-INSTALL.md)" >&2; exit 2; }
done
python3 Tools/fetch-speech-assets.py
bash Tools/build-runtime.sh patched
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim wasm32-unknown-unknown
bash Tools/build-earshot.sh
cargo build --manifest-path Browser/Earshot/Cargo.toml --locked --release --target wasm32-unknown-unknown
bash Tools/build-app.sh
