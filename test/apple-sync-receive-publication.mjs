import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const sha256 = value => createHash('sha256').update(value).digest('hex');
if (process.argv[2] === '--extract') {
  const output = process.argv[3];
  await mkdir(output, { recursive: true });
  const receipts = [];
  async function source(path) { return { path, text: await readFile(path, 'utf8') }; }
  function slice(file, marker, endMarker, includeEnd = false) {
    const start = file.text.indexOf(marker); assert(start >= 0, `missing ${file.path}: ${marker}`);
    assert.equal(file.text.indexOf(marker, start + marker.length), -1, `ambiguous ${marker}`);
    const end = file.text.indexOf(endMarker, start + marker.length); assert(end > start, `missing end of ${marker}`);
    const selected = file.text.slice(start, end + (includeEnd ? endMarker.length : 0));
    receipts.push({ path: file.path, marker, firstLine: file.text.slice(0, start).split('\n').length,
      lastLine: file.text.slice(0, start + selected.length).split('\n').length,
      sourceSHA256: sha256(file.text), sliceSHA256: sha256(selected) });
    return selected;
  }
  function member(file, marker) {
    let start = file.text.indexOf(marker); assert(start >= 0, `missing ${marker}`);
    const markerStart = start;
    // Attributes are semantic source, including MainActor on bridge merge/profile publication.
    while (start > 0) {
      const priorStart = file.text.lastIndexOf('\n', start - 2) + 1;
      if (!file.text.slice(priorStart, start).trim().startsWith('@')) break;
      start = priorStart;
    }
    const firstLineEnd = file.text.indexOf('\n', start);
    const markerLineEnd = file.text.indexOf('\n', markerStart);
    const end = file.text.slice(markerStart, markerLineEnd).trimEnd().endsWith('}')
      ? markerLineEnd : file.text.indexOf('\n    }', markerStart) + 6;
    assert(end > markerStart, `unterminated member ${marker}`);
    const selected = file.text.slice(start, end);
    receipts.push({ path: file.path, marker, firstLine: file.text.slice(0, start).split('\n').length,
      lastLine: file.text.slice(0, end).split('\n').length, sourceSHA256: sha256(file.text), sliceSHA256: sha256(selected) });
    return selected;
  }
  const [manager, core, profiles, discovery, models, target] = await Promise.all([
    source('app/SourcesShared/VortXSyncManager.swift'), source('app/SourcesShared/CoreBridge.swift'),
    source('app/SourcesShared/Profiles.swift'), source('app/SourcesShared/ProfileDiscoveryPreferences.swift'),
    source('app/SourcesShared/CoreModels.swift'), source('app/SourcesShared/StremioAccount.swift')]);
  const managerMethods = ['    private static func sawDocV2(', '    private static func markSawDocV2(',
    '    private func openSyncDocument(', '    private static func decodeDecryptedSyncDocument(', '    private static func documentVersion(',
    '    private func pullDocVersionedResult(', '    private func pullDocVersionedRetrying(',
    '    private func pushSyncDocAt(', '    private func commitNativePulledDocument(', '    func syncDown('];
  let combined = await readFile('app/Tests/AppleSyncReceivePublicationPeer.swift', 'utf8');
  combined += '\nextension VortXSyncManager {\n'
    + ['    private enum VersionedPull ', '    private enum PushOutcome ', '    private struct PendingDebridApply:',
      '    private enum ProviderApplyService:', '    private enum ProviderApplyValue:', '    private struct PendingProviderApply:']
      .map(marker => member(manager, marker)).join('\n')
    + '\n' + managerMethods.map(marker => member(manager, marker)).join('\n')
    + '\n    func uploadForFixture(_ document: [String: Any], version: Int) async -> Bool { if case .accepted = await pushSyncDocAt(document, version: version) { return true }; return false }\n}\n';
  const coreMembers = ['    func hasCertifiedNativeSession(', '    func captureNativePlaybackTarget(',
    '    func nativePlaybackTargetIsCurrent(', '    private func currentNativePlaybackBinding(',
    '    private func nativePlaybackBinding(', '    func mergeNativeAccountDocument(', '    private func refreshNativeProfiles(',
    '    @MainActor func nativeWatchlist()', '    private var enginePublicationBlocked:', '    private func capturePublicationToken()',
    '    private func publicationStillCurrent(', '    private func publicationEpochMatches(',
    '    func stateData(_ field:', '    func decode<T:', '    private func playerActiveSnapshot()', '    private func recordAcceptedHistoryReceipt('];
  combined += '\nextension CoreBridge {\n' + coreMembers.map(marker => member(core, marker)).join('\n')
    + '\n' + slice(core, '    static let decoder:', '\n    }()', true)
    + '\n' + slice(core, '    func rebuildContinueWatching()', '\n    /// Record an owner-tagged history receipt')
    + '\n    @MainActor func refreshProfilesForFixture() throws { try refreshNativeProfiles() }\n'
    + '    func handleHistoryFields(_ fields: [String]) {\n'
    + '        let data = try! JSONSerialization.data(withJSONObject: ["name": "NewState", "args": fields])\n'
    + '        handleEvent(data)\n    }\n'
    + slice(core, '    fileprivate func handleEvent(_ data: Data) {', '\n        // Legacy authKey migration')
    + '\n' + slice(core, '        if fields.contains("continue_watching_preview") {', '\n        // The board needs ctx')
    + '\n' + slice(core, '        if fields.contains("library") {', '\n            // AddToLibrary / RemoveFromLibrary dispatch emits')
    + '\n        }\n' + slice(core, '        // `changedFields` is written unconditionally', '\n    // MARK: meta_details coalesce + diff')
    + '\n}\n';
  combined += '\nextension PlaybackMutationTarget {\n'
    + slice(target, '    static func capture(core: CoreBridge)', '\n    func stillOwnsAccountContext(') + '\n}\n';
  // Full typed projection declarations; unrelated player/source models are excluded.
  await writeFile(join(output, 'Models.swift'), slice(models, 'import Foundation', '// MARK: Continue-Watching exact-source resume')
    + slice(models, 'struct CoreLibrary:', '// MARK: round-trippable requests')
    + slice(models, 'struct CoreLibraryRequest:', '// MARK: - VortX account-owned add-on'));
  await writeFile(join(output, 'UserProfile.swift'), slice(profiles, 'import Foundation', '/// The profile roster and the active selection.'));
  await writeFile(join(output, 'Discovery.swift'), 'import Foundation\n' + slice(discovery, 'struct ProfileDiscoveryPreferences:', '\n/// The one persistence bridge'));
  await writeFile(join(output, 'Combined.swift'), combined);
  await writeFile(join(output, 'extraction.json'), JSON.stringify({ sourceHEAD: process.env.VORTX_RECEIVE_SOURCE_HEAD, receipts,
    boundaries: ['Synthetic keys and owned encrypted checkpoint directories', 'Loopback HTTP request environment',
      'ProfileStore presentation sink and flat local CW choice', 'No provider, legacy migration or open-detail refresh exercised'],
    combinedSHA256: sha256(combined) }, null, 2));
  process.exit(0);
}

const [binary, root] = process.argv.slice(2);
const run = promisify(execFile);
let stored = null;
const wire = [];
const server = createServer(async (req, res) => {
  assert.equal(req.url, '/v1/backup'); assert.equal(req.headers.authorization, 'Bearer synthetic-fixture-only');
  res.setHeader('content-type', 'application/json');
  if (req.method === 'GET') {
    wire.push({ method: 'GET', version: stored?.version });
    res.statusCode = stored ? 200 : 404; res.end(JSON.stringify(stored ?? {})); return;
  }
  assert.equal(req.method, 'PUT');
  let bytes = ''; for await (const part of req) bytes += part;
  const body = JSON.parse(bytes);
  assert.deepEqual(Object.keys(body).sort(), ['document', 'version']);
  assert(body.document.startsWith('v2.')); assert.equal(body.version, 1);
  const accepted = !stored || body.version > stored.version;
  if (accepted) stored = body;
  wire.push({ method: 'PUT', accepted, version: stored.version });
  res.end(JSON.stringify({ accepted, version: stored.version }));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const baseURL = `http://127.0.0.1:${server.address().port}`;
async function peer(name, mode) {
  const directory = join(root, name); await mkdir(directory);
  const command = join(root, `${name}.json`); await writeFile(command, JSON.stringify({ mode, directory, baseURL }));
  const { stdout } = await run(binary, [command], { maxBuffer: 8 * 1024 * 1024 });
  const result = JSON.parse(stdout); await writeFile(join(root, `${name}-result.json`), JSON.stringify(result, null, 2)); return result;
}
let checks = 0;
function check(condition, label) { assert(condition, label); checks++; console.log(`PASS ${label}`); }
try {
  const upload = await peer('peer-a', 'upload');
  check(upload.accepted && upload.stamped === 1 && upload.version === 1, 'actual encrypted uploader acknowledges exact peer-A document revision');
  const received = await peer('peer-b', 'receive');
  check(received.profileID === '10000000-0000-0000-0000-000000000041', 'real profile projection preserves active owner UUID');
  check(received.receivedViewer === 'Received Viewer' && received.accountGenerationAdvanced && received.accountGenerationCertified,
    'actual bridge refresh publishes remote roster and certifies advanced facade account generation');
  check(received.library.includes('tt-receive-fixture'), 'actual NewState main-queue publication exposes received Library title');
  check(received.watchlist.includes('tt-receive-fixture'), 'actual bridge/native-host projection exposes received profile Watchlist membership');
  check(received.watchlistAddedAt === 200.5, 'received Watchlist preserves fractional membership timestamp');
  check(received.cw.includes('tt-receive-fixture'), 'actual CW publication exposes received in-progress title');
  check(received.selectionCurrent && received.selection.length === 1, 'real Home selector accepts published owner-bound local CW state');
  check(received.selection[0].id === 'tt-receive-fixture' && received.selection[0].type === 'series'
    && received.selection[0].videoId === 'tt-receive-fixture:1:7', 'Home selection retains exact title/type/episode identity');
  check(received.selection[0].offset === 234000 && received.selection[0].duration === 1200000, 'Home selection retains exact native progress milliseconds');
  check(received.version === 1 && received.stamped === 1 && received.hasApplied && received.outcome === 'completed', 'actual syncDown acknowledges version and success only after committed native document');
  check(received.historyReceipts >= 2, 'actual accepted library/CW history receipt functions ran');
  check(received.revision > 0 && received.changedFields.includes('library') && received.changedFields.includes('continue_watching_preview'), 'actual NewState common tail publishes history changed fields and revision');
  check(received.staleLibraryRejected && received.staleCWRejected && received.staleReceiptRejected, 'late main-queue library/CW/receipt callbacks reject changed credential owner');
  check(received.staleSelectionRejected, 'captured Home intent rejects changed credential owner');
  check(wire.length === 2 && wire[0].method === 'PUT' && wire[1].method === 'GET', 'receive uses one ordinary encrypted relay upload and one actual manager GET');
  await writeFile(join(root, 'receipt.json'), JSON.stringify({ result: 'PASS', checks, wire, upload, received,
    binarySHA256: sha256(await readFile(binary)), limits: ['macOS static C ABI and extracted Apple source',
      'ProfileStore sink is synthetic; settings/provider/legacy migration/detail paths and physical Apple devices are outside this proof'] }, null, 2));
  console.log(`PASS ${checks} actual receive/publication assertions; retained ${root}`);
} finally { await new Promise(resolve => server.close(resolve)); }
