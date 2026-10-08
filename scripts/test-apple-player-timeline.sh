#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
timeline_test_dir=$(mktemp -d app/build/player-timeline-tests.XXXXXX)
# Extract actual production view bodies/factories/editor methods; change only access control.
node - "$timeline_test_dir" <<'NODE'
const fs = require('node:fs');
const source = fs.readFileSync('app/Sources/PlayerScreen.swift', 'utf8');
function slice(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a);
  if (a < 0 || b < 0) throw new Error('Missing production slice: ' + start);
  return source.slice(a, b);
}
const leaves = slice('private final class TimePosClock:', '/// One provider refresh');
const factories = slice('    private var skipEditorTimelineValues:', '    #if !os(tvOS)\n    // MARK: - Skip segment edit bar');
const editor = slice('    private func skipDBEditBar(', '    /// Submit the edited segment.');
const controls = slice('    private var liveIndicator:', '    private func iconButton(');
const touchActions = slice('    private var touchOptionsActions:', '    private var touchTransport:');
const tooltip = slice('extension View {\n    func skipDBTooltip(', '\n#endif');
const submit = fs.readFileSync('app/SourcesShared/SkipDBSubmitView.swift', 'utf8');
const segmentType = submit.slice(submit.indexOf('    enum SegmentType:'), submit.indexOf('    enum SubmitResult'));
if (!segmentType) throw new Error('Missing production segment types');
const output = 'import SwiftUI\n' + leaves + '\nstruct SkipDBSubmitView {\n' + segmentType + '\n}\nextension PlayerScreen {\n' + factories + '\n' + editor + '\n' + controls + '\n' + touchActions + '\n}\n' + tooltip + '\n';
fs.writeFileSync(process.argv[2] + '/timeline.swift', output.replace(/\b(?:fileprivate|private) (?=(?:final )?(?:class|struct|enum|func|var|let))/g, ''));
NODE
if [[ "${1:-}" == "--prepare-only" ]]; then
  # These identical sources can also be compiled into a UIKit simulator probe.
  printf '%s\n' "$timeline_test_dir"
  exit 0
fi
xcrun swiftc -O -parse-as-library \
  "$timeline_test_dir/timeline.swift" app/Sources/Player/SkipSegments.swift \
  app/SourcesShared/GlassStyle.swift app/SourcesShared/Theme.swift app/SourcesShared/ThemeManager.swift app/SourcesShared/SeekBarStyle.swift \
  app/SourcesShared/ChipButtonStyle.swift app/SourcesShared/SkipEditPolicy.swift \
  app/Tests/PlayerSeekTimelineConstructionTests.swift -o "$timeline_test_dir/construction"
"$timeline_test_dir/construction"
node --test test/apple-player-timeline-boundaries.test.js
bash scripts/test-apple-player-accent-controls.sh
