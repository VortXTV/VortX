// Exact current value types for the whole-ranker host check. Mutable stores/UI/native transport are NOT
// compiled here; the harness supplies explicit task-local preferences and inert peripheral boundaries.
const fs = require('node:fs');
const root = process.argv[2];
const prefs = fs.readFileSync(root + '/app/SourcesShared/SourcePreferences.swift', 'utf8');
const pins = fs.readFileSync(root + '/app/SourcesShared/SourcePin.swift', 'utf8');
function block(source, anchor) {
  const start = source.indexOf(anchor), open = source.indexOf('{', start);
  if (start < 0 || open < 0 || source.indexOf(anchor, start + 1) >= 0) throw Error('nonunique/missing: ' + anchor);
  let depth = 1, end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  if (depth) throw Error('unbalanced: ' + anchor);
  return source.slice(start, end) + '\n';
}
require('./extract-source-quick-filter-models.cjs');
process.stdout.write(block(prefs, 'enum SourceType: String, CaseIterable, Codable, Sendable {'));
process.stdout.write(block(prefs, 'protocol SourcePrefsReading {'));
const weights = prefs.match(/^    fileprivate nonisolated static let tierWeights = .+$/m);
const local = prefs.match(/^    @TaskLocal nonisolated static var readingOverride: Snapshot\?$/m);
if (!weights || !local) throw Error('missing current snapshot dependencies');
process.stdout.write('enum SourcePreferences {\n' + weights[0].replace('fileprivate ', '') + '\n' +
  block(prefs, 'struct Snapshot: SourcePrefsReading, Sendable {') + local[0] + '\n' +
  'static var reading: SourcePrefsReading { guard let value = readingOverride else { fatalError("explicit fixture scope required") }; return value }\n}\n');
process.stdout.write(block(pins, 'struct SourcePin: Codable, Equatable, Sendable {') +
  block(pins, 'enum SourcePinScope: String, Codable, CaseIterable, Sendable {') +
  block(pins, 'struct ResolvedPin: Equatable, Sendable {') +
  'enum SourcePinStore {\n' + block(pins, 'static func matches(_ stream: CoreStream, addon: String, pin: ResolvedPin) -> Bool {') + '}\n');
