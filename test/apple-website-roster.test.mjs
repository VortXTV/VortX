import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { request } from 'node:http';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { bearer, makeRelay, open, original, owner, rawMembers, seal, startPeer, validateRosterPublication } from './apple-website-roster.mjs';

const encode = rows => Buffer.from(`{${[...rows].map(([name, raw]) => `${JSON.stringify(name)}:${raw}`).join(',')}}`);
function promoted(source = original) {
  const rows = rawMembers(source);
  const website = rawMembers(Buffer.from(rows.get('vortx')));
  website.set('rosterModified', '0');
  website.set('roster', JSON.stringify([{ id: owner, name: 'Main', avatar: '🍿', isOwner: true,
    accentID: 'fixture', textScale: 1, oled: false, usesOwnAccount: false, familyEdit: false, isKids: false }]));
  rows.set('vortx', encode(website).toString());
  return encode(rows);
}

function fetchRelay(relay, method, body, headers = { authorization: bearer }) {
  const payload = body === undefined ? undefined : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const outgoing = request(`${relay.baseURL}/v1/backup`, {
      method, headers: payload === undefined ? headers : { ...headers, 'content-type': 'application/json',
        'content-length': Buffer.byteLength(payload) }, timeout: 2_000,
    }, incoming => {
      let text = '';
      incoming.setEncoding('utf8');
      incoming.on('error', reject);
      incoming.on('data', chunk => { text += chunk; });
      incoming.on('end', () => {
        try { resolve({ status: incoming.statusCode, body: JSON.parse(text) }); }
        catch (error) { reject(error); }
      });
    });
    outgoing.on('error', reject);
    outgoing.on('timeout', () => outgoing.destroy(new Error('relay self-test timed out')));
    outgoing.end(payload);
  });
}

test('v2 fixture is interoperable in layout and authenticates account and revision', () => {
  const encrypted = seal(original, 40);
  assert.deepEqual(open(encrypted, 40), original);
  assert.throws(() => open(encrypted, 41));
  assert.throws(() => open(encrypted, 40, owner));
  assert.throws(() => open(encrypted + '=', 40), /encoding/);
});

test('raw slices preserve integer, decimal and escape spelling', () => {
  const candidate = promoted();
  assert.equal(validateRosterPublication(candidate).id, owner);
  assert.throws(() => validateRosterPublication(Buffer.from(candidate.toString().replace('9007199254740991', '9007199254740989'))), /raw account field future/);
  assert.throws(() => validateRosterPublication(Buffer.from(candidate.toString().replace('\\u0061', 'a'))), /raw account field future/);
  assert.throws(() => validateRosterPublication(Buffer.from(candidate.toString().replace('1.2300e+2', '123'))), /raw website field webFuture/);
  assert.throws(() => validateRosterPublication(Buffer.from(candidate.toString().replace('"t":37.125', '"t":38'))), /raw account field webProgress/);
  const native = rawMembers(candidate);
  native.set('nativeSync', '{}');
  assert.throws(() => validateRosterPublication(encode(native)), /unexpected account field change/);
  assert.throws(() => rawMembers(Buffer.from('{"r":1,"\\u0072":2}')), /duplicate JSON member/);
});

test('ordered original read, body-based CAS and later read retain the exact accepted ciphertext', async () => {
  const relay = await makeRelay();
  try {
    const before = relay.state();
    const document = seal(promoted(), 41);
    await relay.expect('controlled test', [{ method: 'GET', version: 40 }, { method: 'PUT', version: 41 }], async () => {
      assert.deepEqual(await fetchRelay(relay, 'GET'), { status: 200, body: before });
      assert.deepEqual(await fetchRelay(relay, 'PUT', { document, baseRevision: 40, version: 41 }),
        { status: 200, body: { accepted: true, version: 41 } });
    });
    const confirmed = await relay.expect('independent test read', [{ method: 'GET', version: 41 }], () => fetchRelay(relay, 'GET'));
    assert.deepEqual(confirmed.body, { document, version: 41 });
    assert.deepEqual(relay.wire.map(row => row.method), ['GET', 'PUT', 'GET']);
    assert.equal(relay.wire[1].ciphertextSHA256, relay.wire[2].ciphertextSHA256);
  } finally { await relay.close(); }
});

test('rejected CAS advances to a competing rosterless winner and the second CAS must use its exact bytes', async () => {
  const relay = await makeRelay();
  try {
    const winner = Buffer.from(original.toString().replace('9007199254740991', '9007199254740989'));
    const candidate = promoted(winner);
    const nextDocument = seal(candidate, 42);
    const expected = [
      { method: 'GET', version: 40 },
      { method: 'PUT', version: 41, verdict: 'rejected', winner },
      { method: 'GET', version: 41 },
      { method: 'PUT', version: 42 },
      { method: 'GET', version: 42 },
    ];
    await relay.expect('race', expected, async () => {
      assert.equal((await fetchRelay(relay, 'GET')).body.version, 40);
      assert.deepEqual((await fetchRelay(relay, 'PUT', { document: seal(promoted(), 41), baseRevision: 40, version: 41 })).body,
        { accepted: false, version: 41 });
      assert.deepEqual(open((await fetchRelay(relay, 'GET')).body.document, 41), winner);
      assert.deepEqual((await fetchRelay(relay, 'PUT', { document: nextDocument, baseRevision: 41, version: 42 })).body,
        { accepted: true, version: 42 });
      assert.deepEqual((await fetchRelay(relay, 'GET')).body, { document: nextDocument, version: 42 });
    });
    assert.throws(() => validateRosterPublication(promoted(), winner), /raw account field future/);
    assert.deepEqual(open(relay.state().document, 42), candidate);
    assert.equal(relay.wire[1].resultingCiphertextSHA256, relay.wire[2].ciphertextSHA256);
  } finally { await relay.close(); }
});

test('ambiguous CAS has no verdict and a newer rosterless winner distinct from the proposed candidate', async () => {
  const relay = await makeRelay();
  try {
    const winner = Buffer.from(original.toString().replace('1.2300e+2', '9.8700e+1'));
    const expected = [
      { method: 'PUT', version: 41, verdict: 'ambiguous', winner },
      { method: 'GET', version: 41 },
    ];
    await relay.expect('ambiguous', expected, async () => {
      assert.deepEqual((await fetchRelay(relay, 'PUT', { document: seal(promoted(), 41), baseRevision: 40, version: 41 })).body,
        { version: 41 });
      assert.deepEqual(open((await fetchRelay(relay, 'GET')).body.document, 41), winner);
    });
    assert.equal(relay.wire[0].verdict, 'ambiguous');
    assert.notEqual(relay.wire[0].ciphertextSHA256, relay.wire[1].ciphertextSHA256);
  } finally { await relay.close(); }
});

test('authenticated stale and same-revision alternate reads do not mutate the accepted cloud candidate', async () => {
  const mismatch = Buffer.from(promoted().toString().replace('9007199254740991', '9007199254740989'));
  for (const [version, readbackPlaintext] of [[40, original], [41, mismatch]]) {
    const relay = await makeRelay();
    try {
      const document = seal(promoted(), 41);
      const expected = [{ method: 'PUT', version: 41 }, { method: 'GET', version, readbackPlaintext }];
      await relay.expect('unconfirmed', expected, async () => {
        assert.deepEqual((await fetchRelay(relay, 'PUT', { document, baseRevision: 40, version: 41 })).body,
          { accepted: true, version: 41 });
        const response = await fetchRelay(relay, 'GET');
        assert.equal(response.body.version, version);
        assert.deepEqual(open(response.body.document, version), readbackPlaintext);
      });
      assert.deepEqual(relay.state(), { document, version: 41 });
      assert.equal(relay.wire[1].overridden, true);
      assert.notEqual(relay.wire[1].ciphertextSHA256, relay.wire[0].ciphertextSHA256);
    } finally { await relay.close(); }
  }
});

test('wrong auth, out-of-order CAS, conditional read and missing network each fail closed', async () => {
  const document = seal(promoted(), 41);
  const attempts = [
    [{ method: 'GET', version: 40 }, relay => fetchRelay(relay, 'GET', undefined, {}), /synthetic authorization/],
    [{ method: 'GET', version: 40 }, relay => fetchRelay(relay, 'PUT', { document, baseRevision: 40, version: 41 }), /request order/],
    [{ method: 'GET', version: 40 }, relay => fetchRelay(relay, 'GET', undefined, { authorization: bearer, 'if-none-match': '"40"' }), /full original/],
    [{ method: 'GET', version: 40 }, async () => {}, /missing request/],
    [{ method: 'PUT', version: 41 }, relay => fetchRelay(relay, 'PUT', { document, baseRevision: 39, version: 41 }), /exact current base/],
  ];
  for (const [expected, operation, failure] of attempts) {
    const relay = await makeRelay();
    try {
      const before = relay.state();
      await assert.rejects(relay.expect('guard', [expected], () => operation(relay)), failure);
      assert.deepEqual(relay.state(), before);
      assert.deepEqual(relay.wire, []);
    } finally { await relay.close(); }
  }
});

test('idle request fails and a controlled newer rosterless revision is read without an upload', async () => {
  const first = await makeRelay();
  try {
    assert.equal((await fetchRelay(first, 'GET')).status, 422);
    assert.throws(first.clean, /outside an explicit command/);
  } finally { await first.close(); }
  const second = await makeRelay();
  try {
    const changed = Buffer.from(original.toString().replace('9007199254740991', '9007199254740989'));
    second.advance(changed);
    const latest = await second.expect('newer', [{ method: 'GET', version: 41 }], () => fetchRelay(second, 'GET'));
    assert.deepEqual(open(latest.body.document, 41), changed);
    assert.deepEqual(second.wire.map(row => row.method), ['GET']);
  } finally { await second.close(); }
});

test('child protocol handles exact ready, command and close, and refuses unsolicited or malformed output', async () => {
  const scratch = await mkdtemp(join(dirname(fileURLToPath(import.meta.url)), 'node-self-test.'));
  try {
    const binary = join(scratch, 'fixture.mjs');
    const config = { mode: 'website-cold', directory: scratch, baseURL: 'http://127.0.0.1:1' };
    const ready = { ready: true, role: config.mode, owner, actor: 'synthetic-test-actor' };
    const stub = `#!${process.execPath}\nimport { createInterface } from 'node:readline';\n` +
      `if (process.env.VORTX_WEBSITE_FIXTURE_ROOT !== process.cwd()) process.exit(2);\n` +
      `console.log(${JSON.stringify(JSON.stringify(ready))});\n` +
      `for await (const line of createInterface({ input: process.stdin })) {\n` +
      `  const { action } = JSON.parse(line); if (action === 'close') break; console.log(JSON.stringify({action}));\n}\n`;
    await writeFile(binary, stub, { mode: 0o700, flag: 'wx' });
    const child = await startPeer(binary, scratch, config, 'normal');
    try { assert.deepEqual(await child.send('snapshot'), { action: 'snapshot' }); await child.close(); }
    finally { await child.abort(); }
    const malformed = join(scratch, 'malformed.mjs');
    await writeFile(malformed, `#!${process.execPath}\nconsole.log('no JSON');\n`, { mode: 0o700, flag: 'wx' });
    await assert.rejects(startPeer(malformed, scratch, config, 'malformed'), /not JSON/);
    const duplicate = join(scratch, 'duplicate.mjs');
    await writeFile(duplicate, stub.replace('for await', `console.log('{}');\nfor await`), { mode: 0o700, flag: 'wx' });
    await assert.rejects(async () => {
      const rejected = await startPeer(duplicate, scratch, config, 'duplicate');
      try { await rejected.close(); }
      finally { await rejected.abort(); }
    }, /unsolicited fixture response/);
  } finally { await rm(scratch, { recursive: true }); }
});
