#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'An Apple Silicon Mac is required.' >&2; exit 2; }
[[ -f Vendor/libCLiteRTLM_mac.dylib ]] || { echo 'Run Tools/build-runtime.sh patched first.' >&2; exit 2; }
derived="${CALL_GEMMA_DERIVED_DATA:-$HOME/Library/Caches/CallGemma/DerivedData}"
result="${1:-$derived/AppTests.xcresult}"
[[ ! -e "$result" ]] || { echo 'Choose a new result path; existing evidence is never replaced.' >&2; exit 2; }
# The shared scheme suppresses model setup in the XCTest host. These tests
# exercise app policy and storage; Qualification runs the real models separately.
xcodebuild -resolvePackageDependencies -project CallGemma.xcodeproj -scheme CallGemma \
  -derivedDataPath "$derived"
bash Tools/apply-dependency-patches.sh "$derived/SourcePackages/checkouts"
xcodebuild -project CallGemma.xcodeproj -scheme CallGemma -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  -resultBundlePath "$result" test
