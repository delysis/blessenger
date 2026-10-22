#!/usr/bin/env bash
# Native device qualification. Every driver invocation starts a new process.
set -euo pipefail
baseline= patched= baseline_receipt= patched_receipt= model= headers= out=
max_save= max_load= audio= next_audio= capacity=4096 ring=1152 verify=4 blocks=12 warmups=1
mtp_modes=both
margin=0 retained=0 bootstrap=20000 confidence=0.99 keep_caches=0
while (($#)); do
  (($# >= 2)) || { echo "Every option requires a value" >&2; exit 2; }
  case "$1" in
    --baseline) baseline=$2 ;; --patched) patched=$2 ;;
    --baseline-receipt) baseline_receipt=$2 ;; --patched-receipt) patched_receipt=$2 ;;
    --model) model=$2 ;; --headers) headers=$2 ;; --out) out=$2 ;;
    --max-save-ms) max_save=$2 ;; --max-load-ms) max_load=$2 ;;
    --audio|--audio-input) audio=$2 ;; --next-audio) next_audio=$2 ;;
    --mtp-modes) mtp_modes=$2 ;;
    --capacity) capacity=$2 ;; --ring-size) ring=$2 ;;
    --verify-steps) verify=$2 ;; --blocks) blocks=$2 ;; --warmup-blocks) warmups=$2 ;;
    --max-regression-percent) margin=$2 ;; --max-retained-bytes) retained=$2 ;;
    --bootstrap) bootstrap=$2 ;; --confidence) confidence=$2 ;; --keep-caches) keep_caches=$2 ;;
    *) echo "Unknown option: $1 (see README.md)" >&2; exit 2 ;;
  esac
  shift 2
done
[[ $(uname -s) == Darwin ]] || { echo "This gate requires a real Mac; Linux builds only test harness code." >&2; exit 2; }
for number in "$capacity" "$ring" "$verify" "$blocks" "$warmups" "$bootstrap" "$keep_caches"; do
  [[ $number =~ ^[0-9]+$ ]] || { echo "Invalid integer: $number" >&2; exit 2; }
done
(( capacity >= 4 && capacity <= 131071 && ring >= 64 && verify >= 1 && verify <= 64 &&
   blocks >= 12 && warmups >= 1 && bootstrap >= 10000 && keep_caches <= 1 )) || {
  echo "Invalid bounds; qualifying runs require >=12 measured and >=1 warmup ABBA blocks." >&2; exit 2;
}
[[ $max_save =~ ^[0-9]+([.][0-9]+)?$ && $max_load =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "Declare positive --max-save-ms and --max-load-ms budgets before collecting data." >&2; exit 2;
}
awk -v save="$max_save" -v load="$max_load" 'BEGIN { exit !(save>0 && load>0) }' || exit 2
for path in "$baseline" "$patched" "$baseline_receipt" "$patched_receipt" "$model" "$headers" "$out"; do
  [[ $path == /* && $path != *$'\t'* && $path != *$'\n'* ]] || {
    echo "All paths must be absolute and contain no tabs/newlines." >&2; exit 2;
  }
done
for path in "$baseline" "$patched" "$baseline_receipt" "$patched_receipt" "$model"; do
  [[ -f $path ]] || { echo "Missing input: $path" >&2; exit 2; }
done
[[ ! -e $out ]] || { echo "Results directory must be new: $out" >&2; exit 2; }
case "$mtp_modes" in
  both) mtps=(0 1) ;;
  off) mtps=(0) ;;
  *) echo '--mtp-modes must be both or off' >&2; exit 2 ;;
esac
effective=$((capacity - capacity % 4))
here=$(cd -- "$(dirname -- "$0")" && pwd)
mkdir -p -- "$out/provenance" "$out/fixtures" "$out/caches" "$out/trials" "$out/warmups" "$out/functional"
sha() { local line; line=$(shasum -a 256 -- "$1"); printf '%s' "${line%% *}"; }
field() { awk -F '\t' -v key="$2" '$1==key { if(found++) exit 2; value=$2 } END { if(found!=1) exit 2; print value }' "$1"; }
model_hash=$(sha "$model")
case "$model_hash" in
  58fd31b778ca2c21c80d634fb34fc5a89d11d563a38dfd3cbf1b40dbf252a8b6)
    layout=ring
    [[ $ring == 1152 && $verify == 4 ]] || { echo "The pinned 12B metadata requires R1152/V4." >&2; exit 2; }
    (( 2*ring + 256 < effective )) || { echo "12B full qualification needs capacity for two ring wraps and output." >&2; exit 2; }
    long_prefix=$((ring-1))
    functional_prefixes=($((ring-verify-2)) $((ring-1)) "$ring" $((ring+1)) $((2*ring-1)))
    ;;
  0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0)
    layout=position
    [[ $verify == 4 ]] || { echo "The pinned E4B verify signature requires V4." >&2; exit 2; }
    (( effective >= 2048 && effective <= 32000 )) || { echo "E4B capacity must be in [2048,32000], below its 32003 magic dimension." >&2; exit 2; }
    ring=0
    long_prefix=$((effective-513))
    functional_prefixes=(122 127 128 1023 "$long_prefix")
    ;;
  *) echo "Model SHA256 is not one of the two inspected artifacts; establish its metadata before extending this gate." >&2; exit 2 ;;
esac
baseline_hash=$(sha "$baseline")
patched_hash=$(sha "$patched")
[[ $baseline_hash != "$patched_hash" ]] || { echo "Baseline and patched binary hashes are identical." >&2; exit 2; }
for variant in baseline patched; do
  if [[ $variant == baseline ]]; then receipt=$baseline_receipt; binary_hash=$baseline_hash;
  else receipt=$patched_receipt; binary_hash=$patched_hash; fi
  [[ $(field "$receipt" variant) == "$variant" && $(field "$receipt" dylib_sha256) == "$binary_hash" &&
     $(field "$receipt" litert_lm_commit) == 5f25078c9439e176615af5ba42636ed904fca847 &&
     $(field "$receipt" litert_commit) == 9b8c7f77e7a29e6073e614a05e1e38be7b761229 ]] || {
    echo "Runtime receipt does not match selected pinned binary: $variant" >&2; exit 2;
  }
  if [[ $variant == baseline ]]; then library=$baseline; else library=$patched; fi
  directory=$(dirname "$library")
  (cd "$directory" && shasum -a 256 -c runtime-files.sha256) > "$out/provenance/$variant-components-check.txt"
  cp "$directory/runtime-files.sha256" "$out/provenance/$variant-components.sha256"
  cp -- "$receipt" "$out/provenance/$variant-runtime.tsv"
done
for key in compiler sdk_version xcode_version build_flags target; do
  [[ $(field "$baseline_receipt" "$key") == "$(field "$patched_receipt" "$key")" ]] || {
    echo "Baseline/patched build configuration differs: $key" >&2; exit 2;
  }
done
{
  printf 'format\tCallGemma-qualification-1\nmodel_sha256\t%s\nbaseline_sha256\t%s\npatched_sha256\t%s\n' "$model_hash" "$baseline_hash" "$patched_hash"
  printf 'model_path\t%s\ncapacity_requested\t%s\ncapacity_effective\t%s\nring_size\t%s\nverify_steps\t%s\n' "$model" "$capacity" "$effective" "$ring" "$verify"
  printf 'mtp_modes\t%s\n' "$mtp_modes"
  printf 'cache_layout\t%s\nlong_prefix\t%s\n' "$layout" "$long_prefix"
  printf 'blocks\t%s\nwarmup_blocks\t%s\nbootstrap\t%s\nconfidence\t%s\n' "$blocks" "$warmups" "$bootstrap" "$confidence"
  printf 'max_regression_percent\t%s\nmax_retained_bytes\t%s\nmax_save_ms\t%s\nmax_load_ms\t%s\n' "$margin" "$retained" "$max_save" "$max_load"
  printf 'created_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$out/provenance/predeclared.tsv"
sw_vers > "$out/provenance/macos.txt"
uname -a > "$out/provenance/kernel.txt"
sysctl hw.memsize hw.ncpu hw.machine > "$out/provenance/hardware.txt"
pmset -g therm > "$out/provenance/thermal-before.txt"
xcrun --show-sdk-version > "$out/provenance/current-sdk.txt"
bash "$here/build.sh" --headers "$headers" --out "$out/bin" > "$out/provenance/harness-build.log" 2>&1
driver="$out/bin/driver"
analyze="$out/bin/analyze"
"$analyze" --check-config yes --min-blocks "$blocks" --bootstrap "$bootstrap" --confidence "$confidence" \
  --max-regression-percent "$margin" --max-retained-bytes "$retained" --max-save-ms "$max_save" --max-load-ms "$max_load"
printf 'group\tblock\tleg\tdirectory\n' > "$out/trials.tsv"
printf 'group\tblock\tleg\tdirectory\n' > "$out/warmups.tsv"
printf 'case\tresult\n' > "$out/functional.tsv"
printf 'file\tsha256\tbytes\n' > "$out/cache-receipts.tsv"
printf '\nWhat was the gate code? Answer it, then count from one:' > "$out/fixtures/next.txt"
printf '7319. One, two, three, four, five, six, seven, eight, nine, ten.' > "$out/fixtures/score.txt"
cat > "$out/fixtures/message.json" <<'EOF'
{"role":"user","content":[{"type":"text","text":"Remember that the gate code is 7319. Answer only: remembered."}]}
EOF
cat > "$out/fixtures/next.json" <<'EOF'
{"role":"user","content":[{"type":"text","text":"What is the gate code? Answer only the four digits."}]}
EOF

# macOS's own synthesizer makes a reproducible local audio-input fixture. This
# exercises the model's audio encoder; it does not substitute transcription.
if [[ -z $audio ]]; then
  say -o "$out/fixtures/spoken.aiff" 'Remember that the gate code is seven three one nine. Answer only: remembered.'
  afconvert -f WAVE -d LEI16@16000 -c 1 "$out/fixtures/spoken.aiff" "$out/fixtures/spoken.wav"
  audio="$out/fixtures/spoken.wav"
fi
[[ $audio == /* && -f $audio && $audio != *$'\n'* ]] || { echo "Audio fixture must be an absolute file path" >&2; exit 2; }
if [[ -z $next_audio ]]; then
  say -o "$out/fixtures/question.aiff" 'What is the gate code? Answer only the four digits.'
  afconvert -f WAVE -d LEI16@16000 -c 1 "$out/fixtures/question.aiff" "$out/fixtures/question.wav"
  next_audio="$out/fixtures/question.wav"
fi
[[ $next_audio == /* && -f $next_audio && $next_audio != *$'\n'* ]] || { echo "Next audio fixture must be an absolute file path" >&2; exit 2; }
# JSON encode the path with the system Swift interpreter, without shell eval.
for turn in first next; do
  if [[ $turn == first ]]; then path=$audio; destination="$out/fixtures/audio-message.json";
  else path=$next_audio; destination="$out/fixtures/audio-next.json"; fi
  xcrun swift - "$path" > "$destination" <<'SWIFT'
import Foundation
let message: [String: Any] = ["role": "user", "content": [["type": "audio", "path": CommandLine.arguments[1]]]]
let json = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
FileHandle.standardOutput.write(json)
SWIFT
done
printf 'first_path\t%s\nfirst_sha256\t%s\nnext_path\t%s\nnext_sha256\t%s\n' \
  "$audio" "$(sha "$audio")" "$next_audio" "$(sha "$next_audio")" > "$out/provenance/audio.tsv"

run_one() {
  local library=$1 directory=$2 mode=$3 prefix=$4 mtp=$5 cache=$6
  shift 6
  local key="CallGemma-qualification-1:$model_hash:$patched_hash:capacity=$effective:mtp=$mtp:greedy=7319:max_output=64"
  local command=("$driver" --library "$library" --model "$model" --out "$directory" --mode "$mode"
    --capacity "$capacity" --mtp "$mtp" --decode-tokens 64 --prefix-tokens "$prefix"
    --next "$out/fixtures/next.txt" --cache "$cache" --key "$key")
  printf 'Running %s\n' "${directory#"$out/"}"
  printf '%q ' "${command[@]}" "$@" > "$directory.command.txt"
  printf '\n' >> "$directory.command.txt"
  "${command[@]}" "$@" > "$directory.stdout.txt" 2> "$directory.stderr.txt"
}
compare() {
  "$analyze" --compare-a "$1" --compare-b "$2" --scoring "${3:-0}" >> "$out/functional.log" 2>&1
  printf '%s\tPASS\n' "${2#"$out/"}" >> "$out/functional.tsv"
}
cache_receipt() { printf '%s\t%s\t%s\n' "$1" "$(sha "$1")" "$(stat -f '%z' "$1")" >> "$out/cache-receipts.tsv"; }
remove_cache() { if (( keep_caches == 0 )); then rm -- "$1"; fi; }

# Use the inspected artifact's geometry: local ring boundaries for 12B,
# prefill-block/near-capacity positions for full-position INT8 E4B.
for mtp in "${mtps[@]}"; do
  for prefix in "${functional_prefixes[@]}"; do
    case_dir="$out/functional/mtp$mtp-prefix$prefix"
    mkdir -p -- "$case_dir"
    cache="$out/caches/functional-$mtp-$prefix.cache"
    run_one "$baseline" "$case_dir/baseline" reference "$prefix" "$mtp" "$cache"
    run_one "$patched" "$case_dir/patched" reference "$prefix" "$mtp" "$cache"
    run_one "$patched" "$case_dir/saved" save "$prefix" "$mtp" "$cache"
    run_one "$patched" "$case_dir/restored" restore "$prefix" "$mtp" "$cache"
    compare "$case_dir/baseline" "$case_dir/patched"
    compare "$case_dir/patched" "$case_dir/saved"
    compare "$case_dir/saved" "$case_dir/restored"
    for variant in baseline patched restored; do
      if [[ $variant == baseline ]]; then library=$baseline; mode=reference;
      elif [[ $variant == patched ]]; then library=$patched; mode=reference;
      else library=$patched; mode=restore; fi
      run_one "$library" "$case_dir/score-$variant" "$mode" "$prefix" "$mtp" "$cache" --score "$out/fixtures/score.txt"
    done
    compare "$case_dir/score-baseline" "$case_dir/score-patched" 1
    compare "$case_dir/score-patched" "$case_dir/score-restored" 1
    cache_receipt "$cache"
    remove_cache "$cache"
  done

  case_dir="$out/functional/rejection-mtp$mtp"
  mkdir -p -- "$case_dir"
  cache="$out/caches/cancel-$mtp.cache"
  run_one "$patched" "$case_dir/reference" reference 512 "$mtp" "$cache"
  run_one "$patched" "$case_dir/cancel" cancel 512 "$mtp" "$cache"
  # Cancellation discards its mutated session. A new process can still restore
  # the prior completed-turn checkpoint; no cancelled state is ever serialized.
  run_one "$patched" "$case_dir/restored-after-cancel" restore 512 "$mtp" "$cache"
  compare "$case_dir/reference" "$case_dir/restored-after-cancel"
  run_one "$patched" "$case_dir/fresh" fresh 512 "$mtp" "$cache"
  "$analyze" --corrupt-copy "$cache" --out "$cache.corrupt"
  run_one "$patched" "$case_dir/corrupt" reject-corrupt 512 "$mtp" "$cache.corrupt"
  compare "$case_dir/fresh" "$case_dir/corrupt"
  # Keep engine settings identical and change only the compatibility key.
  key="CallGemma-qualification-1:$model_hash:$patched_hash:capacity=$effective:mtp=$mtp:greedy=7319:max_output=64:wrong"
  "$driver" --library "$patched" --model "$model" --out "$case_dir/wrong-key" --mode reject-key \
    --capacity "$capacity" --mtp "$mtp" --decode-tokens 64 --prefix-tokens 512 \
    --next "$out/fixtures/next.txt" --cache "$cache" --key "$key" \
    > "$case_dir/wrong-key.stdout.txt" 2> "$case_dir/wrong-key.stderr.txt"
  compare "$case_dir/fresh" "$case_dir/wrong-key"
  cache_receipt "$cache"
  remove_cache "$cache"
  remove_cache "$cache.corrupt"

  for kind in text audio; do
    case_dir="$out/functional/conversation-$kind-mtp$mtp"
    mkdir -p -- "$case_dir"
    message="$out/fixtures/message.json"
    next_message="$out/fixtures/next.json"
    if [[ $kind == audio ]]; then message="$out/fixtures/audio-message.json"; next_message="$out/fixtures/audio-next.json"; fi
    cache="$out/caches/conversation-$kind-$mtp.cache"
    common=(--message "$message" --next-message "$next_message")
    run_one "$baseline" "$case_dir/baseline" conversation-reference 512 "$mtp" "$cache" "${common[@]}"
    run_one "$patched" "$case_dir/patched" conversation-reference 512 "$mtp" "$cache" "${common[@]}"
    run_one "$patched" "$case_dir/saved" conversation-save 512 "$mtp" "$cache" "${common[@]}"
    run_one "$patched" "$case_dir/restored" conversation-restore 512 "$mtp" "$cache" "${common[@]}" --history "$case_dir/saved/history.json"
    compare "$case_dir/baseline" "$case_dir/patched"
    compare "$case_dir/patched" "$case_dir/saved"
    compare "$case_dir/saved" "$case_dir/restored"
    # Whitespace keeps the JSON valid while changing the exact committed bytes.
    cp -- "$case_dir/saved/history.json" "$case_dir/changed-history.json"
    printf '\n' >> "$case_dir/changed-history.json"
    run_one "$patched" "$case_dir/rejected-history" conversation-reject-history 512 "$mtp" "$cache" "${common[@]}" --history "$case_dir/changed-history.json"
    run_one "$patched" "$case_dir/fresh" conversation-fresh 512 "$mtp" "$cache" "${common[@]}"
    compare "$case_dir/fresh" "$case_dir/rejected-history"
    printf '{"broken":' > "$case_dir/malformed.json"
    printf '[{"role":"assistant","content":"orphan"}]' > "$case_dir/orphan.json"
    for invalid in malformed orphan; do
      run_one "$patched" "$case_dir/rejected-$invalid" conversation-reject-malformed 512 "$mtp" "$cache" \
        "${common[@]}" --history "$case_dir/$invalid.json"
      compare "$case_dir/fresh" "$case_dir/rejected-$invalid"
    done
    run_one "$patched" "$case_dir/populated" conversation-reject-populated 512 "$mtp" "$cache" \
      "${common[@]}" --history "$case_dir/saved/history.json"
    compare "$case_dir/patched" "$case_dir/populated"
    cache_receipt "$cache"
    remove_cache "$cache"
  done
done

# The same target should guide greedy acceptance. Different decode/verify batch
# shapes do not promise identical floating-point scores, so preserve separate
# exact text/count/score findings and require review of any difference.
cross_status=0
if [[ $mtp_modes == both ]]; then
for prefix in "${functional_prefixes[@]}"; do
  for scoring in 0 1; do
    variant=patched
    if (( scoring )); then variant=score-patched; fi
    "$analyze" --cross-mtp yes --scoring "$scoring" \
      --compare-a "$out/functional/mtp0-prefix$prefix/$variant" \
      --compare-b "$out/functional/mtp1-prefix$prefix/$variant" \
      --out "$out/functional/cross-mtp-prefix$prefix-score$scoring.tsv" \
      >> "$out/cross-mtp.log" 2>&1 || cross_status=$?
  done
done
fi
if (( cross_status )); then
  echo "Cross-MTP evidence requires review; see cross-mtp.log. No tolerance was widened." >&2
  exit "$cross_status"
fi

# Same effective context for all four user requests. This tests the driver;
# the separate native Swift unit tests exercise the app's actual ModelPolicy.
for requested in "$effective" $((effective+1)) $((effective+2)) $((effective+3)); do
  (( requested <= 131071 )) || continue
  directory="$out/functional/capacity-$requested"
  "$driver" --library "$patched" --model "$model" --out "$directory" --mode reference \
    --capacity "$requested" --mtp "${mtps[0]}" --decode-tokens 64 --prefix-tokens 512 --next "$out/fixtures/next.txt" \
    > "$directory.stdout.txt" 2> "$directory.stderr.txt"
  if [[ $requested == "$effective" ]]; then capacity_reference=$directory;
  else compare "$capacity_reference" "$directory"; fi
done

# A1 B1 B2 A2 controls monotonic warm-up/thermal drift. Do not remove outliers
# or pool different MTP/prefix settings. Warmup observations remain inspectable.
for mtp in "${mtps[@]}"; do
  for prefix in 512 "$long_prefix"; do
    cache="$out/caches/performance-$mtp-$prefix.cache"
    run_one "$patched" "$out/warmups/writer-$mtp-$prefix" save "$prefix" "$mtp" "$cache"
    cache_receipt "$cache"
    for comparison in baseline-vs-patched post-save post-restore; do
      group="$comparison-mtp$mtp-prefix$prefix"
      block=0
      while (( block < warmups + blocks )); do
        if (( block < warmups )); then root="$out/warmups"; manifest="$out/warmups.tsv"; index=$block;
        else root="$out/trials"; manifest="$out/trials.tsv"; index=$((block-warmups)); fi
        for leg in A1 B1 B2 A2; do
          library=$patched; mode=reference; trial_cache=$cache
          if [[ $leg == A* ]]; then
            if [[ $comparison == baseline-vs-patched ]]; then library=$baseline; fi
          else
            case "$comparison" in
              post-save) mode=save; trial_cache="$out/caches/transient.cache" ;;
              post-restore) mode=restore ;;
            esac
          fi
          directory="$root/$group-block$index-$leg"
          run_one "$library" "$directory" "$mode" "$prefix" "$mtp" "$trial_cache"
          printf '%s\t%s\t%s\t%s\n' "$group" "$index" "$leg" "$directory" >> "$manifest"
          if [[ $mode == save ]]; then
            cache_receipt "$trial_cache"
            # A subsequent trial reuses this owned temporary path; retaining
            # every multi-GB checkpoint is unnecessary for timing evidence.
            rm -- "$trial_cache"
          fi
        done
        block=$((block+1))
      done
    done
    remove_cache "$cache"
  done
done
pmset -g therm > "$out/provenance/thermal-after.txt"
[[ $(sha "$baseline") == "$baseline_hash" && $(sha "$patched") == "$patched_hash" && $(sha "$model") == "$model_hash" ]] || {
  echo "An input changed during qualification." >&2; exit 1;
}
status=0
"$analyze" --manifest "$out/trials.tsv" --out "$out/report.tsv" --min-blocks "$blocks" \
  --baseline-library "$baseline" --patched-library "$patched" --long-prefix "$long_prefix" --mtp-modes "$mtp_modes" \
  --bootstrap "$bootstrap" --confidence "$confidence" --max-regression-percent "$margin" \
  --max-retained-bytes "$retained" --max-save-ms "$max_save" --max-load-ms "$max_load" \
  > "$out/analysis.log" 2>&1 || status=$?
cat "$out/analysis.log"
printf 'functional\tPASS\ntiming_memory_exit_status\t%s\nmetal_xctest\tSEPARATE_REQUIRED_GATE\n' "$status" > "$out/result.tsv"
exit "$status"
