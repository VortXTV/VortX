import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, mkdirSync, existsSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const workflow = readFileSync(new URL('../../.github/workflows/release-tvos.yml', import.meta.url), 'utf8');
const source = '844782d29a93ae51991bfadc639d50bc3619d40b', code = 'a'.repeat(40), tag = 'v0.5.0-beta.1';
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
  const dir = mkdtempSync(join(tmpdir(), 'vortx-source-recovery-'));
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}
function admission(overrides = {}, mutations = {}, workflowText = workflow) {
  return fixture(dir => {
    mkdirSync(join(dir, '.github/workflows'), { recursive: true });
    writeFileSync(join(dir, '.github/workflows/release-tvos.yml'), workflowText);
    const records = {
      main: code, comparison: { status: 'ahead', merge_base_commit: { sha: source } },
      tag: { object: { type: 'tag', sha: 'b'.repeat(40) } }, peel: { object: { type: 'commit', sha: source } },
      release: { id: 407572242, tag_name: tag, draft: true, prerelease: false, body: '<!-- vortx-channel: latest-beta -->' },
      ...mutations
    };
    for (const [key, value] of Object.entries(records)) writeFileSync(join(dir, `${key}.json`), JSON.stringify(value));
    return spawnSync('bash', ['-c', `
gh() {
  case "\${*: -1}" in
    */git/ref/heads/main) jq -r . "$RUNNER_TEMP/main.json" ;;
    */compare/*) command cat "$RUNNER_TEMP/comparison.json" ;;
    */git/ref/tags/*) command cat "$RUNNER_TEMP/tag.json" ;;
    */git/tags/*) command cat "$RUNNER_TEMP/peel.json" ;;
    */releases/407572242) command cat "$RUNNER_TEMP/release.json" ;;
    *) return 88 ;;
  esac
}
${script('Validate immutable Beta 1 source recovery')}`], { cwd: dir, encoding: 'utf8', env: { ...process.env,
      RUNNER_TEMP: dir, GH_REPO: 'VortXTV/VortX', GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/main', GITHUB_SHA: code,
      BUILD_SOURCE_SHA: source, TAG: tag, RELEASE_ID: '407572242', VORTX_NATIVE_ONLY: 'true', TVOS_TEST_ONLY: 'false',
      RESUME_HANDOFF: '', MPVKIT_URL: '', MPVKIT_SHA: '', ...overrides } });
  });
}

test('actual recovery admission accepts exactly the main-only immutable cut and annotated tag peel', () => {
  const result = admission(); assert.equal(result.status, 0, result.stderr);
  assert.equal(admission({}, { tag: { object: { type: 'commit', sha: source } } }).status, 0);
  for (const invalid of [
    { GITHUB_EVENT_NAME: 'push' }, { GITHUB_REF: `refs/tags/${tag}` }, { GITHUB_REF: 'refs/heads/feature' },
    { GH_REPO: 'fork/VortX' }, { BUILD_SOURCE_SHA: code }, { TAG: 'v0.5.0-beta.2' }, { RELEASE_ID: '407572243' },
    { VORTX_NATIVE_ONLY: 'false' }, { TVOS_TEST_ONLY: 'true' }, { RESUME_HANDOFF: '{}' },
    { MPVKIT_URL: 'https://github.com/VortXTV/VortX/releases/download/other/player.zip' }, { MPVKIT_SHA: 'd'.repeat(64) }
  ]) assert.notEqual(admission(invalid).status, 0, JSON.stringify(invalid));
  for (const invalid of [
    { main: source }, { comparison: { status: 'diverged', merge_base_commit: { sha: source } } },
    { comparison: { status: 'ahead', merge_base_commit: { sha: code } } },
    { peel: { object: { type: 'commit', sha: code } } }, { peel: { object: { type: 'tree', sha: source } } },
    { peel: { object: { type: 'tag', sha: code } } },
    ...[{ draft: false }, { id: 407572243 }, { tag_name: 'v0.5.0-beta.2' }, { prerelease: true }]
      .map(change => ({ release: { id: 407572242, tag_name: tag, draft: true, prerelease: false, body: '<!-- vortx-channel: latest-beta -->', ...change } }))
  ]) assert.notEqual(admission({}, invalid).status, 0, JSON.stringify(invalid));
  const native = step('Fetch vortx-core (private monorepo, pinned)');
  assert.notEqual(admission({}, {}, workflow.replace(native, native.replace('7e3e68be5bf2b11c65d158c1823be94bd1608d1b', code))).status, 0);
  const player = step('Fetch the MPVKit-DVFEL artifacts (pinned, sha256-verified)');
  for (const changed of [player.replace('vendor-mpvkit-dvfel-3/', 'vendor-mpvkit-dvfel-4/'),
    player.replace('737073f587b4d78c0436d3dc08c40bfab72b26e3d3a3ac3eab11a7a3a1c288d1', 'd'.repeat(64))]) {
    assert.notEqual(admission({}, {}, workflow.replace(player, changed)).status, 0);
  }
});

test('signing precedes first native app acceptance and packaging contains no signing mutation', () => fixture(dir => {
  const signing = 'Final-sign macOS before native app acceptance', acceptance = 'Verify exact native app selection and linked inputs';
  assert(workflow.indexOf(`- name: ${signing}`) < workflow.indexOf(`- name: ${acceptance}`));
  const packaging = step('Package the IPAs');
  assert.doesNotMatch(packaging, /codesign.*(?:--force|--sign|--remove-signature)/);
  assert.match(packaging, /codesign --verify --deep --strict/);
  assert.match(packaging, /verify-archive --app-receipt out\/native-macos.json/);
  const result = spawnSync('/bin/bash', ['-c', `
codesign() { printf 'codesign:%s\\n' "$*"; }
${script(signing)}
python3() { printf 'accept:%s\\n' "$*"; }
${script(acceptance)}`], { encoding: 'utf8', env: { ...process.env, TVOS_TEST_ONLY: 'false', NATIVE_PACKAGE_VERIFIER_DIR: '/reviewed verifier' } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^codesign:--force --deep --sign - .*VortX.app\ncodesign:--verify --deep --strict .*VortX.app\naccept:/);
  assert(result.stdout.includes('--receipt out/native-macos.json'));
  assert.equal((workflow.match(/codesign --force --deep --sign -/g) ?? []).length, 1);
}));

test('recovery preserves only the verifier outside the source checkout and retains native, feed and environment gates', () => {
  const preserve = workflow.indexOf('- name: Preserve the workflow revision\'s native acceptance tool');
  const checkout = workflow.indexOf('- name: Checkout the immutable recovered app source');
  assert(preserve < checkout);
  assert.match(step('Checkout the immutable recovered app source'), /ref: \$\{\{ env.BUILD_SOURCE_SHA \}\}/);
  assert.match(step('Verify immutable recovered source checkout'), /git status --porcelain/);
  assert.match(workflow, /environment: engine-ci/);
  assert.match(workflow, /environment: release-approval/);
  assert.match(step('Fetch vortx-core (private monorepo, pinned)'), /ref: 7e3e68be5bf2b11c65d158c1823be94bd1608d1b/);
  assert.match(step('Fetch the MPVKit-DVFEL artifacts (pinned, sha256-verified)'), /vendor-mpvkit-dvfel-3\/mpvkit-dvfel-artifacts-http-seek-20261009.zip/);
  assert.match(step('Build the content-addressed release feed artifact'), /--source-commit "\$BUILD_SOURCE_SHA"/);
  assert.doesNotMatch(step('Build the content-addressed release feed artifact'), /\$GITHUB_SHA/);
  assert.match(step('Bind the draft release, tag commit, and monotonic source before any write'), /TAG_SHA" = "\$BUILD_SOURCE_SHA/);
  assert.doesNotMatch(workflow, /(?:^|\n)\s*(?:export )?GITHUB_SHA=/);
});

test('verifier location is created at step runtime and exported with the exact accepted tool bytes', () => fixture(dir => {
  const jobEnvironment = workflow.match(/^    env:\n([\s\S]*?)^    steps:/m)?.[1];
  assert(jobEnvironment, 'build job environment exists');
  assert.doesNotMatch(jobEnvironment, /\b(?:runner|env|steps)\./, 'runner/step contexts are unavailable in job-level env');
  mkdirSync(join(dir, 'scripts'));
  const bytes = '# fixture verifier bytes retained without execution\n';
  writeFileSync(join(dir, 'scripts/verify-native-apple-package.py'), bytes);
  const result = spawnSync('/bin/bash', ['-c', script("Preserve the workflow revision's native acceptance tool")], {
    cwd: dir, encoding: 'utf8', env: { ...process.env, RUNNER_TEMP: dir, GITHUB_ENV: join(dir, 'environment'), GITHUB_OUTPUT: join(dir, 'outputs') }
  });
  assert.equal(result.status, 0, result.stderr);
  const exported = readFileSync(join(dir, 'environment'), 'utf8').trim();
  assert(exported.startsWith(`NATIVE_PACKAGE_VERIFIER_DIR=${dir}/native-acceptance.`));
  const verifierDirectory = exported.split('=', 2)[1];
  assert.equal(readFileSync(join(verifierDirectory, 'verify-native-apple-package.py'), 'utf8'), bytes);
  assert.equal(readFileSync(join(dir, 'outputs'), 'utf8'), `verifier_sha256=${createHash('sha256').update(bytes).digest('hex')}\n`);
  assert.match(step('Capture exact native SDK and player inputs before app compilation'),
    /python3 "\$NATIVE_PACKAGE_VERIFIER_DIR"\/verify-native-apple-package\.py snapshot/);
}));

test('coordinator checks the recovered verifier against GitHub workflow bytes and exact run provenance', () => fixture(dir => {
  mkdirSync(join(dir, 'out'));
  const verifier = 'reviewed acceptance tool bytes\n', digest = createHash('sha256').update(verifier).digest('hex');
  const receipt = { schemaVersion: 1, sourceCommit: source, workflowCommit: code, verifierSha256: digest, tag, runId: 123, attempt: 2 };
  const identity = script('Bind the draft release, tag commit, and monotonic source before any write');
  const prefix = identity.slice(0, identity.indexOf('\njq -e --arg tag "$TAG" --arg commit'));
  const verify = (changes = {}) => {
    writeFileSync(join(dir, 'out/native-workflow-provenance.json'), JSON.stringify({ ...receipt, ...changes }));
    return spawnSync('bash', ['-c', `
gh() { printf '%s' '${JSON.stringify({ content: Buffer.from(verifier).toString('base64') })}'; }
${prefix}`], { cwd: dir, encoding: 'utf8', env: { ...process.env, RUNNER_TEMP: dir, GH_REPO: 'VortXTV/VortX', TAG: tag,
      BUILD_SOURCE_SHA: source, BUILD_WORKFLOW_SHA: code, BUILD_RUN_ID: '123', BUILD_ATTEMPT: '2' } });
  };
  const result = verify(); assert.equal(result.status, 0, result.stderr);
  for (const change of [{ sourceCommit: code }, { workflowCommit: source }, { verifierSha256: 'd'.repeat(64) },
    { tag: 'v0.5.0-beta.2' }, { runId: 124 }, { attempt: 1 }, { schemaVersion: 2 }]) {
    assert.notEqual(verify(change).status, 0, JSON.stringify(change));
  }
}));

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
function zip(entries) {
  const generated = spawnSync('python3', ['-c', `
import base64, io, json, sys, zipfile
archive = io.BytesIO()
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as output:
    for entry in json.load(sys.stdin):
        info = zipfile.ZipInfo(entry['name'])
        info.create_system = 3
        info.external_attr = entry.get('mode', 0o100600) << 16
        output.writestr(info, base64.b64decode(entry['base64']))
sys.stdout.buffer.write(archive.getvalue())`], { input: JSON.stringify(entries.map(({ bytes, ...entry }) =>
    ({ ...entry, base64: Buffer.from(bytes).toString('base64') }))) });
  assert.equal(generated.status, 0, generated.stderr?.toString());
  return generated.stdout;
}
function handoffBytes(label = 'accepted') {
  const packages = [['tvOS', 'ipa'], ['tvOS-lite', 'ipa'], ['iOS', 'ipa'], ['macOS', 'dmg']].map(([platform, extension]) =>
    ({ name: `VortX-${platform}-${tag}-ci.${extension}`, bytes: Buffer.from(`${label} ${platform} payload`) }));
  const checksum = packages.map(file => `${sha256(file.bytes)}  ${file.name}\n`).join('');
  const manifest = { schemaVersion: 2, tag, sourceCommit: source, build: '260', releaseId: '407572242',
    assets: Object.fromEntries(packages.map(file => [file.name, { name: file.name, size: file.bytes.length, sha256: sha256(file.bytes) }])) };
  const apps = [...packages, { name: 'SHA256SUMS-ci.txt', bytes: checksum },
    { name: 'native-workflow-provenance.json', bytes: JSON.stringify({ sourceCommit: source, workflowCommit: code }) }];
  const feed = [{ name: 'source.json', bytes: '{}' }, { name: 'appcast.json', bytes: '{}' },
    { name: 'manifest.json', bytes: JSON.stringify(manifest) }, { name: 'SHA256SUMS-ci.txt', bytes: checksum }];
  return { apps, feed, appsZip: zip(apps), feedZip: zip(feed) };
}
const acceptedBytes = handoffBytes();
const uploadStep = name => ({ name, status: 'completed', conclusion: 'success',
  started_at: '2026-10-09T12:00:00Z', completed_at: '2026-10-09T12:01:00Z' });
function downloadEvidence() {
  const run = { id: 123, run_attempt: 2, repository: { id: 1, full_name: 'VortXTV/VortX' }, head_repository: { id: 1, full_name: 'VortXTV/VortX' },
    path: '.github/workflows/release-tvos.yml', event: 'workflow_dispatch', head_sha: code, head_branch: 'main', status: 'in_progress' };
  const jobs = [{ name: 'build-tvos', head_sha: code, run_id: 123, run_attempt: 2, status: 'completed', conclusion: 'success',
    steps: [uploadStep('Upload the immutable app handoff'), uploadStep('Upload the immutable feed handoff')] }];
  const artifact = (id, name, bytes) => ({ id, name, expired: false, size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`,
    created_at: '2026-10-09T12:00:30Z', workflow_run: { id: 123, head_sha: code, head_branch: 'main', repository_id: 1, head_repository_id: 1 } });
  return { run, jobs, apps: artifact(456, 'VortX-tvOS-ci', acceptedBytes.appsZip), feed: artifact(457, 'VortX-release-feed', acceptedBytes.feedZip),
    appsZip: acceptedBytes.appsZip, feedZip: acceptedBytes.feedZip };
}
function downloadHandoff(data, before = () => {}) {
  return fixture(dir => {
    for (const key of ['run', 'jobs', 'apps', 'feed']) writeFileSync(join(dir, `${key}.json`), JSON.stringify(data[key]));
    writeFileSync(join(dir, 'apps.zip'), data.appsZip);
    writeFileSync(join(dir, 'feed.zip'), data.feedZip);
    before(dir);
    const result = spawnSync('bash', ['-c', `
gh() {
  printf '%s\\n' "$*" >> "$RUNNER_TEMP/api-calls"
  case "\${*: -1}" in
    repos/VortXTV/VortX/actions/runs/123) command cat "$RUNNER_TEMP/run.json" ;;
    repos/VortXTV/VortX/actions/runs/123/attempts/2/jobs?per_page=100) jq '[{jobs:.}]' "$RUNNER_TEMP/jobs.json" ;;
    repos/VortXTV/VortX/actions/artifacts/456) command cat "$RUNNER_TEMP/apps.json" ;;
    repos/VortXTV/VortX/actions/artifacts/457) command cat "$RUNNER_TEMP/feed.json" ;;
    repos/VortXTV/VortX/actions/artifacts/456/zip) command cat "$RUNNER_TEMP/apps.zip" ;;
    repos/VortXTV/VortX/actions/artifacts/457/zip) command cat "$RUNNER_TEMP/feed.zip" ;;
    *) echo 'unapproved endpoint or mutation' >&2; return 88 ;;
  esac
}
${script('Download and authenticate immutable handoff archives')}
printf 'reached coordinator mutation boundary\\n' > "$RUNNER_TEMP/coordinator-writes"
`], { cwd: dir, encoding: 'utf8', env: { ...process.env, RUNNER_TEMP: dir, GH_REPO: 'VortXTV/VortX', TAG: tag,
      APPS_ID: '456', FEED_ID: '457', BUILD_RUN_ID: '123', BUILD_ATTEMPT: '2', BUILD_WORKFLOW_SHA: code, BUILD_BRANCH: 'main' } });
    return { ...result, writes: existsSync(join(dir, 'coordinator-writes')), appsExist: existsSync(join(dir, 'out')),
      feedExists: existsSync(join(dir, 'feed-artifact')), calls: readFileSync(join(dir, 'api-calls'), 'utf8'),
      payload: existsSync(join(dir, 'out', acceptedBytes.apps[0].name)) ? readFileSync(join(dir, 'out', acceptedBytes.apps[0].name)) : null,
      sentinel: existsSync(join(dir, 'sentinel')) ? readFileSync(join(dir, 'sentinel'), 'utf8') : null };
  });
}
function authenticateChangedZip(data, key, entries) {
  data[`${key}Zip`] = zip(entries);
  data[key].digest = `sha256:${sha256(data[`${key}Zip`])}`;
  data[key].size_in_bytes = data[`${key}Zip`].length;
}

test('exact API IDs download once and the same authenticated ZIP bytes reach the coordinator', () => {
  const result = downloadHandoff(downloadEvidence());
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.writes, true);
  assert.equal(result.feedExists, true);
  assert.deepEqual(result.payload, acceptedBytes.apps[0].bytes);
  assert.equal((result.calls.match(/artifacts\/456\/zip/g) ?? []).length, 1);
  assert.equal((result.calls.match(/artifacts\/457\/zip/g) ?? []).length, 1);
  assert.doesNotMatch(result.calls, /--method|POST|PATCH|PUT|DELETE/);
  assert.match(result.stdout, /both authenticated artifact ZIPs extracted after exact digest/);
});

for (const [name, mutate] of Object.entries({
  'missing API digest': e => { delete e.apps.digest; },
  'invalid API digest': e => { e.apps.digest = 'sha256:wrong'; },
  'wrong API digest': e => { e.apps.digest = `sha256:${'d'.repeat(64)}`; },
  'altered apps ZIP bytes': e => { e.appsZip = Buffer.concat([e.appsZip, Buffer.from('changed archive')]); },
  'altered feed ZIP after valid apps ZIP': e => { e.feedZip = Buffer.concat([e.feedZip, Buffer.from('changed archive')]); },
  'self-consistent altered package and manifest ZIPs': e => {
    const changed = handoffBytes('substituted');
    const manifest = JSON.parse(changed.feed.find(file => file.name === 'manifest.json').bytes);
    assert.equal(manifest.assets[changed.apps[0].name].sha256, sha256(changed.apps[0].bytes));
    e.appsZip = changed.appsZip; e.feedZip = changed.feedZip;
  },
  'wrong latest run attempt': e => { e.run.run_attempt++; },
  'wrong build job attempt': e => { e.jobs[0].run_attempt--; },
  'previous attempt artifact timestamp': e => { e.apps.created_at = '2026-10-08T12:00:30Z'; },
  'failed uploader step': e => { e.jobs[0].steps[0].conclusion = 'failure'; },
  'wrong exact artifact ID': e => { e.apps.id++; },
  'wrong exact artifact name': e => { e.feed.name = 'other-feed'; },
  'wrong artifact run': e => { e.feed.workflow_run.id++; },
  'wrong artifact workflow SHA': e => { e.apps.workflow_run.head_sha = source; },
  'wrong artifact repository': e => { e.apps.workflow_run.repository_id++; },
  'expired archive': e => { e.apps.expired = true; },
  'no successful build': e => { e.jobs[0].conclusion = 'failure'; },
  'duplicate build evidence': e => { e.jobs.push(e.jobs[0]); },
  'archive path traversal': e => { authenticateChangedZip(e, 'apps', [...acceptedBytes.apps, { name: '../escape', bytes: 'escape' }]); },
  'archive absolute path': e => { authenticateChangedZip(e, 'apps', [...acceptedBytes.apps, { name: '/escape', bytes: 'escape' }]); },
  'archive backslash path': e => { authenticateChangedZip(e, 'apps', [...acceptedBytes.apps, { name: '..\\escape', bytes: 'escape' }]); },
  'archive symlink': e => { authenticateChangedZip(e, 'apps', [...acceptedBytes.apps, { name: 'native-link.json', bytes: '../escape', mode: 0o120777 }]); },
  'archive special file': e => { authenticateChangedZip(e, 'apps', [...acceptedBytes.apps, { name: 'native-pipe.json', bytes: 'pipe', mode: 0o010600 }]); },
  'duplicate archive member': e => { authenticateChangedZip(e, 'apps', [...acceptedBytes.apps, acceptedBytes.apps[0]]); },
  'unexpected executable script': e => { authenticateChangedZip(e, 'feed', [...acceptedBytes.feed, { name: 'run.py', bytes: 'malicious code' }]); },
  'missing required package': e => { authenticateChangedZip(e, 'apps', acceptedBytes.apps.slice(1)); },
  'oversized declared member': e => {
    e.appsZip = Buffer.from(e.appsZip);
    e.appsZip.writeUInt32LE(1024 ** 3 + 1, 22);
    e.appsZip.writeUInt32LE(1024 ** 3 + 1, e.appsZip.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02])) + 24);
    e.apps.digest = `sha256:${sha256(e.appsZip)}`;
  },
  'authenticated ZIP with corrupt member CRC': e => {
    e.appsZip = Buffer.from(e.appsZip);
    e.appsZip[e.appsZip.indexOf(acceptedBytes.apps[0].bytes)] ^= 1;
    e.apps.digest = `sha256:${sha256(e.appsZip)}`;
  },
  'excessive archive members': e => { authenticateChangedZip(e, 'apps', [...acceptedBytes.apps,
    ...Array.from({ length: 65 }, (_, index) => ({ name: `native-extra-${index}.json`, bytes: '{}' }))]); }
})) {
  test(`hard archive gate rejects ${name} before accepted handoff and coordinator writes`, () => {
    const data = downloadEvidence(); mutate(data);
    const result = downloadHandoff(data);
    assert.notEqual(result.status, 0, name);
    assert.equal(result.writes, false, name);
    assert.equal(result.appsExist, false, 'neither accepted output directory exists on failure');
    assert.equal(result.feedExists, false, 'neither accepted output directory exists on failure');
    assert.doesNotMatch(result.calls, /--method|POST|PATCH|PUT|DELETE/);
  });
}

test('hard archive gate refuses a preexisting symlink destination without changing its target', () => {
  const result = downloadHandoff(downloadEvidence(), dir => {
    writeFileSync(join(dir, 'sentinel'), 'preserved');
    symlinkSync(dir, join(dir, 'out'));
  });
  assert.notEqual(result.status, 0);
  assert.equal(result.writes, false);
  assert.equal(result.feedExists, false);
  assert.equal(result.sentinel, 'preserved');
});
