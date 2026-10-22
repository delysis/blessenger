#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
variant="${1:?baseline or patched}"
[[ "$variant" == baseline || "$variant" == patched ]] || exit 2
work="${2:-$root/.build/native/$variant}"
destination="$work/product/CLiteRTLM_mac"
cp -f "$work/LiteRT-LM/bazel-bin/external/litert/litert/runtime/accelerators/gpu/libLiteRtMetalAccelerator.dylib" "$destination/"
for name in libGemmaModelConstraintProvider.dylib libLiteRtTopKMetalSampler.dylib; do
  cp -f "$work/LiteRT-LM/prebuilt/macos_arm64/$name" "$destination/"
done
(
  cd "$destination"
  shasum -a 256 libCLiteRTLM_mac.dylib libGemmaModelConstraintProvider.dylib \
    libLiteRtMetalAccelerator.dylib libLiteRtTopKMetalSampler.dylib > runtime-files.sha256
)
identity="$(shasum -a 256 "$destination/runtime-files.sha256" | cut -d ' ' -f 1)"
printf 'runtime_bundle_sha256\t%s\n' "$identity" > "$work/product/bundle-receipt.tsv"
if [[ "$variant" == patched ]]; then
  mkdir -p "$root/Vendor"
  cp -f "$destination/"*.dylib "$destination/runtime-files.sha256" "$root/Vendor/"
  printf '{"sha256":"%s"}\n' "$identity" > "$root/Sources/CallGemma/Resources/runtime.json"
fi
