import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createServer } from 'node:http';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const sha256 = value => createHash('sha256').update(value).digest('hex');
if (process.argv[2] === '--extract') {
  const output = process.argv[3];
  await mkdir(output, { recursive: true });
  const receipts = [];
  const productionMatches = [];
  async function source(path) {
    const text = await readFile(path, 'utf8');
    if (process.env.VORTX_RECEIVE_PRODUCTION_REF) {
      const { stdout } = await promisify(execFile)('git', ['show', `${process.env.VORTX_RECEIVE_PRODUCTION_REF}:${path}`], { maxBuffer: 16 * 1024 * 1024 });
      assert.equal(sha256(text), sha256(stdout), `production source differs from requested ref: ${path}`);
      productionMatches.push({ path, SHA256: sha256(text), ref: process.env.VORTX_RECEIVE_PRODUCTION_REF });
    }
    return { path, text };
  }
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
  const [manager, core, profiles, discovery, models, target, catalog, home] = await Promise.all([
    source('app/SourcesShared/VortXSyncManager.swift'), source('app/SourcesShared/CoreBridge.swift'),
    source('app/SourcesShared/Profiles.swift'), source('app/SourcesShared/ProfileDiscoveryPreferences.swift'),
    source('app/SourcesShared/CoreModels.swift'), source('app/SourcesShared/StremioAccount.swift'),
    source('app/SourcesShared/CatalogPreferences.swift'), source('app/SourcesShared/HomeRailPreferences.swift')]);
  const managerMethods = ['    private static func sawDocV2(', '    private static func markSawDocV2(',
    '    private func openSyncDocument(', '    private static func decodeDecryptedSyncDocument(', '    private static func documentVersion(',
    '    private func pullDocVersionedResult(', '    private func pullDocVersionedRetrying(',
    '    private func pushSyncDocAt(', '    private func commitNativePulledDocument(', '    private func applyNativeGlobals(',
    '    static func ownedAddons(', '    func syncDown('];
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
    '    func stateData(_ field:', '    func decode<T:', '    private func playerActiveSnapshot()', '    private func recordAcceptedHistoryReceipt(',
    '    private func refreshAddons()', '    private func refreshAddons(capturedPublicationToken',
    '    func hydrateAddonsFromAccount(', '    private func addonMutationStillAllowed(',
    '    private func ensureCatalogOrderRangeLoaded(', '    private func widenBoardRange('];
  combined += '\nextension CoreBridge {\n' + coreMembers.map(marker => member(core, marker)).join('\n')
    + '\n' + slice(core, '    static let decoder:', '\n    }()', true)
    + '\n' + slice(core, '    func rebuildContinueWatching()', '\n    /// Record an owner-tagged history receipt')
    + '\n    @MainActor func refreshProfilesForFixture() throws { try refreshNativeProfiles() }\n'
    + '    func handleHistoryFields(_ fields: [String]) {\n'
    + '        let data = try! JSONSerialization.data(withJSONObject: ["name": "NewState", "args": fields])\n'
    + '        handleEvent(data)\n    }\n'
    + slice(core, '    fileprivate func handleEvent(_ data: Data) {', '\n        // Legacy authKey migration')
    + '\n' + slice(core, '        if fields.contains("continue_watching_preview") {', '\n        // The board needs ctx')
    + '\n' + slice(core, '        if fields.contains("ctx") {\n            VXProbe.log("engine", "ctx/settings changed', '\n            // MID-SEARCH RE-PLAN')
    + '\n        }\n'
    + '\n' + slice(core, '        if fields.contains("library") {', '\n            // AddToLibrary / RemoveFromLibrary dispatch emits')
    + '\n        }\n' + slice(core, '        // `changedFields` is written unconditionally', '\n    // MARK: meta_details coalesce + diff')
    + '\n}\n';
  combined += '\nextension PlaybackMutationTarget {\n'
    + slice(target, '    static func capture(core: CoreBridge)', '\n    func stillOwnsAccountContext(') + '\n}\n';
  // Full typed projection declarations; unrelated player/source models are excluded.
  await writeFile(join(output, 'Models.swift'), slice(models, 'import Foundation', '// MARK: Continue-Watching exact-source resume')
    + slice(models, 'struct CoreLibrary:', '// MARK: round-trippable requests')
    + slice(models, 'struct CoreLibraryRequest:', '// MARK: - VortX account-owned add-on')
    + slice(models, 'struct CoreCtx:', '// MARK: assembled UI row')
    + slice(models, 'struct VortXOwnedAddon {', '// MARK: - Stremio mirror settings'));
  await writeFile(join(output, 'UserProfile.swift'), slice(profiles, 'import Foundation', '/// The profile roster and the active selection.'));
  receipts.push({ path: discovery.path, marker: 'entire Foundation-only discovery persistence bridge', sourceSHA256: sha256(discovery.text), sliceSHA256: sha256(discovery.text) });
  await writeFile(join(output, 'Discovery.swift'), discovery.text);
  const catalogMethods = ['    static func hidden() ', '    static func order() ', '    static func isHidden(', '    static func rank(', '    static func homeLayout()'];
  await writeFile(join(output, 'CatalogConsumers.swift'), 'import Foundation\n'
    + slice(catalog, 'enum HomeLayoutPreset:', '\n/// A Discover HUB category')
    + '\nenum CatalogPrefsStore {\n'
    + slice(catalog, '    static let homeLayoutKey =', '\n') + '\n'
    + catalogMethods.map(marker => member(catalog, marker)).join('\n') + '\n}\n');
  receipts.push({ path: home.path, marker: 'entire Home rail preference consumer', sourceSHA256: sha256(home.text), sliceSHA256: sha256(home.text) });
  await writeFile(join(output, 'HomeRails.swift'), home.text);
  await writeFile(join(output, 'Combined.swift'), combined);
  await writeFile(join(output, 'extraction.json'), JSON.stringify({ sourceHEAD: process.env.VORTX_RECEIVE_SOURCE_HEAD, receipts, productionMatches,
    boundaries: ['Synthetic keys and owned encrypted checkpoint directories', 'Loopback HTTP request environment',
      'ProfileStore presentation sink invokes actual discovery apply; quarantine/admission and UI board rendering are not exercised',
      'No provider, legacy migration or open-detail refresh exercised'],
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
  assert(body.document.startsWith('v2.')); assert(Number.isSafeInteger(body.version) && body.version > 0);
  const accepted = !stored || body.version > stored.version;
  if (accepted) stored = body;
  wire.push({ method: 'PUT', accepted, version: stored.version });
  res.end(JSON.stringify({ accepted, version: stored.version }));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const baseURL = `http://127.0.0.1:${server.address().port}`;
async function peer(name, mode, extra = {}, directoryName = name) {
  const directory = join(root, directoryName); await mkdir(directory, { recursive: true });
  const command = join(root, `${name}.json`); await writeFile(command, JSON.stringify({ mode, directory, baseURL, ...extra }));
  const { stdout } = await run(binary, [command], { maxBuffer: 8 * 1024 * 1024, timeout: 45_000 });
  const result = JSON.parse(stdout); await writeFile(join(root, `${name}-result.json`), JSON.stringify(result, null, 2)); return result;
}
async function warmReceiver() {
  const directory = join(root, 'sequence-b'); await mkdir(directory);
  const command = join(root, 'sequence-b.json'); await writeFile(command, JSON.stringify({ mode: 'receive-sequence', directory, baseURL }));
  const child = spawn(binary, [command], { stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = []; const waiters = []; let failure = null; let stderr = '';
  const reader = createInterface({ input: child.stdout });
  reader.on('line', line => { const resolve = waiters.shift(); if (resolve) resolve(JSON.parse(line)); else lines.push(JSON.parse(line)); });
  child.stderr.on('data', value => { stderr += value; });
  const finished = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', code => {
      if (code === 0) resolve(); else { failure = new Error(`warm receiver exited ${code}: ${stderr}`); reject(failure); }
    });
  });
  // Attach immediately so a protocol failure does not leave a rejected promise unobserved.
  finished.catch(() => {});
  async function next() {
    if (failure) throw failure;
    if (lines.length) return lines.shift();
    let timer;
    try { return await Promise.race([new Promise(resolve => waiters.push(resolve)), finished.then(() => { throw new Error('receiver exited before response'); }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`receiver response timeout: ${stderr}`)), 45_000); })]); }
    finally { clearTimeout(timer); }
  }
  const ready = await next(); assert(ready.ready);
  return { ready, async send(instruction) { child.stdin.write(`${instruction}\n`); return next(); },
    async close() { child.stdin.end('close\n'); await finished; }, abort() { child.kill(); } };
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
  const baseline = { checks, wire: [...wire], upload, received };
  assert.equal(checks, 16, 'original acceptance case count must remain unchanged');
  stored = null; wire.length = 0;
  const urls = Object.fromEntries(['a', 'b', 'c', 'd'].map(id => [id, `https://synthetic.invalid/${id}/manifest.json`]));
  const row = url => url + '|movie|popular';
  const receiver = await warmReceiver();
  const revisions = [];
  let stale;
  try {
    for (const stage of [1, 2, 3, 4]) {
      const sent = await peer(`sequence-a-v${stage}`, 'upload-sequence', { stage, version: stage }, 'sequence-a');
      check(sent.accepted && sent.version === stage && sent.stamped === 1, `revision ${stage} acknowledged by actual encrypted uploader`);
      const pulled = await receiver.send('pull'); revisions.push(pulled);
      await writeFile(join(root, `sequence-b-v${stage}-result.json`), JSON.stringify(pulled, null, 2));
      check(pulled.version === stage && pulled.certified && pulled.hasApplied && pulled.outcome === 'completed', `revision ${stage} actual syncDown ACK follows certified native receive`);
      check(pulled.profileID === '10000000-0000-0000-0000-000000000041' && pulled.selectionCurrent,
        `revision ${stage} retains active owner and current Home selection`);
      if (stage === 1) {
        check(pulled.viewerName === 'Sequence Viewer' && pulled.viewerAvatar === '🐱', 'remote profile creation and host avatar publish on peer B');
        check(JSON.stringify(pulled.inventory) === JSON.stringify([urls.c, urls.a, urls.b]), 'remote native installed inventory uses intentional reorder rather than install order');
        check(JSON.stringify(pulled.addons) === JSON.stringify([urls.c, urls.a]) && pulled.rawAddons.length === 2, 'actual typed/raw add-on publication applies owner visibility without uninstalling hidden member');
        check(JSON.stringify(pulled.catalogOrder) === JSON.stringify([urls.c, urls.a, urls.b].map(row)) && pulled.catalogHidden[0] === row(urls.b), 'real discovery apply and catalog consumers expose received per-profile catalog order/hidden preferences');
        check(pulled.homeLayout === 'rails' && pulled.homeRails.slice(0, 2).join(',') === 'addonCatalogs,topPicks'
          && pulled.homeHidden.join(',') === 'collectionsHub', 'actual global apply reloads Home section order and hidden consumer');
      } else if (stage === 2) {
        check(!pulled.pendingPush, 'matching received carrier joins without requesting a causal-repair push');
        check(pulled.viewerName === 'Edited Viewer' && pulled.viewerAvatar === '🐯' && pulled.viewerKids
          && pulled.viewerDisabled.join(',') === urls.d, 'later remote profile native edits and host avatar converge exactly');
        check(JSON.stringify(pulled.inventory) === JSON.stringify([urls.d, urls.c, urls.b]) && pulled.removedAtPresent && pulled.removedClockDistinct,
          'new install survives and removed add-on retains a durable native removal clock');
        check(JSON.stringify(pulled.addons) === JSON.stringify([urls.d, urls.b]) && pulled.rawAddons.join(',') === [urls.b, urls.d].sort().join(','),
          'new remote order and visibility publish as one typed/raw receipt');
        check(pulled.library.includes('tt-receive-movie') && pulled.library.includes('tt-receive-fixture')
          && pulled.watchlist.join(',') === 'tt-receive-movie' && pulled.watchlistAddedAt[0] === 2000.75,
          'Library add and independent Watchlist remove/add registers converge without losing series history');
        check(pulled.selection.length === 1 && pulled.selection[0].id === 'tt-receive-fixture'
          && pulled.selection[0].videoId === 'tt-receive-fixture:1:7' && pulled.selection[0].offset === 678000,
          'newer peer-A progress is accepted exactly by idle refresh and real Home selector');
        check(pulled.homeLayout === 'wall' && pulled.catalogRanks[3] === 0 && pulled.catalogRanks[2] === 1,
          'newer global wall layout and exact catalog row ranks replace older preferences');
        const repeated = await receiver.send('pull'); revisions.push({ repeated });
        await writeFile(join(root, 'sequence-b-v2-repeated-result.json'), JSON.stringify(repeated, null, 2));
        check(repeated.version === 2 && repeated.stamped === pulled.stamped && repeated.outcome === 'completed' && !repeated.restored,
          'same-version actual syncDown acknowledges no-op without advancing success stamp');
        check(JSON.stringify(repeated.selection) === JSON.stringify(pulled.selection) && JSON.stringify(repeated.cw) === JSON.stringify(pulled.cw)
          && repeated.historyReceipts === pulled.historyReceipts && repeated.accountGeneration === pulled.accountGeneration,
          'same-version refresh does not erase CW/history receipt or move episode/account generation');
        check(JSON.stringify(repeated.addons) === JSON.stringify(pulled.addons) && JSON.stringify(repeated.watchlist) === JSON.stringify(pulled.watchlist),
          'same-version refresh retains add-on and Watchlist published state');
      } else {
        check(JSON.stringify(pulled.inventory) === JSON.stringify([urls.c, urls.d, urls.b]) && pulled.removedAtPresent
          && !pulled.inventory.includes(urls.a) && pulled.inventory.includes(urls.d), `revision ${stage} cannot resurrect removal or lose newer installed add-on`);
        check(JSON.stringify(pulled.addons) === JSON.stringify([urls.c, urls.d, urls.b]), `revision ${stage} retains latest intentional order and visible roster`);
        check(pulled.selection.length === 1 && pulled.selection[0].videoId === 'tt-receive-fixture:1:8'
          && pulled.selection[0].offset === 345000 && pulled.selection[0].duration === 1200000,
          `revision ${stage} retains newest exact episode/progress in actual Home selector`);
        check(!pulled.library.includes('tt-receive-movie') && pulled.library.includes('tt-receive-fixture')
          && pulled.watchlist.join(',') === 'tt-receive-fixture,tt-receive-movie', `revision ${stage} retains independent Library removal and both Watchlist memberships`);
        check(pulled.catalogHidden.join(',') === row(urls.d) && pulled.catalogRanks[2] === 0 && pulled.catalogRanks[3] === 1
          && pulled.homeLayout === 'rails' && pulled.homeHidden.join(',') === 'topPicks', `revision ${stage} retains newest profile and global catalog/Home layout`);
        if (stage === 4) check(pulled.pendingPush, 'newer relay revision carrying older native/host state arms actual causal repair after retained join');
      }
    }
    stale = await receiver.send('stale');
    await writeFile(join(root, 'sequence-b-stale-result.json'), JSON.stringify(stale, null, 2));
    check(stale.staleLibraryRejected && stale.staleCWRejected && stale.staleReceiptRejected && stale.staleAddonsRejected,
      'late actual library/CW/add-on publication rejects changed credential owner after all revisions');
    check(stale.staleSelectionRejected, 'late captured Home intent rejects changed owner after newest progress');
    check(revisions.filter(value => !value.repeated).every(value => value.installationActor === '00000000-0000-4000-8000-000000000042'
      && value.hostActor === '00000000-0000-4000-8000-000000000041'), 'persisted peer-B host actor stays distinct from actual received peer-A register actor');
    check(wire.filter(value => value.method === 'PUT').length === 4 && wire.filter(value => value.method === 'GET').length === 5,
      'revision sequence uses four ordinary encrypted uploads and five actual manager pulls');
    await receiver.close();
  } catch (error) { receiver.abort(); throw error; }
  const baselineChecks = baseline.checks;
  await writeFile(join(root, 'receipt.json'), JSON.stringify({ result: 'PASS', checks, baselineChecks, extendedChecks: checks - baselineChecks,
    baseline, wire, revisions, stale, receiverActor: receiver.ready.actor,
    binarySHA256: sha256(await readFile(binary)), limits: ['macOS static C ABI and extracted Apple source',
      'ProfileStore sink invokes actual discovery apply but excludes full dirty/quarantine admission and rendered catalog board resource content',
      'UserDefaults notifications and sync observer/self-echo suppression are not exercised by the RAM environment',
      'Stale carrier test proves retained join and queued causal-repair marker; automatic repair upload is not exercised',
      'Provider credentials, legacy migration, detail paths and physical Apple devices are outside this proof'] }, null, 2));
  console.log(`PASS ${checks} actual receive/publication assertions; retained ${root}`);
} finally { await new Promise(resolve => server.close(resolve)); }
