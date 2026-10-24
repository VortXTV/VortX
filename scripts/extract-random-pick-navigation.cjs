// Mechanical production extraction only. Run serially from test-random-pick.sh.
const fs = require('node:fs');
const root = process.argv[2];
const facade = fs.readFileSync(root + '/app/SourcesShared/VortxNativeCoreFacade.swift', 'utf8');
const session = fs.readFileSync(root + '/app/SourcesShared/VortxNativeSession.swift', 'utf8');
function full(text, start) {
  const first = text.indexOf(start), open = text.indexOf('{', first);
  if (first < 0 || open < 0 || text.indexOf(start, first + start.length) >= 0) throw Error('non-unique extraction anchor: ' + start);
  let depth = 1, end = open + 1;
  for (; depth && end < text.length; end++) { if (text[end] === '{') depth++; if (text[end] === '}') depth--; }
  if (depth) throw Error('unbalanced production declaration: ' + start);
  return text.slice(first, end) + '\n';
}
// Actual scope's Codable/Hashable/Sendable stored-field prefix; unrelated session validation is
// not replaced or exercised. VortxJSON is already extracted by extract-random-pick-models.cjs.
const scopeStart = session.indexOf('struct VortxAccountScope: Codable, Hashable, Sendable {');
const scopeEnd = session.indexOf('    func validate() throws {', scopeStart);
if (scopeStart < 0 || scopeEnd <= scopeStart) throw Error('actual account scope prefix missing');
process.stdout.write('import Foundation\n' + session.slice(scopeStart, scopeEnd) + '}\n');
// The fixture supplies typed stored state only. All receipt comparison/capture functions,
// availability and mutation/acknowledged owner getters below are copied verbatim, not mocks.
process.stdout.write(`
final class RandomNavigationFacadeFixture {
    struct Session { var scope: VortxAccountScope }
    var session = Session(scope: .init(account: "account-A", ownerProfileID: "owner-A"))
    let lock = NSRecursiveLock()
    var values: [String: VortxJSON] = [:]
    var accountEpoch = UUID(), watchlistProfileGeneration = UUID(), registryGeneration = UUID()
    var closed = false, checkpointReopenRequired = false, resourceRegistryValid = true
    var pendingProfileTransitions = 0
`);
for (const anchor of [
  'struct RegistryBinding: Equatable, Sendable {', 'struct WatchlistBinding: Equatable, Sendable {',
  'struct AcceptedNavigationReceipt: Equatable, Sendable {', 'var watchlistBinding: WatchlistBinding? {',
  'var isAvailable: Bool {', 'var registryBinding: RegistryBinding? {',
  'func captureAcceptedNavigation(expected: WatchlistBinding)',
  'func acceptedNavigationIsCurrent(_ receipt: AcceptedNavigationReceipt)',
  'private func string(_ value: VortxJSON?)'
]) process.stdout.write(full(facade, anchor));
process.stdout.write('}\n');
