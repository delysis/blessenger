#!/usr/bin/env bash
# Harness checks only. This never loads a model or substitutes for native gates.
set -euo pipefail
headers= out=
while (($#)); do
  (($# >= 2)) || { echo "Every option requires a value" >&2; exit 2; }
  case "$1" in
    --headers) headers=$2 ;; --out) out=$2 ;;
    *) echo "Usage: portable-checks.sh --headers /actual/LiteRT-LM --out /new/results" >&2; exit 2 ;;
  esac
  shift 2
done
[[ -n $headers && -n $out && ! -e $out ]] || { echo "Use actual headers and a new output directory" >&2; exit 2; }
here=$(cd -- "$(dirname -- "$0")" && pwd)
mkdir -p -- "$out"
bash "$here/build.sh" --headers "$headers" --out "$out/bin" > "$out/build.log" 2>&1
cat "$out/build.log"
bash -n "$here/build.sh" "$here/run.sh" "$here/kernels.sh" "$here/portable-checks.sh"
analyze="$out/bin/analyze"
"$analyze" --check-config yes --max-save-ms 1 --max-load-ms 1
reject() {
  local name=$1
  shift
  local status=0
  "$analyze" --check-config yes "$@" > "$out/$name.log" 2>&1 || status=$?
  [[ $status == 1 ]] || { echo "Expected parser rejection for $name, got $status" >&2; exit 1; }
  printf 'PASS: rejected %s\n' "$name"
}
reject too-few-blocks --min-blocks 11 --max-save-ms 1 --max-load-ms 1
reject too-few-resamples --bootstrap 9999 --max-save-ms 1 --max-load-ms 1
reject nonfinite-confidence --confidence nan --max-save-ms 1 --max-load-ms 1
reject trailing-confidence --confidence 0.99junk --max-save-ms 1 --max-load-ms 1
reject zero-save-budget --max-save-ms 0 --max-load-ms 1
reject negative-memory-margin --max-retained-bytes -1 --max-save-ms 1 --max-load-ms 1
reject unknown-option --not-a-gate 1 --max-save-ms 1 --max-load-ms 1
if [[ $(uname -s) != Darwin ]]; then
  for script in run kernels; do
    status=0
    bash "$here/$script.sh" > "$out/non-mac-$script.log" 2>&1 || status=$?
    [[ $status == 2 ]] || { echo "$script did not reject the non-Mac host" >&2; exit 1; }
    printf 'PASS: %s refuses non-Mac qualification\n' "$script"
  done
fi
printf 'PASS: portable harness build and admission checks. No native inference, Metal, or persistence was run.\n'
