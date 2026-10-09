import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const workflow = readFileSync(new URL('../../.github/workflows/release-tvos.yml', import.meta.url), 'utf8');
const recovery = readFileSync(new URL('../../.github/workflows/recover-release-feed.yml', import.meta.url), 'utf8');
function step(name) {
  const start = workflow.indexOf(`      - name: ${name}\n`);
  assert(start >= 0, name);
  const end = workflow.indexOf('\n      - ', start + 1);
  return workflow.slice(start, end < 0 ? undefined : end);
}
function script(name) {
  return step(name).split('        run: |\n')[1].split('\n').map(line => line.replace(/^          /, '')).join('\n');
}
function fixture(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'vortx-release-contract-'));
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}
const sha = 'c'.repeat(40), code = 'a'.repeat(40), tag = 'v0.4.0-beta.18';
const resume = { runId: 123, attempt: 2, appsArtifactId: 456, feedArtifactId: 457, sourceCommit: sha, build: '254' };
const upload = name => ({ name, status: 'completed', conclusion: 'success', started_at: '2026-10-01T12:00:00Z', completed_at: '2026-10-01T12:01:00Z' });
function evidence() {
  const run = { id: 123, run_attempt: 2, repository: { id: 1, full_name: 'VortXTV/VortX' }, head_repository: { id: 1, full_name: 'VortXTV/VortX' },
    path: '.github/workflows/release-tvos.yml', event: 'workflow_dispatch', head_sha: sha, head_branch: tag, status: 'completed', conclusion: 'failure' };
  const job = (name, conclusion, steps) => ({ name, conclusion, steps, head_sha: sha, run_id: 123, run_attempt: 2, status: 'completed' });
  const jobs = [job('build-tvos', 'success', [upload('Upload the immutable app handoff'), upload('Upload the immutable feed handoff')]),
    job('attach-release', 'failure', [upload('Attach only exact draft assets and create the authenticated staged receipt'),
      { ...upload('Atomically activate the staged feed, prove routes, then publish last'), conclusion: 'failure' }]), job('verify-published', 'skipped', [])];
  const artifact = (id, name) => ({ id, name, expired: false, size_in_bytes: 999, digest: `sha256:${'d'.repeat(64)}`, created_at: '2026-10-01T12:00:30Z',
    workflow_run: { id: 123, head_sha: sha, head_branch: tag, repository_id: 1, head_repository_id: 1 } });
  return { run, latest: structuredClone(run), jobs, apps: artifact(456, 'VortX-tvOS-ci'), feed: artifact(457, 'VortX-release-feed'), main: code,
    comparison: { status: 'ahead', merge_base_commit: { sha } } };
}
function provenance(data = evidence(), handoff = resume, overrides = {}) {
  return fixture(dir => {
    for (const [key, value] of Object.entries(data)) writeFileSync(join(dir, `${key}.json`), JSON.stringify(value));
    const result = spawnSync('bash', ['-c', `
gh() {
  case "\${*: -1}" in
    repos/VortXTV/VortX/git/ref/heads/main) jq -r . "$RUNNER_TEMP/main.json" ;;
    repos/VortXTV/VortX/compare/${sha}...${code}) command cat "$RUNNER_TEMP/comparison.json" ;;
    repos/VortXTV/VortX/actions/runs/123) command cat "$RUNNER_TEMP/latest.json" ;;
    repos/VortXTV/VortX/actions/runs/123/attempts/2) command cat "$RUNNER_TEMP/run.json" ;;
    repos/VortXTV/VortX/actions/runs/123/attempts/2/jobs?per_page=100) jq '[{jobs:.}]' "$RUNNER_TEMP/jobs.json" ;;
    repos/VortXTV/VortX/actions/artifacts/456) command cat "$RUNNER_TEMP/apps.json" ;;
    repos/VortXTV/VortX/actions/artifacts/457) command cat "$RUNNER_TEMP/feed.json" ;;
    *) echo 'unexpected API request' >&2; return 88 ;;
  esac
}
${script('Validate immutable handoff provenance before coordinator resume')}`], {
      encoding: 'utf8', env: { ...process.env, RUNNER_TEMP: dir, GITHUB_OUTPUT: join(dir, 'outputs'), GITHUB_REF: 'refs/heads/main', GITHUB_SHA: code,
        GITHUB_EVENT_NAME: 'workflow_dispatch', GH_REPO: 'VortXTV/VortX', TAG: tag, RESUME_HANDOFF: typeof handoff === 'string' ? handoff : JSON.stringify(handoff), ...overrides }
    });
    let outputs = '';
    try { outputs = readFileSync(join(dir, 'outputs'), 'utf8'); } catch {}
    return { ...result, outputs };
  });
}

test('actual protected coordinator condition admits only native successful tag builds or native main resumes', () => {
  const job = workflow.split('  attach-release:\n')[1].split('    concurrency:')[0];
  const expression = job.split('    if: >-\n')[1].trim().replaceAll('needs.build-tvos.result', 'result');
  const condition = new Function('github', 'inputs', 'result', 'cancelled', 'always', 'format', `return (${expression});`);
  const allowed = (result, ref, handoff = '', extra = {}, event = 'workflow_dispatch', cancelled = false) =>
    condition({ event_name: event, ref }, { resume_handoff: handoff, release_tag: tag, tvos_test_only: false, native_only: true, ...extra }, result,
      () => cancelled, () => true, (_, value) => `refs/tags/${value}`);
  assert(allowed('success', `refs/tags/${tag}`));
  for (const result of ['failure', 'cancelled', 'skipped']) assert(!allowed(result, `refs/tags/${tag}`));
  assert(allowed('skipped', 'refs/heads/main', '{}'));
  // A resume skips build-tvos and therefore must reject comparison mode independently of that
  // job's shell preflight. Exercise the actual release-write expression with full write inputs.
  for (const [result, ref, handoff] of [['success', `refs/tags/${tag}`, ''], ['skipped', 'refs/heads/main', '{}']]) {
    const release = { release_id: '123', publish_release: true };
    assert(allowed(result, ref, handoff, { ...release, native_only: true }));
    assert(!allowed(result, ref, handoff, { ...release, native_only: false }));
    assert(!allowed(result, ref, handoff, { ...release, native_only: undefined }));
  }
  for (const result of ['success', 'failure', 'cancelled']) assert(!allowed(result, 'refs/heads/main', '{}'));
  assert(!allowed('skipped', `refs/tags/${tag}`, '{}'));
  assert(!allowed('skipped', 'refs/heads/feature', '{}'));
  assert(!allowed('skipped', 'refs/heads/main', '{}', { tvos_test_only: true }));
  assert(!allowed('skipped', 'refs/heads/main', '{}', { release_tag: '' }));
  assert(!allowed('skipped', 'refs/heads/main', '{}', {}, 'push'));
  assert(!allowed('skipped', 'refs/heads/main', '{}', {}, 'workflow_dispatch', true));
  assert.match(workflow, /if: github.event_name != 'release' && inputs.resume_handoff == ''/);
  const coordinator = workflow.split('  attach-release:\n')[1].split('  verify-published:\n')[0];
  assert.match(coordinator, /environment: release-approval/);
  assert.doesNotMatch(coordinator, /actions\/checkout|\b(?:bash|node|python3?) scripts\//);
  assert.doesNotMatch(coordinator, /(?:^|\n)\s*(?:export )?GITHUB_SHA=/);
  for (const [name, key, path] of [['apps', 'apps_id', 'out'], ['feed', 'feed_id', 'feed-artifact']]) {
    const download = step(`Download only the approved original ${name} artifact`);
    assert(download.includes(`artifact-ids: \${{ steps.handoff.outputs.${key} }}`));
    assert(download.includes('run-id: ${{ steps.handoff.outputs.run_id }}'));
    assert(download.includes('merge-multiple: true'));
    assert(download.includes(`path: ${path}`));
    assert(!download.includes('\n          name:'));
  }
});

test('executable provenance accepts coordinator-only failure and keeps code/build commits separate', () => {
  const result = provenance();
  assert.equal(result.status, 0, result.stderr);
  assert(result.outputs.includes(`build_source_sha=${sha}\n`));
  assert(result.stdout.includes(`Reviewed coordinator ${code} resumes source ${sha}`));
  assert(result.outputs.includes('expected_build=254\n'));
  const successful = evidence();
  successful.latest.conclusion = successful.run.conclusion = 'success';
  successful.jobs[1].conclusion = 'success';
  successful.jobs[1].steps[1].conclusion = 'success';
  assert.equal(provenance(successful).status, 0);
  const normal = provenance(evidence(), '');
  assert.equal(normal.status, 0);
  assert.equal(normal.outputs, `build_source_sha=${code}\n`);
});

for (const [name, mutate] of Object.entries({
  'wrong repository': e => { e.run.repository.full_name = 'other/repo'; },
  'fork source': e => { e.run.head_repository.full_name = 'fork/VortX'; },
  'missing repository IDs': e => { delete e.run.repository.id; delete e.run.head_repository.id; delete e.apps.workflow_run.repository_id; delete e.apps.workflow_run.head_repository_id; },
  'wrong workflow path': e => { e.run.path = '.github/workflows/other.yml'; },
  'wrong event': e => { e.run.event = 'push'; },
  'wrong source commit': e => { e.run.head_sha = code; },
  'wrong source tag': e => { e.run.head_branch = 'main'; },
  'wrong run': e => { e.run.id++; },
  'wrong attempt': e => { e.run.run_attempt--; },
  'newer attempt exists': e => { e.latest.run_attempt++; },
  'run incomplete': e => { e.run.status = 'in_progress'; },
  'cancelled run': e => { e.run.conclusion = 'cancelled'; },
  'build failed': e => { e.jobs[0].conclusion = 'failure'; },
  'build skipped': e => { e.jobs[0].conclusion = 'skipped'; },
  'build missing': e => { e.jobs.shift(); },
  'duplicate build': e => { e.jobs.push(e.jobs[0]); },
  'wrong job attempt': e => { e.jobs[0].run_attempt--; },
  'wrong job head': e => { e.jobs[0].head_sha = code; },
  'other job failed': e => { e.jobs[2].conclusion = 'failure'; },
  'receipt not accepted': e => { e.jobs[1].steps[0].conclusion = 'failure'; },
  'successful run without coordinator': e => { e.latest.conclusion = e.run.conclusion = 'success'; e.jobs.splice(1, 1); },
  'successful run with skipped coordinator': e => { e.latest.conclusion = e.run.conclusion = 'success'; e.jobs[1].conclusion = 'skipped'; },
  'successful run without accepted receipt': e => { e.latest.conclusion = e.run.conclusion = 'success'; e.jobs[1].conclusion = 'success'; e.jobs[1].steps = []; },
  'different coordinator failure': e => { e.jobs[1].steps[1].name = 'Download the built apps'; },
  'artifact missing': e => { e.feed = {}; },
  'artifact expired': e => { e.apps.expired = true; },
  'artifact wrong ID': e => { e.apps.id++; },
  'artifact wrong name': e => { e.apps.name = 'other'; },
  'artifact wrong run': e => { e.apps.workflow_run.id++; },
  'artifact wrong head': e => { e.feed.workflow_run.head_sha = code; },
  'artifact wrong repository': e => { e.feed.workflow_run.repository_id++; },
  'artifact wrong fork': e => { e.feed.workflow_run.head_repository_id++; },
  'artifact digest absent': e => { delete e.apps.digest; },
  'artifact from previous attempt': e => { e.apps.created_at = '2026-09-30T12:00:30Z'; },
  'artifact upload failed': e => { e.jobs[0].steps[0].conclusion = 'failure'; },
  'artifact upload absent': e => { e.jobs[0].steps = []; },
  'main advanced': e => { e.main = sha; },
  'unreviewed divergent source': e => { e.comparison.status = 'diverged'; },
  'source not ancestor of coordinator': e => { e.comparison.merge_base_commit.sha = code; }
})) {
  test(`executable provenance rejects ${name}`, () => {
    const data = evidence(); mutate(data);
    const result = provenance(data);
    assert.notEqual(result.status, 0, name);
    assert.equal(result.outputs, '', 'must not emit approved artifact IDs on failure');
  });
}
test('resume input is strict and requires current main dispatch', () => {
  for (const handoff of ['not json', {}, { ...resume, extra: true }, { ...resume, runId: '../123' }, { ...resume, appsArtifactId: 457 },
    { ...resume, attempt: 1.5 }, { ...resume, build: '254\nmalicious' }, { ...resume, sourceCommit: 'main' }]) {
    assert.notEqual(provenance(evidence(), handoff).status, 0);
  }
  assert.notEqual(provenance(evidence(), resume, { GITHUB_REF: `refs/tags/${tag}` }).status, 0);
  assert.notEqual(provenance(evidence(), resume, { GITHUB_EVENT_NAME: 'push' }).status, 0);
});

test('actual coordinator blob and recovery forward/rollback JSON retain every byte above 128 KiB', () => fixture(dir => {
  const bytes = Buffer.from(JSON.stringify({ notes: 'Unicode 🌍 café; literal $() `text` \\ "\r\n'.repeat(7000), versions: Array.from({ length: 250 }, (_, build) => ({ build })) }, null, 2) + '\n\n');
  assert(bytes.length > 128 * 1024);
  for (const file of ['source.json', 'current-main-source.json', 'target-source.json']) writeFileSync(join(dir, file), bytes);
  const promotion = script('Atomically activate the staged feed, prove routes, then publish last');
  const commit = promotion.slice(promotion.indexOf('commit_source_bytes() {'), promotion.indexOf('\nrollback_source() {'));
  const result = spawnSync('bash', ['-c', `set -euo pipefail
gh() {
  case "\${*: -1}" in
    */git/ref/heads/main) printf '%s' '${code}' ;;
    */git/commits/${code}) printf '%s' '${sha}' ;;
    */git/blobs) command cat > "$RUNNER_TEMP/blob.json"; printf '%s' '${sha}' ;;
    */git/trees) command cat > "$RUNNER_TEMP/tree.json"; printf '%s' '${sha}' ;;
    */git/commits) command cat > "$RUNNER_TEMP/commit.json"; printf '%s' '${sha}' ;;
    */git/refs/heads/main) command cat > "$RUNNER_TEMP/ref.json" ;;
    *) return 88 ;;
  esac
}
${commit}
commit_source_bytes "$RUNNER_TEMP/source.json" 'fixture feed' '${code}'`], { encoding: 'utf8', env: { ...process.env, RUNNER_TEMP: dir, GH_REPO: 'VortXTV/VortX' } });
  assert.equal(result.status, 0, result.stderr);
  const blob = JSON.parse(readFileSync(join(dir, 'blob.json'), 'utf8'));
  assert.equal(blob.encoding, 'base64');
  assert.deepEqual(Buffer.from(blob.content, 'base64'), bytes);
  const commitPayload = JSON.parse(readFileSync(join(dir, 'commit.json'), 'utf8'));
  assert.deepEqual(commitPayload.parents, [code]);
  assert.equal(commitPayload.author.name, 'Mamaclapper');
  assert.equal(commitPayload.committer.name, 'Mamaclapper');
  assert.equal(JSON.parse(readFileSync(join(dir, 'ref.json'), 'utf8')).force, false);
  const writes = recovery.split('\n').filter(line => line.includes('jq -cn --arg message') && line.includes('--rawfile source'));
  assert.equal(writes.length, 2, 'forward and compensation must both use file-backed source');
  for (const line of writes) {
    const cmd = line.trim().split(' | gh api')[0];
    const payload = spawnSync('bash', ['-c', cmd], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
      env: { ...process.env, RUNNER_TEMP: dir, sha: code, CURRENT_SHA: code } });
    assert.equal(payload.status, 0, payload.stderr);
    const body = JSON.parse(payload.stdout);
    assert.deepEqual(Buffer.from(body.content, 'base64'), bytes);
    assert.equal(body.sha, code);
    assert.equal(body.branch, 'main');
    assert.equal(body.author.name, 'Mamaclapper');
    assert.equal(body.committer.name, 'Mamaclapper');
  }
  assert.doesNotMatch(workflow + recovery, /--arg content "\$(source_b64|TARGET_B64)"/);
}));

test('identity binds manifest, tag peel, release and every feed checksum before any mutation', () => fixture(dir => {
  const manifest = { schemaVersion: 2, tag, sourceCommit: sha, build: 254, releaseId: '42', prerelease: false, android: null };
  const fileNames = { sourceSha256: 'source.json', appcastSha256: 'appcast.json', checksumSha256: 'SHA256SUMS-ci.txt' };
  // Place the fixture handoff in its actual relative directory consumed by the inline workflow.
  const feedDir = mkdtempSync(join(dir, 'feed-'));
  const identity = script('Bind the draft release, tag commit, and monotonic source before any write');
  const prefix = identity.slice(0, identity.indexOf('\nMAIN_REF='));
  for (const [key, file] of Object.entries(fileNames)) {
    const bytes = `fixture ${file}\n`;
    writeFileSync(join(feedDir, file), bytes);
    manifest[key] = createHash('sha256').update(bytes).digest('hex');
  }
  const release = { id: 42, tag_name: tag, draft: true, prerelease: false, body: '<!-- vortx-channel: latest-beta -->' };
  const check = (input = manifest, target = release, tagSha = sha) => {
    writeFileSync(join(feedDir, 'manifest.json'), JSON.stringify(input));
    writeFileSync(join(dir, 'release.json'), JSON.stringify(target));
    return spawnSync('bash', ['-c', `
gh() {
  case "\${*: -1}" in
    repos/VortXTV/VortX/releases/42) command cat "$RUNNER_TEMP/release.json" ;;
    repos/VortXTV/VortX/git/ref/tags/${tag}) printf '%s' '{"object":{"type":"tag","sha":"${code}"}}' ;;
    repos/VortXTV/VortX/git/tags/${code}) printf '%s' '{"object":{"type":"commit","sha":"${tagSha}"}}' ;;
    *) return 88 ;;
  esac
}
${prefix.replaceAll('feed-artifact/', `${feedDir}/`)}`], { encoding: 'utf8', env: { ...process.env, RUNNER_TEMP: dir,
      GH_REPO: 'VortXTV/VortX', TAG: tag, BUILD_SOURCE_SHA: sha, GITHUB_SHA: code, EXPECTED_BUILD: '254', RELEASE_ID_INPUT: '42', APPLE_ONLY_INPUT: 'false' } });
  };
  const result = check(); assert.equal(result.status, 0, result.stderr);
  for (const invalid of [{ sourceCommit: code }, { schemaVersion: 1 }, { build: 253 }, { tag: 'v0.4.0-beta.17' }, { releaseId: '43' },
    { prerelease: true }, { android: {} }, { sourceSha256: '0'.repeat(64) }, { appcastSha256: '0'.repeat(64) }, { checksumSha256: '0'.repeat(64) }]) {
    assert.notEqual(check({ ...manifest, ...invalid }).status, 0, JSON.stringify(invalid));
  }
  assert.notEqual(check(manifest, { ...release, draft: false }).status, 0);
  assert.notEqual(check(manifest, { ...release, id: 43 }).status, 0);
  assert.notEqual(check(manifest, release, code).status, 0, 'tag must peel to original build source, not coordinator code');
}));
