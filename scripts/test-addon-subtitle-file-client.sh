#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
test -d app/build
run_dir=$(mktemp -d "$PWD/app/build/addon-subtitle-file.XXXXXX")
trap 'rm -rf "$run_dir"' EXIT
# Compile the exact production budget declaration without the renderer's UIKit/AppKit surface.
sed -n '/^enum SubtitleFileBudget {/,/^}/p' app/Sources/Player/SubtitleCueRenderer.swift > "$run_dir/SubtitleFileBudget.swift"
test -s "$run_dir/SubtitleFileBudget.swift"
nice -n 15 xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -j 1 -num-threads 1 \
  app/SourcesShared/AddonPairingProtocol.swift \
  app/SourcesShared/SubtitleRequestMetadata.swift \
  app/SourcesShared/AddonURLGuard.swift \
  app/SourcesShared/SubtitleAddons.swift \
  app/Tests/AddonSubtitleFileClientFixtures.swift \
  "$run_dir/SubtitleFileBudget.swift" \
  app/SourcesShared/AddonSubtitleFileClient.swift \
  app/Tests/AddonSubtitleFileClientTests.swift \
  -o "$run_dir/subtitle-addon-file-tests"
"$run_dir/subtitle-addon-file-tests"
