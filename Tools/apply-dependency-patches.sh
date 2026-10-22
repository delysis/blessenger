#!/bin/bash
# Apply only the reviewed patch to the exact pinned SwiftPM dependency.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
checkouts="${1:-$root/.build/xcode/SourcePackages/checkouts}"
package="$checkouts/FluidAudio"
expected="$(cat "$root/DependencyPatches/FluidAudio/revision")"
[[ "$(git -C "$package" rev-parse HEAD)" == "$expected" ]] || {
  echo 'FluidAudio revision differs from the qualified dependency.' >&2; exit 1;
}
for patch in "$root"/DependencyPatches/FluidAudio/*.patch; do
  if git -C "$package" apply --reverse --check "$patch" 2>/dev/null; then continue; fi
  git -C "$package" apply --check "$patch"
  while IFS= read -r path; do
    chmod u+w "$package/$path"
  done < <(sed -n 's|^+++ b/||p' "$patch")
  git -C "$package" apply "$patch"
done
