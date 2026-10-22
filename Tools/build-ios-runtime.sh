#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="${1:-$root/.build/native/patched}"
work="$(cd "$work" && pwd)"
[[ -f "$work/applied-inputs.txt" ]] || { echo 'Prepare the patched Mac runtime first.' >&2; exit 2; }
# Match the current patch series before reusing a prepared checkout.
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
{
  head -n 1 "$work/applied-inputs.txt"
  shasum -a 256 "$root/RuntimeBuildFixes/normalize.py"
  for repository in LiteRT LiteRT-LM; do
    while IFS= read -r patch; do
      [[ -n "$patch" ]] || continue
      shasum -a 256 "$root/RuntimePatches/$repository/$patch"
    done < "$root/RuntimePatches/$repository/series"
  done
} > "$manifest"
cmp -s "$manifest" "$work/applied-inputs.txt" || {
  echo 'Prepared sources do not match the current patch series. Build the current Mac runtime first.' >&2; exit 2;
}
for repository in LiteRT LiteRT-LM; do
  git -C "$work/$repository" diff --exit-code
  actual="$(git -C "$work/$repository" diff --cached --binary | shasum -a 256 | cut -d ' ' -f 1)"
  [[ "$actual" == "$(cat "$work/$repository.staged.sha256")" ]] || {
    echo "Prepared sources changed: $repository" >&2; exit 2;
  }
done
cd "$work/LiteRT-LM"
bazel build --config=ios_arm64 -c opt \
  --override_repository="litert=$work/LiteRT" //swift:CLiteRTLM
mkdir -p "$root/Vendor"
ditto -x -k bazel-bin/swift/CLiteRTLM.xcframework.zip "$root/Vendor"
# Bind both simulator and device slices to the same archived runtime identity.
sha="$(shasum -a 256 bazel-bin/swift/CLiteRTLM.xcframework.zip | cut -d ' ' -f 1)"
python3 "$root/Tools/package-ios-runtime.py" "$work/LiteRT-LM"
{
  printf 'archive_sha256\t%s\n' "$sha"
  printf 'source_manifest_sha256\t%s\n' "$(shasum -a 256 "$work/applied-inputs.txt" | cut -d ' ' -f 1)"
  printf 'flags\t%s\n' '--config=ios_arm64 -c opt //swift:CLiteRTLM'
  xcodebuild -version
} > "$root/Vendor/runtime-ios-receipt.tsv"
