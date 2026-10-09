#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
subtitle_test_dir=$(mktemp -d app/build/avplayer-subtitle-clock.XXXXXX)
if [[ $# -gt 0 ]]; then
  git show "$1:app/Sources/Player/AVPlayerEngine.swift" > "$subtitle_test_dir/engine.swift"
else
  cp app/Sources/Player/AVPlayerEngine.swift "$subtitle_test_dir/engine.swift"
fi
# Exact production call sites and renderer, with only the AV clock / visual overlay replaced by inert doubles.
{
  printf '%s\n' 'import Foundation' '@MainActor extension SubtitleClockFixtureEngine {'
  sed -n '/    private func setExternalSubtitleActive(/,/^    }/p' "$subtitle_test_dir/engine.swift"
  sed -n '/    func setSubDelay(/,/^    }/p' "$subtitle_test_dir/engine.swift"
  sed -n '/    private func updateSubtitleOverlay(/,/^    }/p' "$subtitle_test_dir/engine.swift"
  printf '%s\n' '}'
} | sed 's/private func /func /' > "$subtitle_test_dir/production-methods.swift"
{
  printf '%s\n' 'import Foundation'
  # Only the real cue storage/bounds/offset/lookup are needed. Exclude parsing, downloads and native views.
  sed -n '/^struct SubtitleCue {/,/    \/\/ MARK: - Parsing/p' \
    app/Sources/Player/SubtitleCueRenderer.swift | sed '$d'
  sed -n '/    private static func boundedCues(/,/^    }/p' app/Sources/Player/SubtitleCueRenderer.swift
  printf '%s\n' '}'
} > "$subtitle_test_dir/renderer.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  app/Sources/Player/RemuxResumePolicy.swift "$subtitle_test_dir/renderer.swift" \
  "$subtitle_test_dir/production-methods.swift" app/Tests/AVPlayerSubtitleClockTests.swift \
  -o "$subtitle_test_dir/subtitle-clock"
"$subtitle_test_dir/subtitle-clock"
