const fs = require('node:fs');
const source = fs.readFileSync(process.argv[2] + '/app/SourcesShared/CoreModels.swift', 'utf8');
function full(anchor) {
  const start = source.indexOf(anchor), open = source.indexOf('{', start);
  if (start < 0 || open < 0) throw Error('missing actual model: ' + anchor);
  let depth = 1, end = open + 1;
  for (; depth && end < source.length; end++) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; }
  if (depth) throw Error('unbalanced actual model');
  return source.slice(start, end) + '\n';
}
const first = source.indexOf('struct CoreStream: Decodable, Identifiable, Equatable, Sendable {');
const last = source.indexOf('    /// A bare YouTube source', first);
if (first < 0 || last <= first) throw Error('actual CoreStream stored fields/identity/descriptor prefix missing');
process.stdout.write('import Foundation\n' + source.slice(first, last) + '}\n' +
  full('struct CoreStreamBehaviorHints: Decodable, Equatable, Sendable {') +
  full('struct CoreProxyHeaders: Decodable, Equatable, Sendable {') +
  full('struct CoreStreamSourceGroup: Identifiable, Equatable, Sendable {'));
