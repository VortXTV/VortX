#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
accent_test_dir=$(mktemp -d app/build/player-accent-controls-tests.XXXXXX)

# Compile the exact production modifier with only its palette dependencies. No application target,
# playback engine, network, or media session is started by this executable.
node - "$accent_test_dir" <<'NODE'
const fs = require('node:fs');
const production = fs.readFileSync('app/Sources/PlayerScreen.swift', 'utf8');
const test = fs.readFileSync('app/Tests/PlayerAccentControlsReduceTransparencyTests.swift', 'utf8');
const start = production.indexOf('private enum PlayerControlReduceTransparencyOverrideKey');
const end = production.indexOf('private struct PlayerControlButton:', start);
if (start < 0 || end < 0) throw new Error('Missing production player control presentation slice');
const modifier = production.slice(start, end);
if (!modifier.includes('private struct PlayerControlSurfaceModifier')) {
  throw new Error('Production player control modifier was not extracted');
}
const palette = `
enum Theme {
    enum Palette {
        static let accent = Color(red: 0.22, green: 0.58, blue: 0.91)
        static let accentBright = Color(red: 0.35, green: 0.72, blue: 1.0)
        static let onAccent = Color(red: 0.03, green: 0.04, blue: 0.06)
        static let surface1 = Color(red: 0.07, green: 0.08, blue: 0.10)
        static let textTertiary = Color(red: 0.55, green: 0.58, blue: 0.62)
        static let hairline = Color(red: 0.25, green: 0.28, blue: 0.32)
    }
}
`;
fs.writeFileSync(process.argv[2] + '/accent.swift',
  'import SwiftUI\nimport AppKit\n' + palette + '\n' + modifier + '\n' + test);
NODE

xcrun swiftc -O -parse-as-library \
  "$accent_test_dir/accent.swift" \
  -o "$accent_test_dir/accent-controls"
"$accent_test_dir/accent-controls"
