#!/usr/bin/env bash
# Runs real provider/KV-copy XCTest code in the pinned runtime build graph.
set -euo pipefail
lm= litert= out= variant=patched bazel=${BAZEL:-bazel}
while (($#)); do
  (($# >= 2)) || { echo "Every option requires a value" >&2; exit 2; }
  case "$1" in
    --lm) lm=$2 ;; --litert) litert=$2 ;; --out) out=$2 ;; --bazel) bazel=$2 ;;
    --variant) variant=$2 ;;
    *) echo "Usage: kernels.sh --lm /patched/LiteRT-LM --litert /patched/LiteRT --out /new/results [--bazel /path]" >&2; exit 2 ;;
  esac
  shift 2
done
[[ $(uname -s) == Darwin && $lm == /* && $litert == /* && $out == /* && ! -e $out ]] || {
  echo "A native Mac, absolute checkout paths, and a new output directory are required." >&2; exit 2;
}
[[ -f $lm/WORKSPACE && -f $litert/ml_drift_delegate/delegate/buffer_handler_metal_test.mm ]] || exit 2
[[ $variant == baseline || $variant == patched ]] || exit 2
[[ $(git -C "$lm" rev-parse HEAD) == 5f25078c9439e176615af5ba42636ed904fca847 &&
   $(git -C "$litert" rev-parse HEAD) == 9b8c7f77e7a29e6073e614a05e1e38be7b761229 ]] || {
  echo "Test checkouts must use the pinned base commits." >&2; exit 2;
}
work=$(cd -- "$(dirname -- "$lm")" && pwd)
[[ $lm == "$work/LiteRT-LM" && $litert == "$work/LiteRT" && -f $work/applied-inputs.txt ]] || {
  echo "Use the paired checkouts prepared by Tools/build-runtime.sh." >&2; exit 2;
}
IFS= read -r prepared < "$work/applied-inputs.txt"
[[ $prepared == "$variant 5f25078c9439e176615af5ba42636ed904fca847 9b8c7f77e7a29e6073e614a05e1e38be7b761229 //swift:CLiteRTLM_mac" ]] || {
  echo "Prepared runtime variant does not match the requested test variant." >&2; exit 2;
}
for repository in LiteRT-LM LiteRT; do
  git -C "$work/$repository" diff --exit-code
  actual=$(git -C "$work/$repository" diff --cached --binary | shasum -a 256 | cut -d ' ' -f 1)
  [[ $actual == "$(cat "$work/$repository.staged.sha256")" ]] || {
    echo "Prepared source changed: $repository" >&2; exit 2;
  }
done
if [[ $variant == baseline ]]; then
  git -C "$litert" diff --exit-code HEAD -- \
    ml_drift_delegate/delegate/buffer_handler_metal.mm \
    ml_drift_delegate/delegate/buffer_handler_metal.h \
    ml_drift_delegate/delegate/buffer_handler_metal_test.mm \
    ml_drift_delegate/delegate/kv_cache_metal.h
fi
here=$(cd -- "$(dirname -- "$0")" && pwd)
mkdir -p -- "$out"
cp -- "$work/applied-inputs.txt" "$work/LiteRT.staged.sha256" "$work/LiteRT-LM.staged.sha256" "$out/"
xcrun swift "$here/metal_probe.swift" > "$out/device.tsv" 2> "$out/device.stderr.txt"
flags=(--config=macos --config=macos_arm64 -c opt "--override_repository=litert=$litert")
target=@litert//ml_drift_delegate/delegate:buffer_handler_metal_test_macos
command=("$bazel" test "${flags[@]}" --nocache_test_results --test_output=all "$target")
printf '%q ' "${command[@]}" > "$out/command.sh"
printf '\n' >> "$out/command.sh"
shasum -a 256 -- "$litert/ml_drift_delegate/delegate/buffer_handler_metal.mm" \
  "$litert/ml_drift_delegate/delegate/buffer_handler_metal_test.mm" \
  "$litert/ml_drift_delegate/delegate/kv_cache_metal.h" > "$out/source-sha256.txt"
(
  cd -- "$lm"
  "${command[@]}"
) > "$out/bazel-xctest.log" 2>&1 || { cat "$out/bazel-xctest.log"; exit 1; }
names=(testCopyKvCacheMetalReduce testCopyKvCacheMetalBroadcast)
if [[ $variant == patched ]]; then
  names+=(testCheckpointAllocatedGemmaKvBuffers testWriteImportedSharedFp16WithoutDevice
    testCheckpointRejectsInvalidFp16Buffers testCheckpointAllocatedInt8KvBuffers testCheckpointRejectsInvalidInt8Buffers)
fi
for name in "${names[@]}"; do
  # XCTest emits a separate passed line for each executed method. A cached,
  # missing, skipped, or differently formatted result requires inspection.
  awk -v name="$name" 'index($0,name) && /passed/ { found=1 } END { exit !found }' \
    "$out/bazel-xctest.log" || { echo "No explicit XCTest pass found for $name" >&2; exit 1; }
done
checkpoint=PASS
if [[ $variant == baseline ]]; then checkpoint=NOT_PRESENT_IN_BASELINE; fi
printf 'variant\t%s\nnative_device\tPASS\ncheckpoint_physical_bytes\t%s\nkv_copy_kernels\tPASS\n' \
  "$variant" "$checkpoint" > "$out/result.tsv"
cat "$out/result.tsv"
