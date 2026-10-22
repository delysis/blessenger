#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'An Apple Silicon Mac is required.' >&2; exit 2; }
[[ -f Vendor/libCLiteRTLM_mac.dylib && -f Sources/CallGemma/Resources/runtime.json ]] || {
  echo 'Run Tools/build-runtime.sh patched first.' >&2; exit 2;
}
(cd Vendor && shasum -a 256 -c runtime-files.sha256)
actual="$(shasum -a 256 Vendor/runtime-files.sha256 | cut -d ' ' -f 1)"
expected="$(plutil -extract sha256 raw -o - Sources/CallGemma/Resources/runtime.json)"
[[ "$actual" == "$expected" ]] || { echo 'Runtime identity does not match its binary.' >&2; exit 2; }
derived="${CALL_GEMMA_DERIVED_DATA:-$HOME/Library/Caches/CallGemma/DerivedData}"
xcodebuild -resolvePackageDependencies -project CallGemma.xcodeproj -scheme CallGemma \
  -derivedDataPath "$derived"
bash Tools/apply-dependency-patches.sh "$derived/SourcePackages/checkouts"
xcodebuild -project CallGemma.xcodeproj -scheme CallGemma -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" build
app="${CALL_GEMMA_APP_DESTINATION:-$HOME/Applications/Blessenger.app}"
[[ ! -e "$app" ]] || { echo "Choose an unused CALL_GEMMA_APP_DESTINATION; $app already exists." >&2; exit 2; }
mkdir -p "$(dirname "$app")"
# Xcode handles SwiftPM dependency resources and embedded-library signing.
ditto "$derived/Build/Products/Release/Blessenger.app" "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\nRun: open "%s"\n' "$app" "$app"
