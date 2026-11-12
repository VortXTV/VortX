import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';
import { mkdir, mkdtemp, realpath, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const account = '20000000-0000-4000-8000-000000000041';
export const owner = '00000000-0000-0000-0000-00000000A11C';
export const bearer = 'Bearer synthetic-fixture-only';
const addon = 'https://synthetic.invalid/website/manifest.json';
const key = Buffer.alloc(32, 41);
const utf8 = new TextDecoder('utf-8', { fatal: true });
const maxBody = 1024 * 1024;
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const aad = (id, revision) => Buffer.from(`vortx/sync-doc/v2\n${id}\n${revision}`);

export const original = Buffer.from(String.raw`{
  "addons": [{"transportUrl":"${addon}","manifest":{"id":"com.example.website-fixture","name":"Website fixture","version":"1.0.0","types":["movie"],"resources":["catalog"],"catalogs":[]}}],
  "addonOrder": ["${addon}"],
  "webProgress": {"editedAt":1720000000000,"owner":[{"id":"tt0000101","type":"series","v":"tt0000101:1:2","t":37.125,"d":2500,"lastWatched":1720000000000}]},
  "vortx": {"webFuture":{"n":1.2300e+2,"z":-0}},
  "future": {"exact":9007199254740991,"text":"\u0061"}
}`);
const changedRosterless = Buffer.from(utf8.decode(original)
  .replace('9007199254740991', '9007199254740989')
  .replace('1.2300e+2', '9.8700e+1')
  .replace('"t":37.125', '"t":83.5'));

export function seal(plaintext, revision) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(aad(account, revision));
  return `v2.${Buffer.concat([nonce, cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]).toString('base64')}`;
}

export function open(ciphertext, revision, id = account) {
  assert(typeof ciphertext === 'string' && ciphertext.startsWith('v2.'), 'expected v2 ciphertext');
  const encoded = ciphertext.slice(3);
  const combined = Buffer.from(encoded, 'base64');
  assert(combined.length > 28 && combined.toString('base64') === encoded, 'invalid v2 encoding');
  const decipher = createDecipheriv('aes-256-gcm', key, combined.subarray(0, 12));
  decipher.setAAD(aad(id, revision));
  decipher.setAuthTag(combined.subarray(-16));
  return Buffer.concat([decipher.update(combined.subarray(12, -16)), decipher.final()]);
}

// JSON.parse validates syntax. The scanner only locates complete raw values and decodes keys.
// It preserves the bytes inside every original opaque value and rejects duplicate object keys.
export function rawMembers(bytes) {
  const text = utf8.decode(bytes);
  const parsed = JSON.parse(text);
  assert(parsed && typeof parsed === 'object' && !Array.isArray(parsed), 'expected object');
  let offset = text.indexOf('{') + 1;
  const whitespace = () => { while (offset < text.length && /[\t\n\r ]/.test(text[offset])) offset++; };
  function stringEnd(start) {
    for (let cursor = start + 1; cursor < text.length; cursor++) {
      if (text[cursor] === '\\') cursor++;
      else if (text[cursor] === '"') return cursor + 1;
    }
    throw new Error('unterminated JSON string');
  }
  function valueEnd(start) {
    if (text[start] === '"') return stringEnd(start);
    if (text[start] !== '{' && text[start] !== '[') {
      return start + /^[^\t\n\r ,}\]]+/.exec(text.slice(start))[0].length;
    }
    let depth = 1;
    for (let cursor = start + 1; cursor < text.length; cursor++) {
      if (text[cursor] === '"') cursor = stringEnd(cursor) - 1;
      else if (text[cursor] === '{' || text[cursor] === '[') depth++;
      else if ((text[cursor] === '}' || text[cursor] === ']') && --depth === 0) return cursor + 1;
    }
    throw new Error('unterminated JSON value');
  }
  const values = new Map();
  for (whitespace(); text[offset] !== '}'; whitespace()) {
    const end = stringEnd(offset);
    const name = JSON.parse(text.slice(offset, end));
    assert(!values.has(name), 'duplicate JSON member');
    offset = end;
    whitespace();
    assert.equal(text[offset++], ':');
    whitespace();
    const finish = valueEnd(offset);
    values.set(name, text.slice(offset, finish));
    offset = finish;
    whitespace();
    if (text[offset] === '}') break;
    assert.equal(text[offset++], ',');
  }
  return values;
}

export function validateRosterPublication(plaintext, source = original) {
  const before = rawMembers(source);
  const after = rawMembers(plaintext);
  assert.deepEqual([...after.keys()].sort(), [...before.keys()].sort(), 'unexpected account field change');
  for (const [name, raw] of before) {
    if (name !== 'vortx') assert.equal(after.get(name), raw, `original raw account field ${name} changed`);
  }
  const website = rawMembers(Buffer.from(before.get('vortx')));
  const promoted = rawMembers(Buffer.from(after.get('vortx')));
  assert(!website.has('roster') && !website.has('rosterModified'), 'publication source is not rosterless');
  assert.deepEqual([...promoted.keys()].sort(), [...website.keys(), 'roster', 'rosterModified'].sort());
  for (const [name, raw] of website) assert.equal(promoted.get(name), raw, `original raw website field ${name} changed`);
  assert.equal(promoted.get('rosterModified'), '0');
  const roster = JSON.parse(promoted.get('roster'));
  assert(Array.isArray(roster) && roster.length === 1, 'promotion must have exactly one owner');
  const record = roster[0];
  assert.equal(record.id, owner);
  assert.equal(record.name, 'Main');
  assert.equal(record.avatar, '🍿');
  assert.equal(record.isOwner, true);
  assert(typeof record.accentID === 'string' && record.accentID.length > 0 && Number.isFinite(record.textScale));
  for (const name of ['oled', 'usesOwnAccount', 'familyEdit', 'isKids']) assert.equal(typeof record[name], 'boolean');
  return record;
}

async function readBody(request) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    assert(bytes <= maxBody, 'fixture request exceeded body limit');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, bytes);
}

export async function makeRelay(initialPlaintext = original) {
  let cloud = { document: seal(initialPlaintext, 40), version: 40 };
  let phase;
  let failure;
  const wire = [];
  function clean() { if (failure) throw failure; }
  function advanceRosterless(plaintext, version = cloud.version + 1) {
    const rows = rawMembers(plaintext);
    assert(!rows.has('nativeSync'), 'revision advance added native sync');
    assert(!rawMembers(Buffer.from(rows.get('vortx'))).has('roster'), 'revision advance inserted a roster');
    assert(Number.isSafeInteger(version) && version > cloud.version);
    cloud = { document: seal(plaintext, version), version };
  }
  const server = createServer(async (request, response) => {
    const current = phase;
    try {
      clean();
      assert(current, 'request outside an explicit command');
      const expected = current.requests[current.position++];
      assert(expected, 'extra request in an explicit command');
      assert.equal(request.url, '/v1/backup', 'unexpected endpoint');
      assert.deepEqual(request.headersDistinct.authorization, [bearer], 'missing or ambiguous synthetic authorization');
      assert.equal(request.method, expected.method, 'wrong request order');
      assert.equal(request.headers['if-match'], undefined, 'revision belongs in the CAS body');
      assert.equal(request.headers['if-none-match'], undefined, 'fixture requires full original account bytes');
      const raw = await readBody(request);
      assert.equal(current, phase, 'request outlived its command');
      response.setHeader('content-type', 'application/json');
      if (request.method === 'GET') {
        assert.equal(raw.length, 0, 'GET contained a body');
        const overridden = expected.readbackPlaintext !== undefined;
        const served = overridden
          ? { document: seal(expected.readbackPlaintext, expected.version), version: expected.version }
          : cloud;
        assert.equal(served.version, expected.version, 'GET served the wrong revision');
        if (overridden) {
          assert(served.version < cloud.version || (served.version === cloud.version
            && !expected.readbackPlaintext.equals(open(cloud.document, cloud.version))),
          'readback control did not serve stale or mismatched plaintext');
        }
        wire.push({ phase: current.label, method: 'GET', version: served.version,
          ciphertextSHA256: sha256(served.document), overridden });
        response.setHeader('etag', `"${served.version}"`);
        response.end(JSON.stringify(served));
        return;
      }
      assert.equal(request.method, 'PUT');
      assert.equal(request.headers['content-type'], 'application/json');
      assert.deepEqual([...rawMembers(raw).keys()].sort(), ['baseRevision', 'document', 'version']);
      const submitted = JSON.parse(utf8.decode(raw));
      assert(Number.isSafeInteger(submitted.baseRevision) && Number.isSafeInteger(submitted.version));
      assert.equal(submitted.baseRevision, cloud.version, 'CAS did not use the exact current base');
      assert.equal(submitted.version, cloud.version + 1, 'CAS did not propose base plus one');
      assert.equal(submitted.version, expected.version, 'wrong proposed revision');
      assert.throws(() => open(submitted.document, submitted.version + 1), 'v2 must bind the revision');
      assert.throws(() => open(submitted.document, submitted.version, owner), 'v2 must bind the account');
      const plaintext = open(submitted.document, submitted.version);
      validateRosterPublication(plaintext, open(cloud.document, cloud.version));
      const verdict = expected.verdict ?? 'accepted';
      assert(['accepted', 'rejected', 'ambiguous'].includes(verdict), 'unknown CAS response');
      if (verdict === 'accepted') {
        assert.equal(expected.winner, undefined);
        cloud = { document: submitted.document, version: submitted.version };
      } else if (verdict === 'rejected' || expected.winner !== undefined) {
        assert(Buffer.isBuffer(expected.winner), 'conflict requires an external winner');
        advanceRosterless(expected.winner, expected.winnerRevision);
      }
      wire.push({ phase: current.label, method: 'PUT', base: submitted.baseRevision, version: submitted.version,
        ciphertextSHA256: sha256(submitted.document), plaintextSHA256: sha256(plaintext), verdict,
        resultingCiphertextSHA256: sha256(cloud.document) });
      const acknowledgment = { version: cloud.version };
      if (verdict !== 'ambiguous') acknowledgment.accepted = verdict === 'accepted';
      response.end(JSON.stringify(acknowledgment));
    } catch (error) {
      failure ??= new Error(`loopback ${current?.label ?? 'idle'}: ${error.message.split('\n')[0]}`);
      if (!response.headersSent) response.statusCode = 422;
      response.end('{}');
    }
  });
  server.requestTimeout = 10_000;
  await new Promise((done, fail) => {
    server.once('error', fail);
    server.listen(0, '127.0.0.1', done);
  });
  return {
    baseURL: `http://127.0.0.1:${server.address().port}`,
    wire,
    state: () => ({ ...cloud }),
    advance(plaintext) {
      clean();
      assert(!phase, 'cannot advance cloud during an explicit command');
      advanceRosterless(plaintext);
    },
    advanceWithRoster(plaintext) {
      clean();
      assert(!phase, 'cannot advance cloud during an explicit command');
      validateRosterPublication(plaintext, open(cloud.document, cloud.version));
      const version = cloud.version + 1;
      cloud = { document: seal(plaintext, version), version };
    },
    async expect(label, requests, action) {
      clean();
      assert(!phase, 'concurrent fixture commands');
      phase = { label, requests, position: 0 };
      try {
        const result = await action();
        clean();
        if (phase.position !== requests.length && typeof result?.outcome === 'string') {
          const outcome = ['completed', 'pending', 'failed'].includes(result.outcome) ? result.outcome : 'unknown';
          const version = [0, 40, 41, 42].includes(result.version) ? result.version : -1;
          process.stderr.write([
            'VORTX_FIXTURE_ORDER', 'observed=' + phase.position, 'expected=' + requests.length,
            'outcome=' + outcome, 'version=' + version, 'mounted=' + (result.mounted === true),
            'applied=' + (result.applied === true),
          ].join(' ') + '\n');
        }
        assert.equal(phase.position, requests.length, `missing request in ${label}`);
        return result;
      } finally { phase = undefined; }
    },
    clean,
    close: () => new Promise((done, fail) => {
      server.close(error => { if (error) fail(error); else done(); });
      server.closeAllConnections();
    }),
  };
}

async function withTimeout(promise, message, milliseconds = 30_000) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

export async function startPeer(binary, scratch, config, label) {
  const command = join(scratch, `${label}.json`);
  await writeFile(command, JSON.stringify(config), { flag: 'wx', mode: 0o600 });
  const child = spawn(binary, [command], { cwd: scratch, stdio: ['pipe', 'pipe', 'pipe'], env: {
    PATH: '/usr/bin:/bin', HOME: scratch, TMPDIR: scratch, VORTX_WEBSITE_FIXTURE_ROOT: scratch,
    ...(process.env.DYLD_LIBRARY_PATH && { DYLD_LIBRARY_PATH: process.env.DYLD_LIBRARY_PATH }),
  } });
  let response;
  let terminal;
  let failure;
  let buffered = '';
  let stderrBytes = 0;
  let closing = false;
  const closed = new Promise(resolve => child.once('close', (code, signal) => {
    terminal = { code, signal };
    if (response) response.reject(new Error(`${label}: child exited before a response`));
    resolve(terminal);
  }));
  function fail(message) {
    failure ??= new Error(`${label}: ${message}`);
    response?.reject(failure);
    child.kill('SIGTERM');
  }
  child.once('error', () => fail('could not start fixture executable'));
  child.stdin.on('error', () => { if (!closing) fail('fixture command write failed'); });
  child.stderr.on('data', chunk => {
    stderrBytes += chunk.length;
    if (stderrBytes > maxBody) fail('fixture stderr exceeded limit');
  });
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    buffered += chunk;
    if (Buffer.byteLength(buffered) > maxBody) { fail('fixture stdout exceeded limit'); return; }
    for (let newline = buffered.indexOf('\n'); newline >= 0; newline = buffered.indexOf('\n')) {
      const line = buffered.slice(0, newline);
      buffered = buffered.slice(newline + 1);
      if (!response) { fail('unsolicited fixture response'); return; }
      let value;
      try { value = JSON.parse(line); }
      catch { fail('fixture response was not JSON'); return; }
      if (!value || typeof value !== 'object' || Array.isArray(value)) { fail('fixture response was not an object'); return; }
      const waiter = response;
      response = undefined;
      waiter.resolve(value);
    }
  });
  async function read(send) {
    if (failure) throw failure;
    assert(!terminal && !response, `${label}: fixture not available`);
    const result = new Promise((resolve, reject) => { response = { resolve, reject }; });
    send?.();
    try {
      const value = await withTimeout(result, `${label}: fixture response timeout`);
      if (failure) throw failure;
      return value;
    }
    finally { response = undefined; }
  }
  async function abort() {
    if (terminal) return;
    closing = true;
    child.kill('SIGTERM');
    try { await withTimeout(closed, `${label}: fixture SIGTERM timeout`, 1_000); }
    catch {
      child.kill('SIGKILL');
      await withTimeout(closed, `${label}: fixture SIGKILL timeout`, 2_000);
    }
  }
  try {
    const ready = await read();
    assert.equal(ready.ready, true);
    assert.equal(ready.role, config.mode);
    assert.equal(ready.owner, owner);
    assert(typeof ready.actor === 'string' && ready.actor.length > 0);
    return {
      ready,
      send: action => read(() => child.stdin.write(`${JSON.stringify({ action })}\n`)),
      abort,
      async close() {
        closing = true;
        child.stdin.end('{"action":"close"}\n');
        const status = await withTimeout(closed, `${label}: fixture close timeout`, 5_000);
        if (failure) throw failure;
        assert.deepEqual(status, { code: 0, signal: null });
        assert.equal(buffered, '', `${label}: fixture ended with trailing stdout`);
      },
    };
  } catch (error) { await abort(); throw error; }
}

function mounted(snapshot, witness) {
  for (const name of ['mounted', 'checkpoint']) assert.equal(snapshot[name], true, `missing ${name}`);
  assert.equal(snapshot.witness, witness);
  assert.match(snapshot.checkpointSHA256, /^[a-f0-9]{64}$/);
  assert.deepEqual(snapshot.installedAddons, [addon]);
  assert.equal(snapshot.native.activeProfileId, owner);
  assert(snapshot.native.roster.profiles[owner] && snapshot.native.roster.profiles[owner].deleted !== true,
    'mounted native owner is absent or deleted');
}

function coldSnapshot(snapshot) {
  for (const name of ['mounted', 'checkpoint', 'witness', 'applied', 'pending', 'durable']) {
    assert.equal(snapshot[name], false, `unexpected cold ${name}`);
  }
  assert.equal(snapshot.version, 0);
  assert.deepEqual(snapshot.installedAddons, []);
}

function archivedSource(snapshot, plaintext, hasRoster) {
  assert.equal(snapshot.archivedRoster, hasRoster, 'authenticated checkpoint archived the wrong roster source');
  assert.deepEqual(snapshot.archivedWebProgress, JSON.parse(utf8.decode(plaintext)).webProgress,
    'authenticated checkpoint lost website progress');
}

const get = (version, readbackPlaintext) => ({ method: 'GET', version, readbackPlaintext });
const put = (version, verdict, winner, winnerRevision) => ({ method: 'PUT', version, verdict, winner, winnerRevision });
const witness = sha256(Buffer.concat([Buffer.from('vortx.website-roster-admission.v1\0' + '40\0'), original]));

function snapshotReceipt(state) {
  return {
    version: state.version, mounted: state.mounted, applied: state.applied,
    checkpoint: state.checkpoint, checkpointSHA256: state.checkpointSHA256, witness: state.witness,
    archivedRoster: state.archivedRoster, pending: state.pending, durable: state.durable,
    installedAddonCount: state.installedAddons.length, requestBoundaries: state.requestBoundaries,
  };
}

function requestBoundaries(snapshot, requests) {
  const boundaries = snapshot.requestBoundaries;
  assert(Array.isArray(boundaries), 'missing actual request-boundary observations');
  assert.deepEqual(boundaries.map(row => row.method), requests.map(row => row.method),
    'request observations are not aligned with the encrypted wire');
  for (const row of boundaries) {
    assert.deepEqual(Object.keys(row).sort(), ['applied', 'checkpoint', 'method', 'mounted', 'version']);
    for (const flag of ['mounted', 'checkpoint', 'applied']) assert.equal(typeof row[flag], 'boolean');
    assert(Number.isSafeInteger(row.version) && row.version >= 0);
  }
  return boundaries;
}

function verifyColdBoundaries(snapshot, requests, confirmationIndex = requests.length - 1) {
  for (const [index, row] of requestBoundaries(snapshot, requests).entries()) {
    for (const flag of ['mounted', 'checkpoint', 'applied']) {
      assert.equal(row[flag], false, `unexpected ${flag} before cold request ${index + 1}`);
    }
    if (index <= confirmationIndex) assert.equal(row.version, 0, 'unconfirmed revision was stamped locally');
  }
}

async function withScenario(binary, scratch, name, initialPlaintext, run, legacySource) {
  const directory = join(scratch, `${name}-first`);
  await mkdir(directory, { mode: 0o700 });
  const relay = await makeRelay(initialPlaintext);
  const active = [];
  async function peer(role, path = directory) {
    const process = await startPeer(binary, scratch, {
      mode: role, directory: path, baseURL: relay.baseURL, websiteWitness: witness,
      ...(legacySource && role === 'website-cold'
        ? { websiteLegacySource: legacySource.toString('base64'), websiteLegacyRevision: 40 }
        : {}),
    }, `${name}-${role}`);
    active.push(process);
    return process;
  }
  async function command(peer, step, action, requests = []) {
    return await relay.expect(`${name}:${step}`, requests, () => peer.send(action));
  }
  try {
    const first = await peer('website-cold');
    const initial = await command(first, 'initial-state', 'snapshot');
    coldSnapshot(initial);
    requestBoundaries(initial, []);
    const result = await run({ first, peer, command, relay });
    relay.clean();
    return result;
  } finally {
    try { await Promise.all(active.map(process => process.abort())); }
    finally { await relay.close(); }
  }
}

async function positiveScenario(binary, scratch, race) {
  const name = race ? 'cas-race' : 'promotion';
  return await withScenario(binary, scratch, name, original, async ({ first, peer, command, relay }) => {
    const source = race ? changedRosterless : original;
    const target = race ? 42 : 41;
    const requests = race
      ? [get(40), put(41, 'rejected', changedRosterless), get(41), put(42), get(42), get(42)]
      : [get(40), put(41), get(41), get(41)];
    const cold = await command(first, 'cold-publication', 'pull', requests);
    verifyColdBoundaries(cold, requests, requests.length - 2);
    assert.equal(cold.outcome, 'completed');
    assert.equal(cold.version, target);
    assert.equal(cold.applied, true);
    mounted(cold, false);
    archivedSource(cold, source, true);
    const confirmation = relay.state();
    assert.equal(confirmation.version, target);
    const plaintext = open(confirmation.document, target);
    validateRosterPublication(plaintext, source);
    const [acceptedPUT, confirmedGET, mountGET] = relay.wire.slice(-3);
    assert.equal(acceptedPUT.verdict, 'accepted');
    assert.equal(acceptedPUT.ciphertextSHA256, sha256(confirmation.document));
    assert.equal(acceptedPUT.ciphertextSHA256, confirmedGET.ciphertextSHA256);
    assert.equal(confirmedGET.ciphertextSHA256, mountGET.ciphertextSHA256);
    if (race) {
      const [, rejectedPUT, winnerGET] = relay.wire;
      assert.equal(rejectedPUT.verdict, 'rejected');
      assert.equal(rejectedPUT.resultingCiphertextSHA256, winnerGET.ciphertextSHA256);
      assert.notEqual(rejectedPUT.plaintextSHA256, acceptedPUT.plaintextSHA256);
    }
    await first.close();
    const fresh = join(scratch, `${name}-peer`);
    await mkdir(fresh, { mode: 0o700 });
    const second = await peer('website-peer', fresh);
    assert.notEqual(second.ready.actor, first.ready.actor, 'independent installation reused the first actor');
    const initial = await command(second, 'independent-initial-state', 'snapshot');
    coldSnapshot(initial);
    requestBoundaries(initial, []);
    const peerRequests = [get(target), get(target)];
    const readback = await command(second, 'independent-readback', 'pull', peerRequests);
    verifyColdBoundaries(readback, peerRequests, 0);
    assert.equal(readback.outcome, 'completed');
    assert.equal(readback.version, target);
    assert.equal(readback.applied, true);
    mounted(readback, false);
    archivedSource(readback, source, true);
    assert.deepEqual(relay.state(), confirmation, 'independent reader changed confirmed cloud bytes');
    await second.close();
    return { plaintext, receipt: { cold: snapshotReceipt(cold), peer: snapshotReceipt(readback), wire: relay.wire } };
  });
}

async function negativeScenario(binary, scratch, name, initial, requests, checkCloud) {
  return await withScenario(binary, scratch, name, initial, async ({ first, command, relay }) => {
    const before = relay.state();
    const rejected = await command(first, 'cold-refusal', 'pull', requests);
    verifyColdBoundaries(rejected, requests);
    assert.equal(rejected.outcome, 'failed');
    coldSnapshot(rejected);
    checkCloud(relay, before);
    await first.close();
    return { rejected: snapshotReceipt(rejected), wire: relay.wire };
  });
}

async function oldCheckpointScenario(binary, scratch, confirmedRoster) {
  return await withScenario(binary, scratch, 'old-checkpoint', original, async ({ first, peer, command, relay }) => {
    const seeded = await command(first, 'seed-legacy-checkpoint', 'seed-legacy');
    requestBoundaries(seeded, []);
    assert.equal(seeded.checkpoint, true);
    assert.equal(seeded.witness, true);
    assert.equal(seeded.mounted, false);
    assert.equal(seeded.applied, false);
    assert.match(seeded.checkpointSHA256, /^[a-f0-9]{64}$/);
    archivedSource(seeded, original, false);
    await first.close();

    relay.advance(changedRosterless);
    const newerRosterless = relay.state();
    const restarted = await peer('website-restart');
    assert.equal(restarted.ready.actor, first.ready.actor, 'old checkpoint reopened under a different installation');
    const offline = await command(restarted, 'offline-reopen', 'offline');
    requestBoundaries(offline, []);
    assert.equal(offline.restored, true);
    mounted(offline, true);
    assert.equal(offline.checkpointSHA256, seeded.checkpointSHA256);
    archivedSource(offline, original, false);

    const changedRequests = [get(41)];
    const refused = await command(restarted, 'newer-rosterless-refusal', 'pull', changedRequests);
    requestBoundaries(refused, changedRequests);
    assert.equal(refused.outcome, 'failed');
    assert.equal(refused.applied, offline.applied);
    assert.equal(refused.version, offline.version);
    mounted(refused, true);
    assert.equal(refused.checkpointSHA256, offline.checkpointSHA256, 'refusal mutated authenticated old checkpoint');
    archivedSource(refused, original, false);
    assert.deepEqual(relay.state(), newerRosterless, 'old checkpoint rewrote the newer rosterless backup');

    relay.advanceWithRoster(confirmedRoster);
    const newerRoster = relay.state();
    const readRequests = [get(42)];
    const restored = await command(restarted, 'same-owner-full-roster-read', 'pull', readRequests);
    requestBoundaries(restored, readRequests);
    assert.equal(restored.outcome, 'completed');
    assert.equal(restored.version, 42);
    assert.equal(restored.applied, true);
    assert.equal(restored.mounted, true);
    assert.equal(restored.checkpoint, true);
    assert.deepEqual(restored.installedAddons, [addon]);
    assert.equal(restored.native.activeProfileId, owner);
    assert.deepEqual(relay.state(), newerRoster, 'ordinary read rewrote a confirmed same-owner roster');
    await restarted.close();
    return { seeded: snapshotReceipt(seeded), offline: snapshotReceipt(offline), refused: snapshotReceipt(refused),
      restored: snapshotReceipt(restored), wire: relay.wire };
  }, original);
}

async function staleAfterConflictScenario(binary, scratch, rosterAtTarget) {
  return await withScenario(binary, scratch, 'stale-after-conflict', original, async ({ first, peer, command, relay }) => {
    const requests = [get(40), put(41, 'rejected', changedRosterless, 42), get(41, rosterAtTarget)];
    const rejected = await command(first, 'stale-target-refusal', 'pull', requests);
    verifyColdBoundaries(rejected, requests);
    assert.equal(rejected.outcome, 'failed');
    coldSnapshot(rejected);
    const receipt = { state: 'r', baseRevision: 40, targetRevision: 41, minimumReadbackRevision: 42 };
    assert.deepEqual(rejected.publicationReceipt, receipt);
    await first.close();

    const restarted = await peer('website-restart');
    assert.equal(restarted.ready.actor, first.ready.actor);
    const staleRead = [get(41, rosterAtTarget)];
    const refused = await command(restarted, 'restarted-stale-target-refusal', 'pull', staleRead);
    verifyColdBoundaries(refused, staleRead);
    assert.equal(refused.outcome, 'failed');
    coldSnapshot(refused);
    assert.deepEqual(refused.publicationReceipt, receipt);
    const cloud = relay.state();
    assert.equal(cloud.version, 42);
    assert.deepEqual(open(cloud.document, 42), changedRosterless);
    await restarted.close();
    return { rejected: snapshotReceipt(rejected), refused: snapshotReceipt(refused), receipt, wire: relay.wire };
  });
}

async function replayConflictScenario(binary, scratch, rosterAtTarget) {
  return await withScenario(binary, scratch, 'replay-conflict', original, async ({ first, peer, command, relay }) => {
    const firstRequests = [get(40), put(41, 'ambiguous'), get(40)];
    const ambiguous = await command(first, 'ambiguous-no-verdict', 'pull', firstRequests);
    verifyColdBoundaries(ambiguous, firstRequests);
    assert.equal(ambiguous.outcome, 'failed');
    coldSnapshot(ambiguous);
    assert.deepEqual(ambiguous.publicationReceipt,
      { state: 'p', baseRevision: 40, targetRevision: 41, minimumReadbackRevision: 41 });
    await first.close();

    const restarted = await peer('website-restart');
    const replayRequests = [get(40), put(41, 'rejected', changedRosterless, 42), get(41, rosterAtTarget)];
    const replayed = await command(restarted, 'replay-rejected', 'pull', replayRequests);
    verifyColdBoundaries(replayed, replayRequests);
    assert.equal(replayed.outcome, 'failed');
    coldSnapshot(replayed);
    const receipt = { state: 'p', baseRevision: 40, targetRevision: 41, minimumReadbackRevision: 42 };
    assert.deepEqual(replayed.publicationReceipt, receipt);
    const newerRequests = [get(42)];
    const refused = await command(restarted, 'newer-rosterless-refusal', 'pull', newerRequests);
    verifyColdBoundaries(refused, newerRequests);
    assert.equal(refused.outcome, 'failed');
    coldSnapshot(refused);
    assert.deepEqual(refused.publicationReceipt, receipt);
    const cloud = relay.state();
    assert.equal(cloud.version, 42);
    assert.deepEqual(open(cloud.document, 42), changedRosterless);
    await restarted.close();
    return { ambiguous: snapshotReceipt(ambiguous), replayed: snapshotReceipt(replayed),
      refused: snapshotReceipt(refused), receipt, wire: relay.wire };
  });
}

async function main() {
  assert.equal(process.argv.length, 4, 'usage: node apple-website-roster.mjs <compiled-peer> <private-output-parent>');
  const binary = await realpath(process.argv[2]);
  const parent = await realpath(process.argv[3]);
  assert((await stat(binary)).isFile(), 'expected compiled peer executable');
  assert((await stat(parent)).isDirectory(), 'expected owned output directory');
  const scratch = await mkdtemp(join(parent, 'apple-website-roster.'));
  const scratchInfo = await stat(scratch);
  assert(scratchInfo.uid === process.getuid() && (scratchInfo.mode & 0o077) === 0, 'fixture scratch must be private and owned');
  const promotion = await positiveScenario(binary, scratch, false);
  const casRace = await positiveScenario(binary, scratch, true);
  const changedBase = await oldCheckpointScenario(binary, scratch, casRace.plaintext);
  const staleAfterConflict = await staleAfterConflictScenario(binary, scratch, promotion.plaintext);
  const replayConflict = await replayConflictScenario(binary, scratch, promotion.plaintext);
  const ambiguousCAS = await negativeScenario(binary, scratch, 'ambiguous-cas', original,
    [get(40), put(41, 'ambiguous', changedRosterless), get(41)], relay => {
      const cloud = relay.state();
      assert.equal(cloud.version, 41);
      assert.deepEqual(open(cloud.document, 41), changedRosterless);
      const [, submitted, readback] = relay.wire;
      assert.equal(submitted.verdict, 'ambiguous');
      assert.notEqual(submitted.ciphertextSHA256, readback.ciphertextSHA256);
      assert.equal(submitted.resultingCiphertextSHA256, readback.ciphertextSHA256);
    });
  function checkUnconfirmedWrite(relay) {
    const cloud = relay.state();
    assert.equal(cloud.version, 41);
    validateRosterPublication(open(cloud.document, 41));
    const [, accepted, unconfirmed] = relay.wire;
    assert.equal(accepted.verdict, 'accepted');
    assert.equal(accepted.ciphertextSHA256, sha256(cloud.document));
    assert.equal(unconfirmed.overridden, true);
    assert.notEqual(accepted.ciphertextSHA256, unconfirmed.ciphertextSHA256);
  }
  const staleReadback = await negativeScenario(binary, scratch, 'stale-readback', original,
    [get(40), put(41), get(40, original)], checkUnconfirmedWrite);
  const mismatch = Buffer.from(utf8.decode(promotion.plaintext).replace('9007199254740991', '9007199254740989'));
  assert(!mismatch.equals(promotion.plaintext), 'mismatched readback must alter accepted opaque bytes');
  const mismatchedReadback = await negativeScenario(binary, scratch, 'mismatched-readback', original,
    [get(40), put(41), get(41, mismatch)], checkUnconfirmedWrite);
  const oversized = Buffer.from(utf8.decode(original).replace('9007199254740991', '9007199254740993'));
  const oversizedNumber = await negativeScenario(binary, scratch, 'oversized-number', oversized,
    [get(40)], (relay, before) => assert.deepEqual(relay.state(), before));
  const legacyLibrary = Buffer.from(`{"library":[{"state":{"watched":"opaque"}}],${utf8.decode(original).slice(1)}`);
  const unsupportedLegacyLibrary = await negativeScenario(binary, scratch, 'legacy-library', legacyLibrary,
    [get(40)], (relay, before) => assert.deepEqual(relay.state(), before));
  const receipt = { promotion: promotion.receipt, casRace: casRace.receipt, changedBase, ambiguousCAS,
    staleReadback, mismatchedReadback, oversizedNumber, staleAfterConflict, replayConflict, unsupportedLegacyLibrary };
  await writeFile(join(scratch, 'apple-website-roster-receipt.json'), JSON.stringify(receipt, null, 2) + '\n',
    { flag: 'wx', mode: 0o600 });
  console.log('PASS Apple website roster publication, independent readback, CAS race, old checkpoint, durable stale refusal and invalid input checks');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main();
