#!/usr/bin/env bash
set -euo pipefail
headers=
out=
while (($#)); do
  (($# >= 2)) || { echo "Every option requires a value" >&2; exit 2; }
  case "$1" in
    --headers) headers=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) echo "Usage: build.sh --headers /path/to/LiteRT-LM --out /path/to/bin" >&2; exit 2 ;;
  esac
done
[[ -n "$headers" && -n "$out" && -f "$headers/c/engine.h" ]] || {
  echo "--headers must point to the actual pinned LiteRT-LM checkout" >&2; exit 2;
}
here=$(cd -- "$(dirname -- "$0")" && pwd)
reference="$here/../Reference/LiteRT-LM"
mkdir -p -- "$out"
compiler=${CXX:-c++}
flags=(-std=c++17 -O3 -DNDEBUG -Wall -Wextra -Werror -pthread)
includes=(-I "$here" -I "$headers" -I "$headers/c" -I "$reference" -I "$reference/c")
driver_command=("$compiler" "${flags[@]}" "${includes[@]}" -MMD -MF "$out/driver.d" "$here/driver.cc" -o "$out/driver")
if [[ $(uname -s) == Linux ]]; then driver_command+=(-ldl); fi
analyze_command=("$compiler" "${flags[@]}" -I "$here" -MMD -MF "$out/analyze.d" "$here/analyze.cc" -o "$out/analyze")
{
  printf '%q ' "${driver_command[@]}"; printf '\n'
  printf '%q ' "${analyze_command[@]}"; printf '\n'
} > "$out/compile-commands.sh"
"${driver_command[@]}"
"${analyze_command[@]}"
"$compiler" --version > "$out/compiler.txt"
{
  printf 'compiler\t%s\n' "$compiler"
  printf 'headers\t%s\n' "$headers"
  printf 'flags\t%s\n' "${flags[*]}"
  printf 'runtime_linkage\tdlopen of explicitly selected library; no bundled implementation\n'
} > "$out/build.tsv"
hash=(shasum -a 256)
if ! command -v shasum >/dev/null; then hash=(sha256sum); fi
{
  for source in "$here"/*.cc "$here"/*.h "$here"/*.sh "$here"/*.swift; do
    if [[ -f $source ]]; then "${hash[@]}" -- "$source"; fi
  done
  for name in engine.h conversation.h api_export.h error_reporter.h; do
    source="$headers/c/$name"
    if [[ ! -f $source ]]; then source="$reference/c/$name"; fi
    "${hash[@]}" -- "$source"
  done
} > "$out/source-sha256.txt"
"$out/analyze" --self-test yes
