'use strict';

// Source preparation/verification only. Does not launch Swift, an app, or another process.
// Run from the exact repository; the parent supplies a fresh retained app/build directory.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = fs.realpathSync(process.cwd());
const output = fs.realpathSync(process.argv[2]);
if (!output.startsWith(path.join(root, 'app', 'build') + path.sep)) throw Error('Expected retained app/build directory');
const inputs = [
  'app/SourcesTV/TVPlayerView.swift',
  'app/SourcesShared/SeekBarStyle.swift',
  'app/Tests/TVSeekTrackMotionTests.swift',
  'app/Tests/Fixtures/TVSeekTrackMotionBaseline.swift.txt',
  'scripts/prepare-tv-seek-track-motion.cjs',
];
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const manifestPath = path.join(output, 'source-manifest.json');
if (process.argv[3] === '--verify') {
  const saved = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (saved.version !== 1 || saved.root !== root || JSON.stringify(saved.inputs.map(x => x.path)) !== JSON.stringify(inputs)) {
    throw Error('Wrong source manifest');
  }
  for (const entry of saved.inputs) {
    if (digest(fs.readFileSync(path.join(root, entry.path))) !== entry.sha256
      || digest(fs.readFileSync(path.join(output, 'source-evidence', entry.path))) !== entry.sha256) {
      throw Error('Owning/captured source changed: ' + entry.path);
    }
  }
  if (saved.generated.path !== 'TVSeekTrackProductionExtract.swift'
    || digest(fs.readFileSync(path.join(output, saved.generated.path))) !== saved.generated.sha256) {
    throw Error('Generated source changed');
  }
  console.log('Exact owning, captured and generated source hashes match');
  process.exit(0);
}
if (process.argv.length !== 3) throw Error('Usage: node prepare-tv-seek-track-motion.cjs <fresh-retained-directory> [--verify]');
if (fs.readdirSync(output).length !== 0) throw Error('Preparation requires a fresh empty retained directory');

// Capture every owning input before extraction. Extraction never rereads mutable source files.
const captured = inputs.map(relative => ({ path: relative, bytes: fs.readFileSync(path.join(root, relative)) }));
const texts = new Map(captured.map(entry => [entry.path, entry.bytes.toString('utf8')]));
function unique(source, needle) {
  const at = source.indexOf(needle);
  if (at < 0 || source.indexOf(needle, at + needle.length) >= 0) throw Error('Missing/ambiguous anchor: ' + needle);
  return at;
}
function between(source, start, end) {
  const a = unique(source, start), b = unique(source, end);
  if (b <= a) throw Error('Reordered anchors');
  return source.slice(a, b);
}
function braced(source, marker) {
  const a = unique(source, marker), open = source.indexOf('{', a);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(a, i + 1);
  }
  throw Error('Unclosed bounded source member');
}
const tv = texts.get(inputs[0]), shared = texts.get(inputs[1]);
const scrubber = between(tv, '    private var scrubber: some View {', '\n    /// The Live position indicator').trimEnd() + '\n';
unique(tv, 'if showInfo && !showOptions && !loadFailed { controlBar }');
const constructor = between(scrubber, 'SeekBarTrack(', '\n                    .frame(width: w, height: focused ? 24 : 16)').trimEnd();
if (!constructor.endsWith(')')) throw Error('Unclosed track constructor');
const animatedMarker = ',\n                             animated:';
const animatedAt = constructor.indexOf(animatedMarker);
const originalConstructor = animatedAt < 0 ? constructor : constructor.slice(0, unique(constructor, animatedMarker)) + ')';
const baseline = texts.get(inputs[3]);
if (scrubber.replace(constructor, originalConstructor) !== baseline) {
  throw Error('Non-animation scrubber inputs, geometry or focus code changed; inspect and intentionally update the baseline');
}
const shown = between(scrubber, 'let shown =', '\n        return GeometryReader').trimEnd();
const fraction = between(scrubber, 'let frac =', '\n            let w =').trimEnd();
const style = between(shared, 'enum SeekBarStyle:', '\n/// Draws the seek-bar TRACK');
const cases = style.match(/^    case [A-Za-z][A-Za-z, ]*$/gm);
if (!cases || cases.length !== 2) throw Error('Changed seek-style case declarations require review');
const animatedStyle = braced(style, 'var isAnimated: Bool {');
const track = between(shared, 'struct SeekBarTrack: View {', '\n// MARK: - Renderer');
const defaultAnimated = track.match(/^    var animated: Bool = (true|false)$/gm);
if (!defaultAnimated || defaultAnimated.length !== 1) throw Error('Changed track animated default requires review');
const paused = between(track, 'TimelineView(.animation(paused: ', ')) { timeline in').slice('TimelineView(.animation(paused: '.length);

// Explicit seam: deterministic value/probe types replace SwiftUI, Theme and persisted style selection.
// Constructor, progress expressions, isAnimated member and Timeline paused expression are exact source.
// The real enum's UserDefaults-backed `current` accessor is neither copied nor called.
const generated = `import Foundation
struct ProbeColor: Equatable, Sendable {
    let name: String
    var alpha: Double = 1
    func opacity(_ value: Double) -> Self { Self(name: name, alpha: value) }
}
enum Theme { enum Palette {
    static let accent = ProbeColor(name: "accent")
    static let textPrimary = ProbeColor(name: "textPrimary")
} }
enum SeekBarStyle: String, CaseIterable {
${cases.join('\n')}
    @MainActor static var current: Self = .classic
    ${animatedStyle}
}
struct SeekBarTrack {
    let style: SeekBarStyle
    let progress: Double
    let accent: ProbeColor
    var track: ProbeColor
    var buffered: Double
${defaultAnimated[0]}
    func sourceTimelinePaused() -> Bool { return ${paused} }
}
@MainActor struct TVSeekTrackProductionFixture {
    var showInfo = true
    var showOptions = false
    var loadFailed = false
    var isPaused = false
    var scrubbing = false
    var accessibilityReduceMotion = false
    var duration = 100.0
    var currentTime = 25.0
    var scrubTarget = 75.0
    var bufferedTime = 50.0
    func makeTrack() -> SeekBarTrack {
        ${shown}
        ${fraction}
        return ${constructor}
    }
}
`;
for (const entry of captured) {
  if (!fs.readFileSync(path.join(root, entry.path)).equals(entry.bytes)) throw Error('Owning source changed during extraction: ' + entry.path);
}
for (const entry of captured) {
  const target = path.join(output, 'source-evidence', entry.path);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, entry.bytes, { flag: 'wx' });
}
const generatedPath = 'TVSeekTrackProductionExtract.swift';
fs.writeFileSync(path.join(output, generatedPath), generated, { flag: 'wx' });
fs.writeFileSync(manifestPath, JSON.stringify({
  version: 1, root,
  inputs: captured.map(entry => ({ path: entry.path, sha256: digest(entry.bytes) })),
  generated: { path: generatedPath, sha256: digest(generated) },
  admission: 'source-unit only; fixture current style; no UserDefaults, SwiftUI, Timeline scheduling, app or SDK build',
  animatedArgumentPresent: animatedAt >= 0,
}, null, 2) + '\n', { flag: 'wx' });
console.log('Retained exact inputs and source-unit extraction; no compiler or process launched');
