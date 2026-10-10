#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
premium_test_dir=$(mktemp -d app/build/player-premium-controls-tests.XXXXXX)

# Compile real production leaves/components in isolation. Only palette and callbacks are fixtures;
# no app target, playback engine, network, media, provider, or customer state is involved.
node - "$premium_test_dir" <<'NODE'
const fs = require('node:fs');
const player = fs.readFileSync('app/Sources/PlayerScreen.swift', 'utf8');
const styles = fs.readFileSync('app/SourcesShared/SeekBarStyle.swift', 'utf8');
const test = fs.readFileSync('app/Tests/PlayerPremiumControlsRenderingTests.swift', 'utf8');

function slice(source, start, end) {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a);
  if (a < 0 || b < 0) throw new Error('Missing production slice: ' + start);
  return source.slice(a, b);
}

const seekLeaves = slice(player, 'private final class TimePosClock:', 'private struct PlayerBufferedBand:');
const seekSurface = slice(player, 'private struct PlayerBufferedBand:', '#if !os(tvOS)\nprivate struct PlayerSkipTimelineBands');
const skipMarkers = slice(player, '#if !os(tvOS)\nprivate struct PlayerSkipTimelineBands', '/// GeometryReader returns this named');
const timelineTrack = slice(player, '/// GeometryReader returns this named', '/// The build-255 failure');
const bottomTimeline = slice(player, 'private struct PlayerBottomTimeline:', 'private struct PlayerSkipEditorSection:');
const controlChrome = slice(player, 'private enum PlayerControlReduceTransparencyOverrideKey', 'private struct PlayerTransportToolbar:');
const seekStyleRenderer = slice(styles, 'import SwiftUI', '/// Settings list of the seek-bar styles');
if (!seekSurface.includes('#if os(iOS) || os(macOS)') || !seekSurface.includes('PlayerStyledSeekSlider(')) {
  throw new Error('Production macOS seek surface no longer routes through the styled slider');
}
for (const contract of [
  '.accessibilityLabel("Playback position")',
  '.accessibilityAdjustableAction',
  '.accessibilityHint("Swipe up or down to seek ten seconds")',
  '.gesture(DragGesture(minimumDistance: 0)',
]) {
  if (!seekLeaves.includes(contract)) throw new Error('Missing production seek interaction/accessibility contract: ' + contract);
}
if (!controlChrome.includes('.frame(minHeight: 44)')) {
  throw new Error('Production player toolbar button lost its minimum target height');
}

const palette = `
enum Theme {
  enum Palette {
    static let accent = Color(red: 0.22, green: 0.58, blue: 0.91)
  }
}
`;
const output = [
  'import SwiftUI',
  'import AppKit',
  palette,
  seekLeaves,
  seekSurface,
  skipMarkers,
  timelineTrack,
  bottomTimeline,
  controlChrome,
  seekStyleRenderer,
  test,
].join('\n');
fs.writeFileSync(process.argv[2] + '/premium-controls.swift',
  output.replace(/\b(?:fileprivate|private) (?=(?:final )?(?:class|struct|enum|func|var|let))/g, ''));
NODE

xcrun swiftc -Onone -parse-as-library \
  "$premium_test_dir/premium-controls.swift" \
  -o "$premium_test_dir/premium-controls"
"$premium_test_dir/premium-controls" "$premium_test_dir"
