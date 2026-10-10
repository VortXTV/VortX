import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const workflow = readFileSync(new URL('../../.github/workflows/release-tvos.yml', import.meta.url), 'utf8');
function script(name) {
  const start = workflow.indexOf(`      - name: ${name}\n`);
  assert(start >= 0, name);
  const end = workflow.indexOf('\n      - ', start + 1);
  return workflow.slice(start, end < 0 ? undefined : end).split('        run: |\n')[1]
    .split('\n').map(line => line.replace(/^          /, '')).join('\n');
}
const download = script('Download and authenticate immutable handoff archives');
const proof = download.match(/ARTIFACT_ID="\$ID" UPLOAD_STEP="\$UPLOAD_STEP" python3 - <<'PY'\n([\s\S]*?)\nPY/);
assert(proof, 'execute the actual workflow upload-proof heredoc, not a test implementation');
function metadataGate(name) {
  const actual = script(name);
  const start = actual.indexOf('jq -e --argjson id "$ID"');
  const suffix = name.startsWith('Download') ? "' \"$HANDOFF_DIR/$ID.json\" >/dev/null" : "' \"$RUNNER_TEMP/source-artifact.json\" >/dev/null";
  const end = actual.indexOf(suffix, start);
  assert(start >= 0 && end >= start, name);
  return actual.slice(start, end + suffix.length);
}
const gates = [
  ['resume metadata', metadataGate('Validate immutable handoff provenance before coordinator resume')],
  ['download metadata', metadataGate('Download and authenticate immutable handoff archives')],
];
const source = 'c4ef656587d70f4f673f28d4766525f48f17897b';
const run = { id: 37976846977, run_attempt: 1, head_sha: source, head_branch: 'v0.5.0-beta.2',
  repository: { id: 1261501126 }, head_repository: { id: 1261501126 } };
const upload = (name, start, end) => ({ name, started_at: start, completed_at: end, status: 'completed', conclusion: 'success' });
const jobs = [{ id: 113977202330, name: 'build-tvos', steps: [
  upload('Upload the immutable app handoff', '2026-10-09T19:56:32Z', '2026-10-09T19:56:39Z'),
  upload('Upload the immutable feed handoff', '2026-10-09T19:56:39Z', '2026-10-09T19:56:40Z'),
] }];
const artifacts = [
  { id: 11642526112, name: 'VortX-tvOS-ci', size_in_bytes: 207639035,
    digest: 'sha256:871a6eed0531897b40204529488d724309735f293559bf075ce10db06d18099b' },
  { id: 11642361427, name: 'VortX-release-feed', size_in_bytes: 42700,
    digest: 'sha256:9b7539632ddead42779c0de3f03cc2f1c1e9f0598436817e98e1324d0faa10a1' },
].map(item => ({ ...item, created_at: '2026-10-09T19:56:40Z', expired: false,
  workflow_run: { id: run.id, head_sha: source, head_branch: run.head_branch,
    repository_id: run.repository.id, head_repository_id: run.head_repository.id } }));
// Retained authenticated run's six proof lines; no app bytes or private code.
const lines = [
  '2026-10-09T19:56:39.5626810Z SHA256 digest of uploaded artifact is 871a6eed0531897b40204529488d724309735f293559bf075ce10db06d18099b',
  '2026-10-09T19:56:39.8014950Z Artifact VortX-tvOS-ci successfully finalized. Artifact ID 11642526112',
  '2026-10-09T19:56:39.8017350Z Artifact VortX-tvOS-ci has been successfully uploaded! Final size is 207639035 bytes. Artifact ID is 11642526112',
  '2026-10-09T19:56:40.2190980Z SHA256 digest of uploaded artifact is 9b7539632ddead42779c0de3f03cc2f1c1e9f0598436817e98e1324d0faa10a1',
  '2026-10-09T19:56:40.4373350Z Artifact VortX-release-feed successfully finalized. Artifact ID 11642361427',
  '2026-10-09T19:56:40.4375580Z Artifact VortX-release-feed has been successfully uploaded! Final size is 42700 bytes. Artifact ID is 11642361427',
];
function fixture(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'vortx-upload-proof-'));
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}
function execute(index, { artifact = artifacts[index], steps = jobs[0].steps, log = lines.join('\n') + '\n', gate = null } = {}) {
  return fixture(dir => {
    for (const name of ['run', 'source-run']) writeFileSync(join(dir, `${name}.json`), JSON.stringify(run));
    for (const name of ['jobs', 'source-jobs']) writeFileSync(join(dir, `${name}.json`), JSON.stringify([{ ...jobs[0], steps }]));
    for (const name of [String(artifacts[index].id), 'source-artifact']) writeFileSync(join(dir, `${name}.json`), JSON.stringify(artifact));
    writeFileSync(join(dir, 'upload.log'), log);
    return spawnSync(gate ? '/bin/bash' : 'python3', gate ? ['-c', gate] : ['-c', proof[1]], {
      encoding: 'utf8', env: { ...process.env, RUNNER_TEMP: dir, HANDOFF_DIR: dir,
        ID: String(artifacts[index].id), ARTIFACT_ID: String(artifacts[index].id), NAME: artifacts[index].name,
        UPLOAD_STEP: jobs[0].steps[index].name },
    });
  });
}
function changedArtifact(index, changes) { return { ...structuredClone(artifacts[index]), ...changes }; }
function changedLine(index, stamp) {
  const result = [...lines]; result[index] = stamp + ' ' + result[index].split(' ').slice(1).join(' ');
  return result.join('\n');
}

test('both actual metadata gates and actual Python proof admit the exact Beta2 endpoint tuple', () => {
  for (const index of [0, 1]) {
    for (const [name, gate] of gates) {
      const result = execute(index, { gate }); assert.equal(result.status, 0, `${name}: ${result.stderr}`);
    }
    const result = execute(index); assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, new RegExp(`Authenticated exact upload proof for artifact ${artifacts[index].id}`));
  }
  assert.equal((download.match(/gh api -- "repos\/\$GH_REPO\/actions\/jobs\/\$UPLOAD_JOB_ID\/logs"/g) ?? []).length, 1);
  assert(download.indexOf('/actions/jobs/$UPLOAD_JOB_ID/logs') < download.indexOf('/actions/artifacts/$ID/zip'));
});
test('actual gates admit each step start, completed second, and exact represented endpoint', () => {
  for (const index of [0, 1]) for (const created_at of [jobs[0].steps[index].started_at, jobs[0].steps[index].completed_at,
    index === 0 ? '2026-10-09T19:56:40Z' : '2026-10-09T19:56:41Z']) {
    const artifact = changedArtifact(index, { created_at });
    for (const [label, gate] of gates) assert.equal(execute(index, { artifact, gate }).status, 0, label);
    const result = execute(index, { artifact }); assert.equal(result.status, 0, result.stderr);
  }
});

for (const [name, created_at] of Object.entries({
  'before upload start': '2026-10-09T19:56:31Z',
  'after the one represented second': '2026-10-09T19:56:41Z',
  'malformed timestamp': 'not-a-timestamp',
})) test(`actual metadata and proof gates reject API timestamp ${name}`, () => {
  const artifact = changedArtifact(0, { created_at });
  for (const [label, gate] of gates) assert.notEqual(execute(0, { artifact, gate }).status, 0, label);
  assert.notEqual(execute(0, { artifact }).status, 0);
});
test('actual Python gate rejects one microsecond beyond the API endpoint', () => {
  assert.notEqual(execute(0, { artifact: changedArtifact(0, { created_at: '2026-10-09T19:56:40.000001Z' }) }).status, 0);
});
for (const [name, mutate] of Object.entries({
  'wrong ID': item => { item.id++; }, 'wrong name': item => { item.name = 'other'; },
  'wrong run': item => { item.workflow_run.id++; }, 'wrong source': item => { item.workflow_run.head_sha = 'a'.repeat(40); },
  'wrong branch': item => { item.workflow_run.head_branch = 'main'; },
  'wrong repository': item => { item.workflow_run.repository_id++; }, 'wrong fork': item => { item.workflow_run.head_repository_id++; },
  'expired': item => { item.expired = true; }, 'missing digest': item => { delete item.digest; },
  'malformed digest': item => { item.digest = 'sha256:invalid'; }, 'zero size': item => { item.size_in_bytes = 0; },
})) test(`actual metadata gates reject ${name}`, () => {
  const artifact = structuredClone(artifacts[0]); mutate(artifact);
  for (const [label, gate] of gates) assert.notEqual(execute(0, { artifact, gate }).status, 0, label);
});

for (const key of ['id', 'name', 'size_in_bytes', 'digest']) test(`actual proof rejects changed exact ${key}`, () => {
  const artifact = structuredClone(artifacts[0]);
  artifact[key] = key === 'digest' ? `sha256:${'a'.repeat(64)}` : key === 'name' ? 'other' : artifact[key] + 1;
  assert.notEqual(execute(0, { artifact }).status, 0);
});
for (const index of [0, 1, 2]) {
  for (const [name, stamp] of Object.entries({
    'prestart': '2026-10-09T19:56:31.999999Z', 'exact excluded endpoint': '2026-10-09T19:56:40Z',
    'late': '2026-10-09T19:56:41Z', 'malformed': 'malformed', 'interior BOM': '2026-10-09T19:\ufeff56:39Z',
  })) test(`actual proof rejects ${['digest', 'finalized', 'uploaded'][index]} timestamp ${name}`, () => {
    assert.notEqual(execute(0, { log: changedLine(index, stamp) }).status, 0);
  });
  test(`actual proof rejects missing ${['digest', 'finalized', 'uploaded'][index]} line`, () => {
    assert.notEqual(execute(0, { log: lines.filter((_, i) => i !== index).join('\n') }).status, 0);
  });
  test(`actual proof rejects duplicate ${['digest', 'finalized', 'uploaded'][index]} line`, () => {
    assert.notEqual(execute(0, { log: [...lines, lines[index]].join('\n') }).status, 0);
  });
  test(`actual proof rejects decorated ${['digest', 'finalized', 'uploaded'][index]} line`, () => {
    const changed = [...lines]; changed[index] += ' unexpected trailer';
    assert.notEqual(execute(0, { log: changed.join('\n') }).status, 0);
  });
}
test('actual proof rejects digest/finalization/upload order inversions', () => {
  for (const [index, stamp] of [[0, '2026-10-09T19:56:39.9Z'], [2, '2026-10-09T19:56:39.7Z']])
    assert.notEqual(execute(0, { log: changedLine(index, stamp) }).status, 0);
});
for (const [name, mutate] of Object.entries({
  missing: steps => { steps.shift(); }, duplicate: steps => { steps.push(structuredClone(steps[0])); },
  failed: steps => { steps[0].conclusion = 'failure'; }, incomplete: steps => { steps[0].status = 'in_progress'; },
  'inverted interval': steps => { steps[0].started_at = '2026-10-09T19:56:41Z'; },
})) test(`actual metadata and proof gates reject ${name} upload step`, () => {
  const steps = structuredClone(jobs[0].steps); mutate(steps);
  for (const [label, gate] of gates) assert.notEqual(execute(0, { steps, gate }).status, 0, label);
  assert.notEqual(execute(0, { steps }).status, 0);
});
