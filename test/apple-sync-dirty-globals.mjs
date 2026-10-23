import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const [binary, root] = process.argv.slice(2);
const run = promisify(execFile);
const wire = [], checks = [];
let stored = null;
const server = createServer(async (req, res) => {
  assert.equal(req.url, '/v1/backup');
  assert.equal(req.headers.authorization, 'Bearer synthetic-fixture-only');
  res.setHeader('content-type', 'application/json');
  if (req.method === 'GET') {
    wire.push({ method: 'GET', version: stored?.version });
    res.statusCode = stored ? 200 : 404; res.end(stored ? JSON.stringify(stored) : undefined); return;
  }
  assert.equal(req.method, 'PUT');
  let raw = ''; for await (const bytes of req) raw += bytes;
  const body = JSON.parse(raw);
  assert.deepEqual(Object.keys(body).sort(), ['baseRevision', 'document', 'version']);
  assert(body.document.startsWith('v2.')); assert(Number.isSafeInteger(body.version) && body.version >= 0);
  assert(body.baseRevision === null || (Number.isSafeInteger(body.baseRevision) && body.baseRevision >= 0));
  assert.equal(body.version, body.baseRevision === null ? 0 : body.baseRevision + 1);
  const previousVersion = stored?.version ?? null;
  const accepted = body.baseRevision === previousVersion;
  if (accepted) stored = { document: body.document, version: body.version };
  wire.push({ method: 'PUT', accepted, baseRevision: body.baseRevision, version: body.version, previousVersion });
  res.end(JSON.stringify(accepted ? { ok: true, accepted: true } : { ok: true, accepted: false, version: previousVersion }));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const baseURL = `http://127.0.0.1:${server.address().port}`;
let serial = 0;
async function peer(name, mode, extra = {}) {
  const directory = join(root, name); await mkdir(directory, { recursive: true });
  const sequence = ++serial, command = join(root, `dirty-command-${sequence}.json`);
  await writeFile(command, JSON.stringify({ mode, directory, baseURL,
    actor: name === 'sender' ? '00000000-0000-4000-8000-000000000001' : '00000000-0000-4000-8000-000000000002', ...extra }));
  const { stdout } = await run(binary, [command], { timeout: 60_000, maxBuffer: 8 * 1024 * 1024 });
  const result = JSON.parse(stdout);
  await writeFile(join(root, `dirty-result-${sequence}.json`), JSON.stringify(result, null, 2)); return result;
}
function check(condition, name) { checks.push({ name, passed: !!condition }); assert(condition, name); console.log(`PASS ${name}`); }
const owner = '10000000-0000-0000-0000-000000000001';
const watchField = 'watchlist.series.' + Buffer.from('tt-dirty-quarantine').toString('base64url');
const malformed = ['stremiox.autoSkip', 'stremiox.directLinksOnly', 'stremiox.autoSkipDelaySeconds', 'stremiox.videoSize'];
try {
  await peer('sender', 'edit', { actions: [
    { type: 'add_library_item', profileId: owner, item: { kind: 'standard', id: 'tt-dirty-quarantine', type: 'series', name: 'Synthetic Dirty Quarantine', poster: null } },
    { type: 'report_progress', metaId: 'tt-dirty-quarantine', videoId: 'tt-dirty-quarantine:1:2', name: 'Synthetic Dirty Quarantine', positionMs: 120000, durationMs: 1200000, metadata: { type: 'series' } }
  ], edits: [{ profileID: owner, fields: { [watchField]: { id: 'tt-dirty-quarantine', type: 'series', name: 'Synthetic Dirty Quarantine', addedAt: 123.5 } } }] });
  const scalar = await peer('sender', 'auto', { globalScenario: 'scalar' });
  check(scalar.accepted && !scalar.pendingPush && scalar.globalDirtyStamps['stremiox.autoSkip'] === 11,
    'wrong scalar type retains its stamp while actual accepted upload releases the receive-blocking queue');
  const sent = await peer('sender', 'auto', { globalScenario: 'malformed' });
  check(sent.accepted && !sent.pendingPush && sent.stamped === 1,
    'malformed Data, non-JSON Date, nonfinite number and wrong scalar type cannot starve actual queued native upload');
  check(malformed.every(key => sent.nativeUnsupportedSettings.includes(key) && sent.globalDirtyStamps[key] > 0
    && sent.host.globals.fields[key] === undefined), 'all malformed known globals retain dirty stamps and are omitted without null substitution');
  check(sent.globalDirtyStamps['fixture.unsupported'] === 16 && sent.nativeUnsupportedSettings.includes('fixture.unsupported')
    && !('stremiox.activeProfileId' in sent.globalDirtyStamps) && !('fixture.device-local' in sent.globalDirtyStamps)
    && sent.host.globals.fields['stremiox.activeProfileId'] === undefined,
    'unknown settings remain pending while obsolete device-local stamps retire without export');
  check(sent.host.globals.fields['stremiox.keepPlayingInBackground'].value === null
    && !('stremiox.keepPlayingInBackground' in sent.globalDirtyStamps)
    && sent.host.globals.fields['stremiox.catalog.posterWidthPreset'].value === 'compact',
    'valid explicit deletion and unrelated valid global export and acknowledge');
  const cold = await peer('sender', 'inspect', { globalScenario: 'resume' });
  check(Object.keys(cold.globalDirtyStamps).length === Object.keys(sent.globalDirtyStamps).length
    && Object.entries(sent.globalDirtyStamps).every(([key, value]) => cold.globalDirtyStamps[key] === value)
    && malformed.every(key => cold.globalLocalValues[key] === sent.globalLocalValues[key]),
    'new process reopens unchanged local malformed values and exact production dirty stamps from synthetic plist');
  const remote = await peer('receiver', 'pull');
  check(remote.state.libraries[owner].items.some(item => item.id === 'tt-dirty-quarantine')
    && remote.host.profiles[owner].fields[watchField].value.addedAt === 123.5
    && remote.playback.resumeById['tt-dirty-quarantine:1:2'].offsetMs === 120000,
    'independent native installation receives unrelated library, Watchlist and exact episode progress');
  const repairedDuringPUT = await peer('sender', 'auto', { globalScenario: 'resume', globalDuringPUT: 'repair-omitted' });
  check(repairedDuringPUT.accepted && repairedDuringPUT.globalDirtyStamps['stremiox.autoSkip'] === 11
    && repairedDuringPUT.host.globals.fields['stremiox.autoSkip'] === undefined,
    'repairing an omitted value during PUT with the same old stamp cannot be acknowledged by that export');
  const repairedNext = await peer('sender', 'auto', { globalScenario: 'resume' });
  check(repairedNext.accepted && !('stremiox.autoSkip' in repairedNext.globalDirtyStamps)
    && repairedNext.host.globals.fields['stremiox.autoSkip'].value === true,
    'next exact accepted export clears the repaired value and retained stamp');
  const newer = await peer('sender', 'auto', { globalScenario: 'newer', globalDuringPUT: 'newer-valid' });
  check(newer.accepted && newer.globalDirtyStamps['vortx.player.badSourceAutoRetry'] === 21
    && newer.host.globals.fields['vortx.player.badSourceAutoRetry'].value === true,
    'a valid value edited with a newer stamp during PUT survives the preceding value acknowledgement');
  const corrected = await peer('sender', 'auto', { globalScenario: 'correct' });
  check(corrected.accepted && !corrected.pendingPush && Object.keys(corrected.globalDirtyStamps).join() === 'fixture.unsupported'
    && corrected.host.globals.fields['vortx.player.badSourceAutoRetry'].value === false
    && corrected.host.globals.fields['stremiox.directLinksOnly'].value === false
    && corrected.host.globals.fields['stremiox.autoSkipDelaySeconds'].value === 3
    && corrected.host.globals.fields['stremiox.videoSize'].value === 'fit',
    'later valid corrections and newer edit acknowledge only after their own accepted exports');
  const finalCold = await peer('sender', 'inspect', { globalScenario: 'resume' });
  check(Object.keys(finalCold.globalDirtyStamps).join() === 'fixture.unsupported'
    && finalCold.host.globals.fields['stremiox.videoSize'].value === 'fit', 'repaired native values and cleared stamps survive another process restart');
} catch (error) {
  process.exitCode = 1; console.error(error);
  await writeFile(join(root, 'dirty-failure.json'), JSON.stringify({ message: String(error),
    stderr: error.stderr, signal: error.signal, code: error.code, command: error.cmd }, null, 2));
}
finally {
  const digest = async path => createHash('sha256').update(await readFile(path)).digest('hex');
  await writeFile(join(root, 'dirty-receipt.json'), JSON.stringify({ result: process.exitCode ? 'RED' : 'GREEN', checks, wire,
    compiledMethodsSHA256: await digest(join(root, 'Combined.swift')), binarySHA256: await digest(binary),
    librarySHA256: process.env.VORTX_SYNC_TEST_LIBRARY_SHA256, headerSHA256: process.env.VORTX_SYNC_TEST_HEADER_SHA256,
    boundary: 'Actual extracted manager export, dirty persistence accessors, encryption, ACK, retries and queue. Production native C ABI, encrypted checkpoint and host carrier. Synthetic file-backed UserDefaults environment and loopback relay. No live account, app, UI, real notifications or WebSocket scheduling.' }, null, 2));
  console.log(`Receipt: ${join(root, 'dirty-receipt.json')}`);
  await new Promise(resolve => server.close(resolve));
}
