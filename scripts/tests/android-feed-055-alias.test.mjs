import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const workflow = readFileSync(new URL('../../.github/workflows/augment-android-release-feed.yml', import.meta.url), 'utf8');
const block = workflow.split('          # BEGIN PINNED 0.5.5 RC HANDOFF:')[1]?.split('          # END PINNED 0.5.5 RC HANDOFF')[0];
assert.ok(block, 'exercise the actual workflow guard, not a second implementation');
const source = '35761135a71867d23a9c4ee83cbdb31fe65747bd';
const object = 'c89a4a24326a8683910afc28b569ca783cfcad7a';
const provenanceSha = 'e42939673bec0dff481c5b885d228f3c285978bf033497525e31b6c60d3dafc7';
const fullSha = 'b61a02a8da6dfd2aa24cb56e0f17c8b73a24605fac8583538437f873f5e73a69';
const playSha = 'e630a09fe3d91fcb2e5c280a7813aebf085df9ef4cb556fe049dabb34d77b7cb';
const run = { id: 38966783085, run_attempt: 1, repository: { full_name: 'VortXTV/VortX' }, head_repository: { full_name: 'VortXTV/VortX' }, path: '.github/workflows/android-release.yml', event: 'workflow_dispatch', status: 'completed', conclusion: 'success', head_branch: 'v0.5.5-rc.1', head_sha: source };
const baseResponses = {
  'releases/latest': { id: 415681390, tag_name: 'v0.5.5', draft: false, prerelease: false },
  'git/ref/tags/v0.5.5': { object: { type: 'tag', sha: object } },
  [`git/tags/${object}`]: { tag: 'v0.5.5', object: { type: 'commit', sha: source } },
  'git/ref/tags/v0.5.5-rc.1': { object: { type: 'commit', sha: source } },
  'actions/runs/38966783085': structuredClone(run),
  'actions/runs/38966783085/attempts/1': structuredClone(run),
};
const baseText = `release tag: v0.5.5-rc.1\nrelease tag commit: ${source}\nsource commit: ${source}\nAndroid versionCode: 274\nAndroid versionName: 0.5.5\n`;

function guard({ env = {}, text = baseText, mutate = () => {} } = {}) {
  const responses = structuredClone(baseResponses);
  mutate(responses);
  const dir = mkdtempSync(join(tmpdir(), 'android-feed-alias-'));
  try {
    writeFileSync(join(dir, 'SIGNING_PROVENANCE.txt'), text);
    // Fixture only the external hash/API boundaries; the real shell branch, jq predicates,
    // exact-line matching, pipes and fail-fast semantics execute unchanged.
    return spawnSync('bash', ['-c', `set -euo pipefail
sha256sum() { [ "$1" = "$RUNNER_TEMP/SIGNING_PROVENANCE.txt" ]; printf '%s  %s\\n' "$PROVENANCE_TEST_SHA" "$1"; }
gh() { [ "$1" = api ]; [ "$2" = -- ]; local key="${'${3#repos/VortXTV/VortX/}'}"; jq -ce --arg key "$key" '.[$key] // error("unexpected API path")' <<<"$GH_RESPONSES"; }
${block.slice(block.indexOf('\n') + 1).replace(/^          /gm, '')}`], {
      encoding: 'utf8', timeout: 10000,
      env: { ...process.env, RUNNER_TEMP: dir, GH_REPO: 'VortXTV/VortX', RELEASE_ID: '415681390', TAG: 'v0.5.5', FULL_SHA: fullSha, PLAY_SHA: playSha, PROVENANCE_TEST_SHA: provenanceSha, RELEASE_JSON: '{"prerelease":false}', GH_RESPONSES: JSON.stringify(responses), ...env },
    });
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test('pinned same-commit RC signing record is accepted without modifying it', () => {
  const result = guard();
  assert.equal(result.status, 0, result.stderr);
});

test('ordinary releases retain the exact-tag path and cannot use the RC prefix', () => {
  assert.equal(guard({ env: { TAG: 'v0.5.6' }, text: 'release tag: v0.5.6\n' }).status, 0);
  assert.notEqual(guard({ env: { TAG: 'v0.5.6' }, text: 'release tag: v0.5.6-rc.1\n' }).status, 0);
  assert.notEqual(guard({ env: { TAG: 'v0.5.5-rc.2' } }).status, 0);
});

test('one-release exception rejects wrong repository, release, hashes and prerelease', () => {
  for (const env of [
    { GH_REPO: 'attacker/VortX' }, { RELEASE_ID: '415681391' },
    { PROVENANCE_TEST_SHA: '0'.repeat(64) }, { FULL_SHA: '0'.repeat(64) }, { PLAY_SHA: '0'.repeat(64) },
    { RELEASE_JSON: '{"prerelease":true}' },
  ]) assert.notEqual(guard({ env }).status, 0, JSON.stringify(env));
});

test('one-release exception rejects changed version/build/source and rewritten final-tag provenance', () => {
  for (const [before, after] of [
    ['Android versionCode: 274', 'Android versionCode: 275'],
    ['Android versionName: 0.5.5', 'Android versionName: 0.5.6'],
    [`release tag commit: ${source}`, `release tag commit: ${'0'.repeat(40)}`],
    [`source commit: ${source}`, `source commit: ${'0'.repeat(40)}`],
    ['release tag: v0.5.5-rc.1', 'release tag: v0.5.5'],
  ]) assert.notEqual(guard({ text: baseText.replace(before, after) }).status, 0, after);
});

test('final/RC tags and Latest must have their exact authenticated identities', () => {
  const mutations = [
    r => { r['releases/latest'].id++; },
    r => { r['releases/latest'].draft = true; },
    r => { r['releases/latest'].prerelease = true; },
    r => { r['releases/latest'].tag_name = 'v0.5.6'; },
    r => { r['git/ref/tags/v0.5.5'].object.type = 'commit'; },
    r => { r['git/ref/tags/v0.5.5'].object.sha = '0'.repeat(40); },
    r => { r[`git/tags/${object}`].object.sha = '0'.repeat(40); },
    r => { r[`git/tags/${object}`].object.type = 'tag'; },
    r => { r[`git/tags/${object}`].tag = 'v0.5.6'; },
    r => { r['git/ref/tags/v0.5.5-rc.1'].object.type = 'tag'; },
    r => { r['git/ref/tags/v0.5.5-rc.1'].object.sha = '0'.repeat(40); },
  ];
  for (const mutate of mutations) assert.notEqual(guard({ mutate }).status, 0);
});

test('original and latest Android run must independently retain exact successful attempt identity', () => {
  for (const path of ['actions/runs/38966783085', 'actions/runs/38966783085/attempts/1']) {
    for (const [key, value] of Object.entries({ id: 1, run_attempt: 2, path: '.github/workflows/android.yml', event: 'push', status: 'in_progress', conclusion: 'failure', head_branch: 'v0.5.5', head_sha: '0'.repeat(40), repository: { full_name: 'foreign/repo' }, head_repository: { full_name: 'fork/repo' } })) {
      assert.notEqual(guard({ mutate: r => { r[path][key] = value; } }).status, 0, `${path}: ${key}`);
    }
  }
});

test('common signing and CAS/compensation checks remain present outside the alias block', () => {
  assert.match(workflow, /SIGNER SHA-256/);
  assert.match(workflow, /status_is_exact_predecessor/);
  assert.match(workflow, /MUTATION_ATTEMPTED=1/);
  assert.match(workflow, /expectedReceiptSha256:\$receipt/);
  assert.match(workflow, /without mutating release or source metadata/);
});
