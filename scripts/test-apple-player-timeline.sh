#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
timeline_test_dir=$(mktemp -d app/build/player-timeline-tests.XXXXXX)
# Include the whole real value-observation helper, then extract actual view bodies/factories/editor methods.
# Only production access control is changed; fixture actor isolation stays explicit.
node - "$timeline_test_dir" <<'NODE'
const fs = require('node:fs');
const source = fs.readFileSync('app/Sources/PlayerScreen.swift', 'utf8');
const valueChange = fs.readFileSync('app/SourcesShared/ValueChangeObservation.swift', 'utf8');
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
const output = valueChange + '\n' + leaves + '\nstruct SkipDBSubmitView {\n' + segmentType + '\n}\nextension PlayerScreen {\n' + factories + '\n' + editor + '\n' + controls + '\n' + touchActions + '\n}\n' + tooltip + '\n';
fs.writeFileSync(process.argv[2] + '/timeline.swift', output.replace(/\b(?:fileprivate|private) (?=(?:final )?(?:class|struct|enum|func|var|let))/g, ''));
NODE
if [[ "${1:-}" == "--prepare-only" ]]; then
  # Prepared UIKit simulator consumers must compile these identical sources in Swift 6 mode.
  printf '%s\n' "$timeline_test_dir"
  exit 0
fi
xcrun swiftc -swift-version 6 -O -parse-as-library \
  "$timeline_test_dir/timeline.swift" app/Sources/Player/SkipSegments.swift \
  app/SourcesShared/GlassStyle.swift app/SourcesShared/Theme.swift app/SourcesShared/ThemeManager.swift app/SourcesShared/SeekBarStyle.swift \
  app/SourcesShared/ChipButtonStyle.swift app/SourcesShared/SkipEditPolicy.swift \
  app/SourcesShared/VisualEffects.swift app/SourcesShared/ReducedMotion.swift \
  app/Sources/Player/PlaybackMetadataFacts.swift app/Sources/Player/PlaybackMetadataPills.swift \
  app/Tests/PlayerSeekTimelineConstructionTests.swift -o "$timeline_test_dir/construction"
"$timeline_test_dir/construction"
node --test test/apple-player-timeline-boundaries.test.js
bash scripts/test-apple-player-accent-controls.sh
