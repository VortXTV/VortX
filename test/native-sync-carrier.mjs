import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';

// Strict-newer BLIND relay contract, explicitly a model of the documented deployed predicate
// excluded.version > backups.version. No credentials, production account or provider is used.
const run = promisify(execFile);
const [swiftPeer, kotlinLauncher, outputRoot] = process.argv.slice(2);
assert(swiftPeer && kotlinLauncher && outputRoot, 'usage: node native-sync-carrier.mjs swift-peer kotlin-launcher output-root');
await mkdir(outputRoot, { recursive: true });
const fixtureRoot = await mkdtemp(join(outputRoot, 'carrier-fixture-'));
const digest = async path => createHash('sha256').update(await readFile(path)).digest('hex');
const sources = ['app/Tests/NativeSyncCarrierPeer.swift', 'android/app/src/test/kotlin/com/vortx/android/sync/NativeSyncCarrierPeer.kt',
  'test/native-sync-carrier.mjs', 'scripts/test-native-sync-carrier.sh', 'scripts/native-sync-kotlin-peer-inputs.sh'];
const sourceSHA256 = Object.fromEntries(await Promise.all(sources.map(async path => [path, await digest(path)])));
async function treeDigests(directory, prefix = '') {
  const result = {};
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relative = prefix + entry.name;
    if (entry.isDirectory()) Object.assign(result, await treeDigests(join(directory, entry.name), relative + '/'));
    else if (entry.isFile()) result[relative] = await digest(join(directory, entry.name));
  }
  return Object.fromEntries(Object.entries(result).sort(([a], [b]) => a.localeCompare(b)));
}
const owner = '10000000-0000-0000-0000-000000000001';
const viewer = '10000000-0000-0000-0000-000000000002';
let stored = null;
const wire = [];
const relay = createServer(async (request, response) => {
  assert.equal(request.url, '/v1/backup');
  assert.equal(request.headers.authorization, 'Bearer fixture-only');
  if (request.method === 'GET') {
    wire.push({ method: 'GET', version: stored?.version ?? null });
    response.writeHead(stored ? 200 : 404, { 'content-type': 'application/json' });
    response.end(JSON.stringify(stored ?? { error: 'no_backup' }));
    return;
  }
  assert.equal(request.method, 'PUT');
  let raw = ''; for await (const chunk of request) raw += chunk;
  const body = JSON.parse(raw);
  assert.deepEqual(Object.keys(body).sort(), ['document', 'version']);
  assert(Number.isSafeInteger(body.version) && body.version >= 0);
  assert.equal(typeof body.document, 'string'); assert(body.document.startsWith('v2.'));
  const accepted = !stored || body.version > stored.version;
  if (accepted) stored = body;
  wire.push({ method: 'PUT', version: body.version, accepted });
  response.writeHead(200, { 'content-type': 'application/json' });
  response.end(JSON.stringify({ accepted, version: stored.version }));
});
await new Promise(resolve => relay.listen(0, '127.0.0.1', resolve));
const baseURL = `http://127.0.0.1:${relay.address().port}`;
let serial = 0;
async function peer(kind, name, mode, fields = {}) {
  const directory = join(fixtureRoot, name); await mkdir(directory, { recursive: true });
  const actor = kind === 'swift' ? '00000000-0000-4000-8000-000000000001' : '00000000-0000-4000-8000-000000000002';
  const path = join(fixtureRoot, `command-${++serial}.json`);
  await writeFile(path, JSON.stringify({ directory, actor, mode, baseURL, ...fields }));
  const { stdout, stderr } = await run(kind === 'swift' ? swiftPeer : kotlinLauncher, [path], { maxBuffer: 16 * 1024 * 1024 });
  assert.equal(stderr.trim(), '', `${kind} peer stderr`);
  const result = JSON.parse(stdout.trim());
  await writeFile(join(fixtureRoot, `result-${serial}.json`), JSON.stringify(result));
  return result;
}
const edit = (kind, name, actions, hostEdits = []) => peer(kind, name, 'edit', { actions, hostEdits });
async function publish(kind, name) {
  const version = (stored?.version ?? 0) + 1;
  const prepared = await peer(kind, name, 'prepare', { wireVersion: version });
  assert.equal(prepared.baseVersion, version - 1);
  assert.equal(prepared.document.fixtureSibling, 'retain-me');
  assert(!('activeProfileId' in prepared.document));
  assert(!('activeProfileId' in prepared.document.nativeSync));
  assert.equal((await peer(kind, name, 'push')).accepted, true);
  return prepared;
}
const profile = (result, id) => result.state.roster.profiles[id];
const saved = (result, id) => result.state.libraries[owner].items.some(item => item.id === id);
const watchField = 'watchlist.movie.' + Buffer.from('tt-watchlist').toString('base64url');
const watchValue = { id: 'tt-watchlist', type: 'movie', name: 'Watch later', addedAt: 123.5 };
const watchRegister = result => result.nativeHostPreferences.profiles[owner]?.fields[watchField];
const addon = suffix => ({ transportUrl: `https://fixture.invalid/${suffix}/manifest.json`, manifest: {
  id: `fixture.${suffix}`, name: suffix, version: '1.0.0', resources: ['meta'], types: ['movie', 'series'], catalogs: []
} });
const install = suffix => ({ type: 'install_addon', profileId: owner, addon: addon(suffix) });

try {
  await edit('swift', 'apple', [
    { type: 'add_profile', id: viewer, name: 'Viewer' }, install('one'), install('two'),
    { type: 'add_library_item', profileId: owner, item: { kind: 'standard', id: 'tt-saved', type: 'series', name: 'Saved series', poster: null } },
    { type: 'report_progress', metaId: 'tt-saved', videoId: 'tt-saved:1:2', name: 'Saved series', positionMs: 120000, durationMs: 1200000, metadata: { type: 'series' } },
    { type: 'mark_watched', metaId: 'tt-history', name: 'Watched without saving', metadata: { type: 'movie' } }
  ], [{ profileID: owner, fields: { [watchField]: watchValue, avatar: '🍿' } }]);
  await publish('swift', 'apple');
  let android = await peer('kotlin', 'android', 'pull');
  assert.equal(profile(android, viewer).name, 'Viewer');
  assert(saved(android, 'tt-saved')); assert(!saved(android, 'tt-history')); assert(!saved(android, 'tt-watchlist'));
  assert.equal(android.playback.resumeById['tt-saved:1:2'].offsetMs, 120000);
  assert.equal(android.playback.watchedTitles['tt-history'], 1);
  assert.deepEqual(android.installedAddons, [addon('one').transportUrl, addon('two').transportUrl]);
  assert.equal(watchRegister(android).value.addedAt, 123.5);
  await edit('kotlin', 'android', [
    { type: 'reorder_addons', profileId: owner, transportUrls: [addon('two').transportUrl, addon('one').transportUrl] },
    { type: 'remove_addon', profileId: owner, transportUrl: addon('one').transportUrl },
    { type: 'patch_profile', id: viewer, edits: [{ field: 'name', value: 'Renamed on Android' }] },
    { type: 'report_progress', metaId: 'tt-saved', videoId: 'tt-saved:1:2', name: 'Saved series', positionMs: 240000, durationMs: 1200000, metadata: { type: 'series' } },
    { type: 'reset_watched', metaId: 'tt-history' }
  ], [{ profileID: owner, fields: { [watchField]: null, avatar: '🎬' } }]);
  await edit('kotlin', 'android', [{ type: 'switch_profile', id: viewer }]);
  await publish('kotlin', 'android');
  let apple = await peer('swift', 'apple', 'pull');
  assert.equal(apple.state.activeProfileId, owner);
  assert.equal(profile(apple, viewer).name, 'Renamed on Android');
  assert.deepEqual(apple.installedAddons, [addon('two').transportUrl]);
  assert.equal(apple.playback.resumeById['tt-saved:1:2'].offsetMs, 240000);
  assert(!apple.playback.watchedTitles['tt-history']);
  assert.equal(watchRegister(apple).value, null);
  // Reopening a stale local installation and exporting after a remote merge cannot resurrect
  // removed add-ons/watchlist entries, and a sync cannot replace device-local active viewer.
  await publish('swift', 'apple');
  android = await peer('kotlin', 'android', 'pull');
  assert.equal(android.state.activeProfileId, viewer);
  assert.equal(watchRegister(android).value, null);
  assert.deepEqual(android.installedAddons, [addon('two').transportUrl]);
  const cold = await peer('swift', 'cold', 'pull');
  assert.deepEqual(cold.state.nativeSync, apple.state.nativeSync);
  assert.equal(watchRegister(cold).value, null);
  assert(saved(cold, 'tt-saved')); assert(!saved(cold, 'tt-watchlist')); assert(!saved(cold, 'tt-history'));
  await edit('swift', 'apple', [install('one'), { type: 'reorder_addons', profileId: owner, transportUrls: [addon('one').transportUrl, addon('two').transportUrl] }],
    [{ profileID: owner, fields: { [watchField]: { ...watchValue, addedAt: 124 } } }]);
  await publish('swift', 'apple');
  android = await peer('kotlin', 'android', 'pull');
  assert.deepEqual(android.installedAddons, [addon('one').transportUrl, addon('two').transportUrl]);
  assert.equal(watchRegister(android).value.addedAt, 124);

  // Exercise the unsafe increasing-version protocol using explicit fixture sequence values.
  // Production manager version selection/automatic retries have separate integration tests.
  const raceA = '10000000-0000-0000-0000-000000000003';
  const raceB = '10000000-0000-0000-0000-000000000004';
  await edit('swift', 'apple', [{ type: 'add_profile', id: raceA, name: 'Apple concurrent edit' }]);
  await edit('kotlin', 'android', [{ type: 'add_profile', id: raceB, name: 'Android concurrent edit' }]);
  await peer('swift', 'apple', 'prepare', { wireVersion: 1000 });
  await peer('kotlin', 'android', 'prepare', { wireVersion: 1001 });
  assert.equal((await peer('swift', 'apple', 'push')).accepted, true);
  assert.equal((await peer('kotlin', 'android', 'push')).accepted, true);
  const staleWinner = await peer('swift', 'race-cold', 'pull');
  assert.equal(profile(staleWinner, raceA), undefined);
  assert.equal(profile(staleWinner, raceB).name, 'Android concurrent edit');

  // Version=base+1 makes the same-base loser observable. Its re-pull/re-merge must export both
  // native edits and the host registers rather than repeating the stale prepared ciphertext.
  const raceC = '10000000-0000-0000-0000-000000000005';
  const raceD = '10000000-0000-0000-0000-000000000006';
  await peer('swift', 'apple', 'pull');
  await peer('kotlin', 'android', 'pull');
  await edit('swift', 'apple', [{ type: 'add_profile', id: raceC, name: 'Apple CAS edit' }]);
  await edit('kotlin', 'android', [{ type: 'add_profile', id: raceD, name: 'Android CAS edit' }]);
  const collisionVersion = stored.version + 1;
  await peer('swift', 'apple', 'prepare', { wireVersion: collisionVersion });
  await peer('kotlin', 'android', 'prepare', { wireVersion: collisionVersion });
  assert.equal((await peer('swift', 'apple', 'push')).accepted, true);
  assert.equal((await peer('kotlin', 'android', 'push')).accepted, false);
  await publish('kotlin', 'android');
  const recovered = await peer('swift', 'final-cold', 'pull');
  for (const id of [raceA, raceB, raceC, raceD]) assert(profile(recovered, id), `missing recovered native profile ${id}`);
  assert.equal(watchRegister(recovered).value.addedAt, 124);
  assert.equal((await peer('swift', 'final-cold', 'inspect')).playback.resumeById['tt-saved:1:2'].offsetMs, 240000);
  const androidFinal = await peer('kotlin', 'android', 'inspect');
  assert.equal(androidFinal.state.activeProfileId, viewer);
  const receipt = {
    fixtureRoot, relay: 'strict-newer blind contract model; production backend source unavailable',
    peers: 'actual Swift C ABI / Kotlin JNI native sessions, encrypted durable checkpoints, production AES-GCM v2 crypto with a synthetic fixture account/key',
    provenance: { publicBase: process.env.VORTX_CARRIER_PUBLIC_BASE, nativeLibrarySHA256: process.env.VORTX_FFI_EXPECTED_SHA256,
      nativeHeaderSHA256: process.env.VORTX_FFI_HEADER_EXPECTED_SHA256, androidClassesSHA256: process.env.VORTX_CARRIER_APP_CLASSES_SHA256,
      sourceSHA256, swiftPeerSHA256: await digest(swiftPeer), kotlinLauncherSHA256: await digest(kotlinLauncher),
      kotlinBytecodeSHA256: await treeDigests(join(outputRoot, 'kotlin-classes')),
      swiftCompiler: process.env.VORTX_CARRIER_SWIFT_COMPILER, javaRuntime: process.env.VORTX_CARRIER_JAVA_RUNTIME,
      kotlinCompilerSHA256: process.env.VORTX_CARRIER_KOTLIN_COMPILER_SHA256 },
    evidenceRetention: 'Generated source inputs, Android class snapshot, peer binaries, commands/results and this receipt are intentionally retained under fixtureRoot and its parent.',
    hostActors: { swift: '00000000-0000-4000-8000-000000000001', kotlin: androidFinal.state.nativeHostPreferenceState.actor },
    boundary: 'Does not invoke production sync-manager version selection or automatic retries, equal-clock host actor tie-break, deployed backend, installed apps, UI, provider traffic or playback. Android uses its production persisted random host actor.',
    coverage: ['Apple→Android encrypted carrier', 'Android→Apple encrypted carrier', 'native install/reorder/remove/reinstall',
      'profile edit with device-local active viewer', 'episode progress', 'watched/reset separate from saved library',
      'Watchlist fractional timestamp add/null removal/re-add separate from saved library', 'stale peer merge', 'OS-process cold reopen',
      'increasing-version lost-update protocol reproduced', 'base+1 same-base rejection and manual re-merge recovery'],
    knownGapReproduced: 'increasing-version stale writes both accepted; cold peer lost earlier profile', wire
  };
  await writeFile(join(fixtureRoot, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.log('PASS: real Swift↔Kotlin encrypted native carrier, profile/addon/history/Watchlist convergence and cold reopen');
  console.log('REPRODUCED: increasing-version stale PUT accepted and lost earlier native edit; base+1 rejected loser and manual re-merge recovered all edits');
  console.log(`Fixture receipt: ${join(fixtureRoot, 'receipt.json')}`);
} finally { await new Promise(resolve => relay.close(resolve)); }
