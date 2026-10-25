// Harness preparation: retain exact production declarations used by policy.
const fs = require('node:fs');
const source = fs.readFileSync(process.argv[2] + '/app/SourcesShared/CoreModels.swift', 'utf8');
function prefix(start, end) {
  const first = source.indexOf(start), last = source.indexOf(end, first);
  if (first < 0 || last <= first) throw Error('production extraction anchor missing: ' + start);
  return source.slice(first, last) + '}\n';
}
function full(start, text = source) {
  const first = text.indexOf(start), open = text.indexOf('{', first);
  if (first < 0 || open < 0) throw Error('production extraction anchor missing: ' + start);
  let depth = 1, end = open + 1;
  for (; depth && end < text.length; end++) { if (text[end] === '{') depth++; if (text[end] === '}') depth--; }
  if (depth) throw Error('unbalanced production declaration');
  return text.slice(first, end) + '\n';
}
// Unrelated CoreCWItem lifecycle helpers and CoreVideo's global EPG formatter are
// not dependencies of this picker. No replacement behavior or mock parser is used.
process.stdout.write('import Foundation\n' +
  full('indirect enum VortxJSON: Codable, Equatable, Sendable {',
    fs.readFileSync(process.argv[2] + '/app/SourcesShared/VortxResourceBridge.swift', 'utf8')) +
  full('enum VortxMetaLoadingProjection {',
    fs.readFileSync(process.argv[2] + '/app/SourcesShared/VortxResourceProjection.swift', 'utf8')) +
  full('struct CoreResourceRequest: Decodable, Sendable {') + full('struct CoreResourcePath: Decodable, Sendable {') +
  full('enum CoreLoadable<T: Decodable>: Decodable {') +
  full('extension CoreLoadable: Sendable where T: Sendable {') + full('struct CoreMetaSelection: Decodable, Sendable {') +
  full('struct CoreMetaDetails: Decodable, Sendable {') + full('struct CoreMetaEntry: Decodable, Sendable {') +
  prefix('struct CoreMetaItem: Decodable, Sendable {', '    /// A title ID is not a version of its metadata.') +
  full('struct CoreLink: Decodable, Equatable, Sendable {') + full('struct CoreMetaBehaviorHints: Decodable, Equatable, Sendable {') +
  full('struct CoreStreamGroup: Decodable, Sendable {') +
  fs.readFileSync(process.argv[2] + '/app/SourcesShared/DetailMetaRecoveryPolicy.swift', 'utf8') + '\n' +
  prefix('struct CoreCWItem: Decodable, Identifiable, Sendable {', '    /// 0…1 watch progress') +
  full('struct CoreLibState: Decodable, Sendable {') +
  prefix('struct CoreVideo: Decodable, Identifiable, Equatable, Sendable {', '    /// The `released` string parsed as a `Date`'));
// Compile the actual owner closure verbatim. The facade context below is controlled test state;
// enqueue/session execution stays outside this fixture and is checked by the source contract.
const facade = fs.readFileSync(process.argv[2] + '/app/SourcesShared/VortxNativeCoreFacade.swift', 'utf8');
const loadStart = facade.indexOf('if name == "Load", model == "MetaDetails", field == "meta_details" {');
const projectionStart = facade.indexOf('            let previous = values[field], account = accountEpoch', loadStart);
const projectionEnd = facade.indexOf('            return enqueue(field, initial: project(loading))', projectionStart);
if (loadStart < 0 || projectionStart < 0 || projectionEnd <= projectionStart) throw Error('actual metadata owner projection missing');
process.stdout.write(`
// Inert peripherals only: no addon preference lookup, navigation inventory validation, or stream decoding proof.
enum ProfileStore {
    static func activeDisabledAddons() -> Set<String> { [] }
    static func activeAddonOrder(accountOrder: [String]) -> [String] { accountOrder }
}
enum ProfileAddonPreferencesPolicy { static func identity(_ value: String) -> String { value } }
enum VortXSyncManager { static let appliedAddonOrder: [String] = [] }
struct CoreStream: Decodable, Sendable {}
enum EpisodePlaybackIdentity {
    enum Authority { case launch }
    static func appleCWSeriesInventory(from videos: [CoreVideo], authority: Authority) -> [CoreVideo]? { videos }
}
final class MetaProjectionOwnerFixture: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var values: [String: VortxJSON] = [:]
    var accountEpoch = UUID(), watchlistProfileGeneration = UUID(), registryGeneration = UUID()
    var closed = false, resourceRegistryValid = true
    var pendingProfileTransitions = 0
    func capture(previous prior: VortxJSON, profile: String) -> @Sendable (VortxJSON) -> VortxJSON {
        lock.lock(); defer { lock.unlock() }
        let field = "meta_details"
        values[field] = prior
        values["native_state"] = .object(["activeProfileId": .string(profile)])
${facade.slice(projectionStart, projectionEnd)}
        return project
    }
}
`);
