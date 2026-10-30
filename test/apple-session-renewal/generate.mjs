// Authored UNRUN. Unique literal declaration extraction, adapted from actual auth-recovery runner.
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {createHash} from 'node:crypto';
if (process.argv.length !== 7) throw Error('Expected source-dir, exact-pins.json, context-root, output-dir, fixture');
const [dir, pinFile, context, out, fixture] = process.argv.slice(2).map(value => resolve(value));
const pins = JSON.parse(readFileSync(pinFile, 'utf8'));
const hash = value => createHash('sha256').update(value).digest('hex');
const files = Object.fromEntries(['AuthenticatedHTTPTransport.swift','Keychain.swift','VortXSyncManager.swift'].map(name => {
  const value = readFileSync(resolve(dir, name), 'utf8');
  if (!/^[0-9a-f]{64}$/.test(pins[name] ?? '') || hash(value) !== pins[name]) throw Error('Source pin mismatch: ' + name);
  return [name, value];
}));
const scope = readFileSync(resolve(context, 'app/SourcesShared/CredentialScope.swift'), 'utf8');
if (hash(scope) !== pins['CredentialScope.swift']) throw Error('Credential result source pin mismatch');
mkdirSync(resolve(out, 'original-suite/app/SourcesShared'), {recursive:true});
mkdirSync(resolve(out, 'original-suite/app/Tests'), {recursive:true});
writeFileSync(resolve(out, 'original-suite/app/SourcesShared/CredentialScope.swift'), scope);
writeFileSync(resolve(out, 'original-suite/app/SourcesShared/Keychain.swift'), files['Keychain.swift']);
const exactJSON = readFileSync(resolve(context, 'app/SourcesShared/OwnerHistoryExactJSON.swift'), 'utf8');
if (hash(exactJSON) !== pins['OwnerHistoryExactJSON.swift']) throw Error('Exact JSON source pin mismatch');
const legacyTests = readFileSync(resolve(context, 'app/Tests/KeychainFailureClosedTests.swift'));
if (hash(legacyTests) !== pins['KeychainFailureClosedTests.swift']) throw Error('Original Keychain suite pin mismatch');
writeFileSync(resolve(out, 'original-suite/app/Tests/KeychainFailureClosedTests.swift'), legacyTests);
function extract(source, signature) {
  const start = source.indexOf(signature);
  if (start < 0 || source.indexOf(signature, start + signature.length) >= 0) throw Error('Missing/ambiguous declaration: ' + signature);
  let depth = 0, opened = false, state = 'code', escaped = false;
  for (let i = start; i < source.length; i++) {
    const c = source[i], n = source[i + 1];
    if (state === 'line') { if (c === '\n') state = 'code'; continue; }
    if (state === 'block') { if (c === '*' && n === '/') { state = 'code'; i++; } continue; }
    if (state === 'string') { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') state = 'code'; continue; }
    if (c === '/' && n === '/') { state = 'line'; i++; continue; }
    if (c === '/' && n === '*') { state = 'block'; i++; continue; }
    if (c === '"') { state = 'string'; continue; }
    if (c === '{') { depth++; opened = true; }
    if (c === '}' && opened && --depth === 0) return source.slice(start, i + 1);
  }
  throw Error('Unterminated declaration: ' + signature);
}
const manager = files['VortXSyncManager.swift'];
const extracted = {
  mutation: extract(scope, 'enum CredentialMutationResult: Equatable, Sendable'),
  durable: extract(scope, 'enum CredentialDurableReadResult: Equatable, Sendable'),
  credentialScope: extract(scope, 'enum CredentialScope: Equatable, Hashable, Sendable'),
  store: extract(files['Keychain.swift'], 'final class KeychainFailureClosedStore: @unchecked Sendable'),
  account: extract(manager, 'struct Account: Codable, Equatable, Sendable'),
  persisted: extract(manager, 'private struct Persisted: Codable, Sendable'),
  claims: extract(manager, 'private struct RenewalClaims'),
  base64: extract(manager, 'private static func decodeCanonicalBase64URL('),
  integer: extract(manager, 'private static func exactSafeUnsignedInteger('),
  now: extract(manager, 'private static func sessionNowMilliseconds()'),
  parse: extract(manager, 'private static func renewalClaims('),
  persistRenewal: extract(manager, 'private func storeSessionRenewal('),
  request: extract(manager, 'private func request('),
  currency: extract(manager, 'private func isCurrent(_ capture: CredentialScopeRegistry.Capture)'),
};
// Compiler-only credential boundary; whole CredentialScope remains captured for source inspection.
// Do not import its unrelated native ownership graph into these deliberately standalone lanes.
const resultTypes = `import Foundation\n${extracted.mutation}\n${extracted.durable}\n`;
writeFileSync(resolve(out, 'CredentialResultTypes.swift'), resultTypes);
const anchor = 'static let shared = AuthenticatedHTTPTransport()';
let transport = files['AuthenticatedHTTPTransport.swift'];
if (transport.split(anchor).length !== 2) throw Error('Shared transport injection anchor changed');
transport = transport.replace(anchor, 'static let shared = AuthenticatedHTTPTransport(protocolClasses: [RenewalProtocol.self])');
const wrappers = `
func perform(_ path: String = "/v1/backup", capture: CredentialScopeRegistry.Capture?, auth: Bool = true, bearer: String? = nil, conditional: Int? = nil) async -> Int {
    await request("GET", path, auth: auth, bearer: bearer, credentialCapture: capture, ifNoneMatch: conditional).0
}
func seed(_ value: String) throws {
    token = value
    let tuple = Persisted(token: value, account: account!, dataKey: dataKey!.base64EncodedString())
    Keychain.backend.seed(String(decoding: try JSONEncoder().encode(tuple), as: UTF8.self), account: kcAccount)
}
func persistedToken() throws -> String {
    guard case .value(let raw) = Keychain.store.durableString(kcAccount) else { throw RenewalTestFailure.failed }
    return try JSONDecoder().decode(Persisted.self, from: Data(raw.utf8)).token
}
func persistedMetadataMatches() throws -> Bool {
    guard case .value(let raw) = Keychain.store.durableString(kcAccount) else { return false }
    let tuple = try JSONDecoder().decode(Persisted.self, from: Data(raw.utf8))
    return tuple.account == account && tuple.dataKey == dataKey?.base64EncodedString()
}
`;
const generated = `import Foundation\nimport CoreFoundation\n${extracted.mutation}\n${extracted.durable}\n${extracted.credentialScope}\n${extracted.store}\n${exactJSON}\n${transport}\n@MainActor extension RenewalFixture {\n${extracted.account}\n${extracted.persisted}\n${extracted.claims}\n${extracted.base64}\n${extracted.integer}\n${extracted.now}\n${extracted.parse}\n${extracted.persistRenewal}\n${extracted.request}\n${extracted.currency}\n${wrappers}\n}\n`;
writeFileSync(resolve(out, 'Production.swift'), generated);
writeFileSync(resolve(out, 'source-receipt.json'), JSON.stringify({schemaVersion:1, sourceDirectory:dir,
  fullSourceSHA256: Object.fromEntries(Object.entries(files).map(([key,value]) => [key,hash(value)])),
  credentialResultSourceSHA256:hash(scope), exactJSONSourceSHA256:hash(exactJSON), originalKeychainTestsSHA256:hash(legacyTests), fixtureSHA256:hash(readFileSync(fixture)),
  fileTransactionFixtureSHA256:hash(readFileSync(resolve(dirname(fixture), 'FileTransactionTests.swift'))),
  compilerOnlyResultTypesSHA256:hash(resultTypes),
  fullFileLaneInputs:['CredentialResultTypes.swift','original-suite/app/SourcesShared/Keychain.swift','FileTransactionTests.swift'],
  originalSuiteLaneInputs:['CredentialResultTypes.swift','original-suite/app/SourcesShared/Keychain.swift','original-suite/app/Tests/KeychainFailureClosedTests.swift'],
  wholeCredentialScopeRole:'captured read-only source; not selected in full-file/original-suite compiles',
  declarations:Object.fromEntries(Object.entries(extracted).map(([key,value])=>[key,hash(value)])),
  transformation:{count:1, from:anchor, to:'static let shared = AuthenticatedHTTPTransport(protocolClasses: [RenewalProtocol.self])'},
  transformedTransportSHA256:hash(transport), generatedSHA256:hash(generated),
  fixtureReplaces:['manager state/credential registry','static Keychain adapter via actual store injection','URLProtocol server response producer'],
  fixtureDoesNotReplace:['request route/status/owner/token admission','transport delegate/no redirect/byte bounds','renewal claims decoder','tuple CAS/marker/readback/generation/pending logic']}, null, 2)+'\n');
