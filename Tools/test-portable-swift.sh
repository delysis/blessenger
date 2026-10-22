#!/usr/bin/env bash
set -euo pipefail

# Run the platform-independent production code and its Swift Testing suites.
# This does not compile or qualify the AppKit, audio-device, or LiteRT adapters.
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [new-result-directory]" >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
swift_bin=${CALL_GEMMA_SWIFT:-swift}
if [[ $# -eq 1 ]]; then
  mkdir "$1"
  result=$(cd "$1" && pwd)
else
  result=$(mktemp -d "${TMPDIR:-/tmp}/CallGemma-Swift.XXXXXX")
fi
package="$result/package"
mkdir -p "$package/Sources/CallGemma" "$package/Tests/CallGemmaTests"

"$swift_bin" --version | tee "$result/toolchain.txt"
cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let checks: [SwiftSetting] = [.unsafeFlags([
    "-strict-concurrency=complete", "-warnings-as-errors", "-enable-actor-data-race-checks",
])]
let package = Package(
    name: "CallGemmaPortableChecks",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CallGemma", swiftSettings: checks),
        .testTarget(name: "CallGemmaTests", dependencies: ["CallGemma"], swiftSettings: checks),
    ]
)
SWIFT

sources=(
  Audio/AudioTypes.swift
  Audio/SentenceBuffer.swift
  Audio/UtteranceBuffer.swift
  Audio/SpeechEndpoint.swift
  Audio/SpeculativeEndpoint.swift
  Audio/PlaybackLedger.swift
  Audio/ForcedTextAlignment.swift
  Models/ModelCatalog.swift
  Models/ModelPolicy.swift
  Runtime/InputData.swift
  Runtime/ConversationHistory.swift
)
tests=(AudioPolicyTests.swift ModelPolicyTests.swift RuntimeInputTests.swift SpeechEndpointTests.swift PlaybackLedgerTests.swift ForcedTextAlignmentTests.swift ConversationHistoryTests.swift)
: > "$result/SOURCE_SHA256SUMS"
for file in "${sources[@]}"; do
  original="$root/Sources/CallGemma/$file"
  copy="$package/Sources/CallGemma/$(basename "$file")"
  cp "$original" "$copy"
  cmp "$original" "$copy"
  shasum -a 256 "$original" >> "$result/SOURCE_SHA256SUMS"
done
for file in "${tests[@]}"; do
  original="$root/Tests/CallGemmaTests/$file"
  copy="$package/Tests/CallGemmaTests/$file"
  cp "$original" "$copy"
  cmp "$original" "$copy"
  shasum -a 256 "$original" >> "$result/SOURCE_SHA256SUMS"
done

# Parse every app/test source too, without pretending unavailable Apple modules
# were typechecked. The test package above uses unchanged files and no API mocks.
while IFS= read -r -d '' file; do
  "$swift_bin" -frontend -parse -swift-version 6 "$file"
done < <(find "$root/Sources" "$root/Tests" -name '*.swift' -print0)
printf '%s\n' 'PASS: all app and test sources parsed in Swift 6 mode.' | tee "$result/parse.txt"

"$swift_bin" test --package-path "$package" --use-integrated-swift-driver -j 2 \
  --cache-path "$result/cache" --config-path "$result/config" --security-path "$result/security" \
  --disable-xctest --xunit-output "$result/tests.xml" \
  -Xswiftc -swift-version -Xswiftc 6 2>&1 | tee "$result/tests.txt"
printf 'Portable Swift results: %s\n' "$result"
