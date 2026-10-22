#!/bin/bash
# Read-only build gate: never change dependency sources during compilation.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
checkouts="${1:-${BUILD_DIR:?BUILD_DIR or checkout directory required}/../../SourcePackages/checkouts}"
package="$checkouts/FluidAudio"
expected="$(cat "$root/DependencyPatches/FluidAudio/revision")"
[[ "$(git -C "$package" rev-parse HEAD)" == "$expected" ]] || {
  echo 'error: FluidAudio revision differs from the qualified dependency.' >&2
  exit 1
}
for patch in "$root"/DependencyPatches/FluidAudio/*.patch; do
  if ! git -C "$package" apply --reverse --check "$patch" 2>/dev/null; then
    echo "error: Required FluidAudio patch is missing: $(basename "$patch"). Run Tools/apply-dependency-patches.sh before building." >&2
    exit 1
  fi
done
