import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createServer } from 'node:http';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const run = promisify(execFile);
const hash = value => createHash('sha256').update(value).digest('hex');
if (process.argv[2] === '--extract') {
  const output = process.argv[3];
  await mkdir(output, { recursive: true });
  await run(process.execPath, ['test/apple-sync-receive-publication.mjs', '--extract', output]);
  const productionMatches = [];
  async function production(path) {
    const value = await readFile(path, 'utf8');
    const ref = process.env.VORTX_RECEIVE_PRODUCTION_REF;
    assert(ref, 'exact production ref required');
    const { stdout } = await run('git', ['show', `${ref}:${path}`], { maxBuffer: 16 * 1024 * 1024 });
    assert.equal(hash(value), hash(stdout), `production changed: ${path}`);
    productionMatches.push({ path, ref, SHA256: hash(value) }); return value;
  }
  const source = await production('app/SourcesShared/VortXSyncManager.swift');
  const fixture = await readFile('app/Tests/NativeCausalRepairHarness.swift.in', 'utf8');
  const receipts = [];
  function member(text, path, marker) {
    let start = text.indexOf(marker); assert(start >= 0, `missing ${marker}`);
    const markerStart = start;
    assert.equal(text.indexOf(marker, start + marker.length), -1, `ambiguous ${marker}`);
    while (start > 0) {
      const prior = text.lastIndexOf('\n', start - 2) + 1;
      if (!text.slice(prior, start).trim().startsWith('@')) break;
      start = prior;
    }
    const lineEnd = text.indexOf('\n', markerStart);
    const end = text.slice(markerStart, lineEnd).trimEnd().endsWith('}') ? lineEnd : text.indexOf('\n    }', markerStart) + 6;
    assert(end > markerStart, `unterminated ${marker}`);
    const result = text.slice(start, end);
    receipts.push({ path, marker, firstLine: text.slice(0, start).split('\n').length, sourceSHA256: hash(text), sliceSHA256: hash(result) });
    return result;
  }
  function section(name) {
    return fixture.slice(fixture.indexOf(`// BEGIN ${name}\n`) + `// BEGIN ${name}\n`.length, fixture.indexOf(`// END ${name}`));
  }
  let combined = await readFile(join(output, 'Combined.swift'), 'utf8');
  await writeFile(join(output, 'ReceiveBase.swift.txt'), combined);
  const priorCombinedSHA256 = hash(combined);
  const transformations = [];
  function replace(before, after) {
    assert.equal(combined.split(before).length, 2, `fixture seam not unique: ${before}`);
    combined = combined.replace(before, after); transformations.push({ beforeSHA256: hash(before), afterSHA256: hash(after) });
  }
  replace('    private var values: [String: Any] = [:]', '    private var values: [String: Any] = [:]\n' + section('DEFAULTS ENVIRONMENT'));
  replace('    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }',
    '    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value }; DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) } }');
  replace('    var cwItems: [CoreCWItem] = []', '    var cwItems: [CoreCWItem] = []\n' + section('PROFILE ENVIRONMENT'));
  replace('        ProfileDiscoveryPreferencesStore.apply(active?.discovery, resetUnset: true)',
    '        VortXSyncManager.suppressHousekeeping { ProfileDiscoveryPreferencesStore.apply(self.active?.discovery, resetUnset: true) }');
  replace('    var isSignedIn = true; var hasAppliedAccountDoc = false; var hasPendingPush = false',
    '    var isSignedIn = true; var hasAppliedAccountDoc = false\n' + section('MANAGER ENVIRONMENT'));
  replace('    var dirtySettings: [String: Double] = [:]; var appliedSettingsBaseline: Set<String> = []', '    var appliedSettingsBaseline: Set<String> = []');
  const remove = [
    '    func withRemoteApplySuppressed(_ body: () -> Void) { body() }',
    '    func nativeMutationDidCommit(credentialCapture: CredentialScopeRegistry.Capture) { hasPendingPush = true }',
    '    func mergedNativeProviderState(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { try nativeProviderState(capture: capture) }',
    '    func persistMergedNativeProviders(_ providers: VortxNativeProviderCredentials, capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { providers }',
    '    func mirrorNativeProviderKeys(_ providers: VortxNativeProviderCredentials, original: Any?) throws -> [String: Any] { [:] }',
    '    func acknowledgeNativeProviders(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) throws {}',
    '    func ensureNativeCheckpoint(credentialCapture: CredentialScopeRegistry.Capture) async -> Bool { CoreBridge.shared.hasCertifiedNativeSession(capture: credentialCapture, profileID: ProfileStore.shared.activeID) }'
  ];
  remove.forEach(value => replace(value, ''));
  replace('    func nativeProviderState(capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials {\n        try VortxNativeProviderCredentials(scope: capture.namespace, actor: AppleSyncReceivePublicationPeer.actor)\n    }',
    '    func nativeProviderState(capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials {\n        if let fixtureProviderState { return fixtureProviderState }; return try VortxNativeProviderCredentials(scope: capture.namespace, actor: AppleSyncReceivePublicationPeer.actor)\n    }');
  const keychain = await production('app/SourcesShared/Keychain.swift');
  const keychainPrefix = marker => {
    const start = keychain.indexOf(marker); assert(start >= 0); const end = keychain.indexOf('\n', start);
    const selected = keychain.slice(start, end);
    receipts.push({ path: 'app/SourcesShared/Keychain.swift', marker, sourceSHA256: hash(keychain), sliceSHA256: hash(selected) }); return selected;
  };
  replace('enum Keychain {', 'enum Keychain {\n' + keychainPrefix('    static let fallbackKeyPrefix =') + '\n' + keychainPrefix('    static let invalidationKeyPrefix ='));
  replace('@main @MainActor enum AppleSyncReceivePublicationPeer {', '@MainActor enum AppleSyncReceivePublicationPeer {');
  replace('"pendingPush": manager.hasPendingPush', '"pendingPush": manager.fixtureState()["pending"]!');
  const markers = [
    '    private func dirtySettingsKey(', '    private var dirtySettings:', '    private var nativeDurablePushPending:', '    private var hasPendingPush:',
    '    private func currentSyncableDomain(', '    private func refreshSettingsShadow(', '    private func noteLocalSettingsChange(',
    '    private func observeDefaultsChange(', '    func nativeMutationDidCommit(', '    private func drainNativeMutationPush(', '    private func drainLocalRosterPush(',
    '    func withRemoteApplySuppressed(', '    nonisolated static func suppressHousekeeping(', '    func requestSyncSoon(',
    '    private func nativeGlobalEdits(', '    private func nativeDirtySettingIsExported(', '    private func nativePreferenceStampIsAttributed(',
    '    private func clearPushedDirtySettings(', '    func syncUp(', '    private func finishSyncUp(', '    private func mergeLocalIntoDoc(',
    '    private func pushDerivedDoc(', '    private struct DerivedSyncDoc {', '    private func ensureNativeCheckpoint(',
    '    private struct NativePreferenceContext {', '    private func nativePreferenceContext(', '    nonisolated private static func makeNativePreferenceContext(',
    '    nonisolated private static func nativePreferenceValue(', '    nonisolated private static func nativePreferenceSnapshot(',
    '    func finishNativePreferenceIntents(', '    private func pendingNativePreferenceReceipts(', '    private func acknowledgeNativePreferenceCloud(',
    '    private func replayNativePreferenceIntents(', '    private func mergedNativeProviderState(', '    private func mirrorNativeProviderKeys(',
    '    private func acknowledgeNativeProviders(', '    private func persistMergedNativeProviders('
  ];
  combined += '\nextension VortXSyncManager {\n' + markers.map(marker => member(source, 'app/SourcesShared/VortXSyncManager.swift', marker)).join('\n') + '\n}\n';
  const core = await production('app/SourcesShared/CoreBridge.swift');
  combined += '\nextension CoreBridge {\n' + member(core, 'app/SourcesShared/CoreBridge.swift', '    func settleResidentNativeSession(')
    + '\n' + member(core, 'app/SourcesShared/CoreBridge.swift', '    var nativeRegistryBinding:') + '\n}\n';
  const backup = await production('app/SourcesShared/SettingsBackup.swift');
  const start = backup.indexOf('    private static let skipPrefixes =');
  const end = backup.indexOf('\n    }', backup.indexOf('    static func migratedKey(')) + 6;
  const filters = backup.slice(start, end);
  receipts.push({ path: 'app/SourcesShared/SettingsBackup.swift', marker: 'syncable filters through migratedKey', sourceSHA256: hash(backup), sliceSHA256: hash(filters) });
  combined += '\nextension SettingsBackup {\n' + filters + '\n}\n';
  const observerStart = source.indexOf('        refreshSettingsShadow()\n        NotificationCenter.default.addObserver');
  const observerEnd = source.indexOf('\n        // T-2:', observerStart);
  assert(observerStart >= 0 && observerEnd > observerStart);
  const observer = source.slice(observerStart, observerEnd);
  replace('    func fixtureBaseline() { refreshSettingsShadow() }', '    func fixtureBaseline() {\n' + observer + '\n    }');
  receipts.push({ path: 'app/SourcesShared/VortXSyncManager.swift', marker: 'actual defaults observer registration', sourceSHA256: hash(source), sliceSHA256: hash(observer) });
  combined += '\n' + fixture.slice(fixture.indexOf('@main @MainActor enum NativeCausalRepairPeer'));
  await writeFile(join(output, 'Combined.swift'), combined);
  const originalBytes = await readFile(join(output, 'extraction.json'));
  const original = JSON.parse(originalBytes);
  await writeFile(join(output, 'causal-extraction.json'), JSON.stringify({ sourceHEAD: original.sourceHEAD, priorExtractionSHA256: hash(originalBytes), priorCombinedSHA256, priorCombinedPath: 'ReceiveBase.swift.txt', receipts, productionMatches,
    transformations, fixtureSHA256: hash(fixture), combinedSHA256: hash(combined),
    excluded: ['Profile preference edits and selection: empty real journal; sink retry/save fail on nonempty preference inputs',
      'Provider authentication: empty state, inert storage; real carrier merge/mirror/ACK', 'Cold/empty-account restoration',
      'Real Foundation UserDefaults notification timing and process-death persistence', 'Realtime socket/startup lifecycle, providers, devices, installed applications'] }, null, 2));
  process.exit(0);
}

const [binary, root] = process.argv.slice(2);
const SeedOwner = '10000000-0000-0000-0000-000000000041';
const SeedAddonA = 'https://synthetic.invalid/a/manifest.json';
let stored = null; let behavior = 'normal'; let held = null;
const wire = []; const events = []; let checks = 0;
const server = createServer(async (req, res) => {
  try {
    assert.equal(req.url, '/v1/backup'); assert.equal(req.headers.authorization, 'Bearer synthetic-fixture-only');
    res.setHeader('content-type', 'application/json');
    if (req.method === 'GET') {
      wire.push({ method: 'GET', version: stored?.version }); res.statusCode = stored ? 200 : 404;
      res.end(JSON.stringify(stored ?? {})); return;
    }
    assert.equal(req.method, 'PUT');
    let raw = ''; for await (const part of req) raw += part;
    const body = JSON.parse(raw); assert.deepEqual(Object.keys(body).sort(), ['document', 'version']);
    assert(body.document.startsWith('v2.')); assert(Number.isSafeInteger(body.version));
    const record = { method: 'PUT', proposed: body.version, behavior }; wire.push(record);
    if (behavior === 'missing-ack') { behavior = 'normal'; record.accepted = false; res.end(JSON.stringify({ version: stored.version })); return; }
    if (behavior === 'hold-conflict' || behavior === 'hold-ack') {
      const mode = behavior; behavior = 'normal'; held = { body, res, record, mode };
      if (mode === 'hold-ack') { assert(body.version > stored.version); stored = body; }
      return;
    }
    const accepted = !stored || body.version > stored.version;
    if (accepted) stored = body;
    record.accepted = accepted; record.stored = stored.version;
    res.end(JSON.stringify({ accepted, version: stored.version }));
  } catch (error) { events.push({ relayError: String(error) }); res.statusCode = 500; res.end('{}'); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const baseURL = `http://127.0.0.1:${server.address().port}`;
function check(value, label) { assert(value, label); checks++; console.log(`PASS ${label}`); }
async function until(predicate, label, milliseconds = 12_000) {
  const deadline = Date.now() + milliseconds;
  while (!predicate()) { assert(Date.now() < deadline, label); await new Promise(resolve => setTimeout(resolve, 25)); }
}
async function upload(stage, version, sibling = 'synthetic') {
  const directory = join(root, 'peer-a'); await mkdir(directory, { recursive: true });
  const path = join(root, `upload-${version}.json`); await writeFile(path, JSON.stringify({ mode: 'upload', directory, baseURL, stage, version, sibling }));
  const { stdout, stderr } = await run(binary, [path], { timeout: 45_000, maxBuffer: 4 * 1024 * 1024 });
  await writeFile(join(root, `upload-${version}.log`), stderr); const result = JSON.parse(stdout);
  events.push({ upload: result }); assert(result.accepted); return result;
}
async function receiver(name) {
  const directory = join(root, name); await mkdir(directory, { recursive: true });
  const path = join(root, `${name}.json`); await writeFile(path, JSON.stringify({ mode: 'receive', directory, baseURL }));
  const child = spawn(binary, [path], { stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = []; const waiters = []; let error = null; let stderr = '';
  createInterface({ input: child.stdout }).on('line', line => { const value = JSON.parse(line); const waiter = waiters.shift(); if (waiter) waiter(value); else lines.push(value); });
  child.stderr.on('data', value => { stderr += value; });
  const done = new Promise((resolve, reject) => { child.on('error', reject); child.on('exit', async code => {
    await writeFile(join(root, `${name}.log`), stderr);
    if (code === 0) resolve(); else { error = new Error(`${name} exited ${code}: ${stderr}`); reject(error); }
  }); });
  done.catch(() => {});
  async function next() {
    if (error) throw error; if (lines.length) return lines.shift(); let timer;
    try { return await Promise.race([new Promise(resolve => waiters.push(resolve)), done.then(() => { throw new Error(`${name} ended early`); }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${name} response timeout: ${stderr}`)), 20_000); })]); }
    finally { clearTimeout(timer); }
  }
  let ready;
  try { ready = await next(); assert(ready.ready); }
  catch (error) { child.kill(); await done.catch(() => {}); throw error; }
  events.push({ name, ready });
  return { async send(action, milliseconds) { child.stdin.write(JSON.stringify({ action, milliseconds }) + '\n'); const result = await next(); events.push({ name, action, result }); return result; },
    async close() { child.stdin.end('{"action":"close"}\n'); await done; }, async abort() { child.kill(); await done.catch(() => {}); } };
}
function release(accepted, echoedVersion = stored.version) {
  assert(held); held.record.accepted = accepted; held.record.stored = stored.version;
  held.res.end(JSON.stringify({ accepted, version: echoedVersion })); held = null;
}
let b; let c;
try {
  await upload(1, 1);
  b = await receiver('peer-b');
  for (const stage of [1, 2, 3]) {
    if (stage > 1) await upload(stage, stage);
    const value = await b.send('pull'); check(value.outcome === 'completed' && value.version === stage, `actual receive accepts revision ${stage}`);
    check(value.dirty.length === 0, `remote projection at revision ${stage} does not dirty syncable preferences`);
    if (value.pending) await b.send('wait', 2800);
  }
  const quiet = await b.send('snapshot');
  check(!quiet.pending && !quiet.worker, 'normal received state settles without an observer echo worker');
  const count = wire.length; await b.send('observe'); await b.send('wait', 100);
  check(wire.length === count, 'real observer no-delta notification does not create transport activity');
  await upload(4, 4, 'stale-carrier'); behavior = 'missing-ack';
  const stale = await b.send('pull');
  check(stale.version === 4 && stale.pending && stale.durable, 'stale receive admits durable automatic causal repair');
  check(stale.selection.some(item => item.videoId === 'tt-receive-fixture:1:8' && item.offset === 345000), 'stale receive retains newer exact episode progress');
  await until(() => wire.some(item => item.behavior === 'missing-ack'), 'scheduled repair never uploaded');
  const failed = await b.send('wait', 100);
  check(failed.version === 4 && failed.stamped === stale.stamped && failed.pending && failed.durable && !failed.worker, 'invalid ACK leaves repair pending, success unstamped and background worker retires');
  const beforeRetry = wire.length; await b.send('wait', 2750);
  check(wire.length === beforeRetry, 'backgrounded failed upload waits for a new trigger');
  behavior = 'hold-conflict'; await b.send('foreground');
  await until(() => held?.mode === 'hold-conflict', 'foreground retry never uploaded');
  check(held.body.version === 5, 'automatic worker proposes freshly pulled base revision plus one');
  await upload(4, 5, 'concurrent-winner'); release(false, 999999);
  behavior = 'hold-ack';
  await until(() => held?.mode === 'hold-ack', 'conflict retry never rebuilt');
  check(held.body.version === 6, 'conflict retry re-pulls winner and ignores spoofed echoed revision');
  const oldGeneration = (await b.send('snapshot')).generation;
  const local = await b.send('progress');
  check(local.generation > oldGeneration && local.pending && local.durable, 'real native late progress admits a newer queue generation during held PUT');
  release(true);
  const olderACK = await b.send('wait', 100);
  check(olderACK.version === 6 && olderACK.pending && olderACK.durable, 'older accepted ACK cannot clear newer native pending generation');
  await until(() => stored.version === 7, 'newer generation never uploaded');
  const healed = await b.send('wait', 100);
  check(!healed.pending && !healed.durable && !healed.worker && healed.version === 7, 'newest accepted generation clears queue and durable pending');
  c = await receiver('peer-c'); const received = await c.send('pull');
  check(received.version === 7 && received.selection.some(item => item.videoId === 'tt-receive-fixture:1:9' && item.offset === 444000), 'fresh encrypted FFI peer receives repaired newest exact progress');
  check(!received.native.nativeSync.addons[SeedOwner]?.records?.[SeedAddonA]?.removedAt ? false : true, 'fresh peer retains native add-on tombstone');
  const full = await c.send('document');
  check(full.document.causalFixtureSibling.owner === 'concurrent-winner' && full.document.causalFixtureSibling.preserve.join() === '1,2,3',
    'repair preserves freshly pulled concurrent winner foreign sibling');
  check(full.document.apiKeys.unrelatedFixtureField === 'retained-synthetic', 'actual provider mirror retains unrelated authenticated API-key sibling');
  await c.close(); c = null;
  behavior = 'hold-ack'; await b.send('trigger');
  await until(() => held?.mode === 'hold-ack', 'ABA control upload never started');
  const prior = await b.send('snapshot'); const wrong = await b.send('wrong-owner');
  check(wrong.generation === prior.generation, 'wrong credential binding cannot admit another mutation generation');
  const retired = await b.send('aba'); release(true);
  const late = await b.send('wait', 100);
  check(late.credential === prior.credential + 2 && late.version === 7 && late.stamped === prior.stamped && late.pending && late.durable && late.generation === retired.generation,
    'late ACK from retired ABA capture cannot stamp current version or clear new pending generation');
  await until(() => stored.version === 9, 'fresh ABA worker never healed current state');
  const current = await b.send('wait', 100);
  check(current.version === 9 && !current.pending && !current.durable, 'current credential generation alone clears its accepted upload');
  const suppressed = await b.send('suppressed');
  check(suppressed.changedDomain && suppressed.waitedDuringSuppression && !suppressed.deferred && !suppressed.suppressed && suppressed.generation === suppressed.beforeGeneration + 2,
    'real suppression retains one receipt and drains one worker admission after re-baselining');
  const observed = await b.send('observe');
  check(observed.generation === suppressed.generation && observed.dirty.length === 0, 'suppressed remote write never becomes a new observer echo admission');
  await until(() => stored.version === 10, 'suppressed admission never uploaded');
  const final = await b.send('wait', 100);
  check(!final.pending && !final.durable && final.version === 10, 'deferred suppressed admission receives accepted ACK and settles');
  check(events.every(event => !event.relayError), 'all HTTP operations stayed inside declared owned loopback contract');
  await b.close(); b = null;
  console.log(`PASS ${checks} actual causal-repair checks`);
} finally {
  if (held) { held.res.destroy(); held = null; }
  await b?.abort(); await c?.abort(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  await writeFile(join(root, 'causal-runtime-receipt.json'), JSON.stringify({ checks, wire, events,
    boundary: 'Actual extracted manager scheduler/suppression/observer/repair/upload/fresh-base retry/ACK and native merge/publication; real encrypted persistent native FFI peers. Synthetic RAM defaults and notification delivery, credential generations, owned loopback relay, empty real preference journal/provider state. No installed app, Foundation timing, process-death durability, socket/startup lifecycle, profile selection, providers or devices.' }, null, 2));
}
