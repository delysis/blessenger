#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
variant="${1:-patched}"
case "$variant" in baseline|patched) ;; *) echo "Usage: $0 [baseline|patched] [work-directory]" >&2; exit 2 ;; esac
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'An Apple Silicon Mac is required.' >&2; exit 2; }
command -v bazel >/dev/null || { echo 'Install Bazelisk (the pinned project selects Bazel 7.6.1).' >&2; exit 2; }
xcrun --find clang >/dev/null
work="${2:-$root/.build/native/$variant}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
lm_commit=5f25078c9439e176615af5ba42636ed904fca847
litert_commit=9b8c7f77e7a29e6073e614a05e1e38be7b761229
target=//swift:CLiteRTLM_mac

manifest="$work/requested-inputs.txt"
{
  echo "$variant $lm_commit $litert_commit $target"
  shasum -a 256 "$root/RuntimeBuildFixes/normalize.py"
  if [[ "$variant" == patched ]]; then
    for repository in LiteRT LiteRT-LM; do
      while IFS= read -r patch; do
        [[ -n "$patch" ]] || continue
        shasum -a 256 "$root/RuntimePatches/$repository/$patch"
      done < "$root/RuntimePatches/$repository/series"
    done
  fi
} > "$manifest"

checkout() {
  local name="$1" remote="$2" revision="$3"
  [[ ! -e "$work/$name" ]] || { echo "Refusing to replace existing checkout: $work/$name" >&2; exit 2; }
  git init -q "$work/$name"
  git -C "$work/$name" remote add origin "$remote"
  git -C "$work/$name" fetch --depth 1 origin "$revision"
  git -C "$work/$name" checkout --detach -q FETCH_HEAD
}

if [[ -f "$work/applied-inputs.txt" ]]; then
  cmp "$manifest" "$work/applied-inputs.txt" || { echo 'Build inputs changed; choose a new work directory.' >&2; exit 2; }
  for repository in LiteRT LiteRT-LM; do
    expected_revision="$litert_commit"
    [[ "$repository" != LiteRT-LM ]] || expected_revision="$lm_commit"
    [[ "$(git -C "$work/$repository" rev-parse HEAD)" == "$expected_revision" ]] || {
      echo "The $repository base revision changed; choose a new work directory." >&2; exit 2;
    }
    git -C "$work/$repository" diff --exit-code
    [[ -z "$(git -C "$work/$repository" ls-files --others --exclude-standard)" ]] || {
      echo "The $repository checkout contains untracked sources; choose a new work directory." >&2; exit 2;
    }
    actual="$(git -C "$work/$repository" diff --cached --binary | shasum -a 256 | cut -d ' ' -f 1)"
    [[ "$actual" == "$(cat "$work/$repository.staged.sha256")" ]] || {
      echo "The prepared $repository patch set changed; choose a new work directory." >&2; exit 2;
    }
  done
else
  checkout LiteRT-LM https://github.com/google-ai-edge/LiteRT-LM.git "$lm_commit"
  checkout LiteRT https://github.com/google-ai-edge/LiteRT.git "$litert_commit"
  if [[ "$variant" == patched ]]; then
    for repository in LiteRT LiteRT-LM; do
      while IFS= read -r patch; do
        [[ -n "$patch" ]] || continue
        git -C "$work/$repository" apply --check "$root/RuntimePatches/$repository/$patch"
        git -C "$work/$repository" apply "$root/RuntimePatches/$repository/$patch"
      done < "$root/RuntimePatches/$repository/series"
    done
  fi
  python3 "$root/RuntimeBuildFixes/normalize.py" "$work"
  # --override_repository bypasses WORKSPACE's http_archive patch_cmds. Apply
  # the same repository-label fix to BOTH variants, with BSD sed syntax.
  for file in "$work/LiteRT"/third_party/*/*; do
    [[ -f "$file" ]] || continue
    sed -i '' -e 's|"@//third_party/|"@litert//third_party/|g' "$file"
  done
  for repository in LiteRT LiteRT-LM; do
    git -C "$work/$repository" add --all
    git -C "$work/$repository" diff --cached --binary | shasum -a 256 | cut -d ' ' -f 1 > "$work/$repository.staged.sha256"
  done
  cp "$manifest" "$work/applied-inputs.txt"
fi

cd "$work/LiteRT-LM"
bazel build --config=macos --config=macos_arm64 -c opt \
  --override_repository="litert=$work/LiteRT" "$target"
bazel build --config=macos --config=macos_arm64 -c opt \
  --override_repository="litert=$work/LiteRT" \
  @litert//litert/runtime/accelerators/gpu:ml_drift_metal_accelerator_dylib
destination="$work/product"
mkdir -p "$destination"
unzip -o -q bazel-bin/swift/CLiteRTLM_mac.zip -d "$destination"
library="$destination/CLiteRTLM_mac/libCLiteRTLM_mac.dylib"
[[ -f "$library" ]] || { echo 'The expected runtime dylib was not produced.' >&2; exit 1; }
library_sha="$(shasum -a 256 "$library" | cut -d ' ' -f 1)"
receipt="$destination/runtime-receipt.tsv"
{
  printf 'variant\t%s\n' "$variant"
  printf 'litert_lm_commit\t%s\n' "$lm_commit"
  printf 'litert_commit\t%s\n' "$litert_commit"
  printf 'compiler\t%s\n' "$(xcrun clang --version | head -1)"
  printf 'sdk_version\t%s\n' "$(xcrun --sdk macosx --show-sdk-version)"
  printf 'xcode_version\t%s\n' "$(xcodebuild -version | tr '\n' ' ')"
  printf 'build_flags\t%s\n' '--config=macos --config=macos_arm64 -c opt --override_repository=litert=$LITERT_CHECKOUT; WORKSPACE third_party label fix'
  printf 'target\t%s\n' "$target"
  printf 'dylib_sha256\t%s\n' "$library_sha"
  printf 'patch_manifest_sha256\t%s\n' "$(shasum -a 256 "$manifest" | cut -d ' ' -f 1)"
} > "$receipt"

if [[ "$variant" == patched ]]; then
  # Fail before linking the app if an unpatched binary slips into the build.
  for symbol in litert_lm_conversation_save_cache litert_lm_conversation_load_cache litert_lm_conversation_get_history litert_lm_conversation_count_tokens litert_lm_conversation_capture_cache_bounded; do
    nm -gU "$library" | awk -v expected="_$symbol" '$NF == expected { found = 1 } END { exit !found }'
  done
  for header in engine.h conversation.h api_export.h error_reporter.h; do
    cmp "$work/LiteRT-LM/c/$header" "$root/Reference/LiteRT-LM/c/$header"
  done
  mkdir -p "$root/Vendor"
  cp -f "$library" "$root/Vendor/libCLiteRTLM_mac.dylib"
  cp "$receipt" "$root/Vendor/runtime-receipt.tsv"
  printf '{"sha256":"%s"}\n' "$library_sha" > "$root/Sources/CallGemma/Resources/runtime.json"
fi
bash "$root/Tools/package-runtime.sh" "$variant" "$work"
printf 'Runtime: %s\nReceipt: %s\n' "$library" "$receipt"
