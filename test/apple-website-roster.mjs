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
const originalWebProgress = JSON.parse(utf8.decode(original)).webProgress;

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

export function validatePromotion(plaintext) {
  const before = rawMembers(original);
  const after = rawMembers(plaintext);
  assert.deepEqual([...after.keys()].sort(), [
    ...before.keys(), 'nativeSync', 'nativeHostPreferences', 'profileEditResults', 'nativeProviderCredentials', 'apiKeys',
  ].sort(), 'unexpected account field change');
  for (const [name, raw] of before) {
    if (name !== 'vortx') assert.equal(after.get(name), raw, `original raw account field ${name} changed`);
  }
  const website = rawMembers(Buffer.from(before.get('vortx')));
  const promoted = rawMembers(Buffer.from(after.get('vortx')));
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
  const native = JSON.parse(after.get('nativeSync'));
  assert.equal(native.ownerProfileId, owner, 'native export belongs to a different owner');
  return native;
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
        assert.equal(cloud.version, expected.version, 'GET served the wrong revision');
        wire.push({ phase: current.label, method: 'GET', version: cloud.version, ciphertextSHA256: sha256(cloud.document) });
        response.setHeader('etag', `"${cloud.version}"`);
        response.end(JSON.stringify(cloud));
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
      validatePromotion(plaintext);
      cloud = { document: submitted.document, version: submitted.version };
      wire.push({ phase: current.label, method: 'PUT', base: submitted.baseRevision, version: cloud.version,
        ciphertextSHA256: sha256(cloud.document), plaintextSHA256: sha256(plaintext), accepted: true });
      response.end(JSON.stringify({ accepted: true, version: cloud.version }));
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
      assert(!rawMembers(plaintext).has('nativeSync'), 'revision advance must stay rosterless');
      assert(!rawMembers(Buffer.from(rawMembers(plaintext).get('vortx'))).has('roster'), 'revision advance inserted a roster');
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
          const version = [0, 40, 41].includes(result.version) ? result.version : -1;
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

function originalArchive(snapshot) {
  assert.equal(snapshot.archivedRoster, false, 'promotion leaked into the authenticated legacy archive');
  assert.deepEqual(snapshot.archivedWebProgress, originalWebProgress, 'authenticated legacy archive lost website progress');
}

const get = version => ({ method: 'GET', version });
const put = version => ({ method: 'PUT', version });
const witness = sha256(Buffer.concat([Buffer.from('vortx.website-roster-admission.v1\0' + '40\0'), original]));

async function scenario(binary, scratch, mode) {
  const directory = join(scratch, `${mode}-first`);
  await mkdir(directory, { mode: 0o700 });
  const oversized = Buffer.from(utf8.decode(original).replace('9007199254740991', '9007199254740993'));
  const relay = await makeRelay(mode === 'oversized-number' ? oversized : original);
  const active = [];
  async function peer(role, path) {
    const process = await startPeer(binary, scratch, {
      mode: role, directory: path, baseURL: relay.baseURL, websiteWitness: witness,
    }, `${mode}-${role}`);
    active.push(process);
    return process;
  }
  const snapshot = state => ({ version: state.version, mounted: state.mounted, applied: state.applied,
    checkpoint: state.checkpoint, checkpointSHA256: state.checkpointSHA256, witness: state.witness,
    archivedRoster: state.archivedRoster, pending: state.pending, durable: state.durable,
    installedAddonCount: state.installedAddons.length });
  try {
    const first = await peer('website-cold', directory);
    coldSnapshot(await relay.expect(`${mode}:initial-state`, [], () => first.send('snapshot')));
    const before = relay.state();
    if (mode === 'oversized-number') {
      const rejected = await relay.expect('oversized-number:cold-rejection', [get(40)], () => first.send('pull'));
      assert.equal(rejected.outcome, 'failed');
      coldSnapshot(rejected);
      assert.deepEqual(relay.state(), before);
      await first.close();
      relay.clean();
      return { rejected: snapshot(rejected), wire: relay.wire };
    }
    const cold = await relay.expect(`${mode}:cold`, [get(40), get(40)], () => first.send('pull'));
    assert.equal(cold.outcome, 'completed');
    assert.equal(cold.version, 40);
    assert.equal(cold.applied, true);
    mounted(cold, true);
    assert.equal(cold.pending, true);
    assert.equal(cold.durable, true);
    originalArchive(cold);
    assert.deepEqual(relay.state(), before, 'cold admission altered the cloud document');
    if (mode === 'promotion') {
      const push = await relay.expect(`${mode}:push`, [get(40), put(41)], () => first.send('push'));
      assert.equal(push.accepted, true);
      assert.equal(push.version, 41);
      assert.equal(push.applied, true);
      mounted(push, true);
      originalArchive(push);
      await first.close();
      const accepted = relay.state();
      const native = validatePromotion(open(accepted.document, accepted.version));
      const fresh = join(scratch, `${mode}-peer`);
      await mkdir(fresh, { mode: 0o700 });
      const second = await peer('website-peer', fresh);
      assert.notEqual(second.ready.actor, first.ready.actor, 'independent installation reused the first actor');
      coldSnapshot(await relay.expect(`${mode}:fresh-peer-state`, [], () => second.send('snapshot')));
      // This fixture exercises the generic account branch, which re-fetches during cold mount.
      assert(!Object.hasOwn(native, 'ownerHistory') && native.schemaVersion !== 6);
      const readback = await relay.expect(`${mode}:independent-readback`, [get(41), get(41)], () => second.send('pull'));
      assert.equal(readback.outcome, 'completed');
      assert.equal(readback.version, 41);
      assert.equal(readback.applied, true);
      mounted(readback, false);
      assert.deepEqual(relay.state(), accepted, 'independent reader changed the confirmed cloud bytes');
      await second.close();
      relay.clean();
      return { cold: snapshot(cold), push: snapshot(push), peer: snapshot(readback), wire: relay.wire };
    }

    const changed = Buffer.from(utf8.decode(original).replace('9007199254740991', '9007199254740989'));
    assert(!changed.equals(original));
    relay.advance(changed);
    const advanced = relay.state();
    const refused = await relay.expect(`${mode}:advance-before-CAS`, [get(41)], () => first.send('push'));
    assert.equal(refused.accepted, false);
    assert.equal(refused.version, 40);
    assert.equal(refused.applied, true);
    mounted(refused, true);
    assert.equal(refused.pending, true);
    assert.equal(refused.durable, true);
    assert.equal(refused.checkpointSHA256, cold.checkpointSHA256, 'refused push mutated authenticated local state');
    originalArchive(refused);
    assert.deepEqual(relay.state(), advanced, 'refused push mutated the newer rosterless cloud bytes');
    await first.close();
    const restarted = await peer('website-restart', directory);
    assert.equal(restarted.ready.actor, first.ready.actor, 'same-directory reopen used a different installation');
    const offline = await relay.expect(`${mode}:offline-reopen`, [], () => restarted.send('offline'));
    assert.equal(offline.restored, true);
    assert.equal(offline.outcome, 'completed');
    mounted(offline, true);
    originalArchive(offline);
    assert.deepEqual(relay.state(), advanced);
    await restarted.close();
    relay.clean();
    return { cold: snapshot(cold), refused: snapshot(refused), offline: snapshot(offline), wire: relay.wire };
  } finally {
    try { await Promise.all(active.map(process => process.abort())); }
    finally { await relay.close(); }
  }
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
  const promotion = await scenario(binary, scratch, 'promotion');
  const changedBase = await scenario(binary, scratch, 'changed-base');
  const oversizedNumber = await scenario(binary, scratch, 'oversized-number');
  await writeFile(join(scratch, 'apple-website-roster-receipt.json'), JSON.stringify({ promotion, changedBase, oversizedNumber }, null, 2) + '\n',
    { flag: 'wx', mode: 0o600 });
  console.log(`PASS Apple website roster promotion, independent readback, changed-base refusal and offline checkpoint reopen: ${scratch}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main();
