import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, mkdirSync, existsSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const workflow = readFileSync(new URL('../../.github/workflows/release-tvos.yml', import.meta.url), 'utf8');
const source = '844782d29a93ae51991bfadc639d50bc3619d40b', code = 'a'.repeat(40), tag = 'v0.5.0-beta.1';
const normalNative = 'dd520b0c9e540e11b9e115467b4fe5ec0ccb3fb2';
const historicalNative = '0c201563c6aa54eeb0545b55ad01582c0c3bcae3';
const beta1RecordedNative = '7e3e68be5bf2b11c65d158c1823be94bd1608d1b';
const playerDigest = '737073f587b4d78c0436d3dc08c40bfab72b26e3d3a3ac3eab11a7a3a1c288d1';
// Retained selection lines from each immutable workflow: Beta 1 records 7e3e68b;
// Beta 3 records 0c20156. Both authenticated recovery routes still execute 0c20156.
// Never use the executing workflow's new normal pin as historical checkout evidence.
function historicalPinBlocks(recordedNative) {
  return `      - name: Fetch vortx-core (private monorepo, pinned)
        with:
          ref: ${recordedNative}
      - name: Promote the vortx-core engine workspace + verify both engines (fail closed)
        run: |
          set -euo pipefail
          NATIVE_REVISION="$(git -C _vortx_core_src rev-parse HEAD)"
          [ "$NATIVE_REVISION" = ${recordedNative} ] || { echo "::error::native source checkout differs from reviewed pin"; exit 1; }
      - name: Fetch the MPVKit-DVFEL artifacts (pinned, sha256-verified)
        run: |
          EXPECTED="${playerDigest}"
          URL="https://github.com/VortXTV/VortX/releases/download/vendor-mpvkit-dvfel-3/mpvkit-dvfel-artifacts-http-seek-20261009.zip"
      - name: End historical pin fixture
`;
}
const recoveryCuts = [
  { source, tag, releaseId: '407572242', recordedNative: beta1RecordedNative },
  { source: 'bf4aad976aa7ad21e8d77b1b13c1d2a556b5dd39', tag: 'v0.5.0-beta.3', releaseId: '408568690', recordedNative: historicalNative },
];
function step(name, text = workflow) {
  const start = text.indexOf(`      - name: ${name}\n`);
  assert(start >= 0, name);
  const end = text.indexOf('\n      - ', start + 1);
  return text.slice(start, end < 0 ? undefined : end);
}
function script(name, text = workflow) {
  return step(name, text).split('        run: |\n')[1].split('\n').map(line => line.replace(/^          /, '')).join('\n');
}
function fixture(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'vortx-source-recovery-'));
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}
function admission(overrides = {}, mutations = {}, workflowText = workflow, cut = recoveryCuts[0]) {
  return fixture(dir => {
    mkdirSync(join(dir, '.github/workflows'), { recursive: true });
    writeFileSync(join(dir, '.github/workflows/release-tvos.yml'), workflowText);
    const records = {
      main: code, comparison: { status: 'ahead', merge_base_commit: { sha: cut.source } },
      tag: { object: { type: 'tag', sha: 'b'.repeat(40) } }, peel: { object: { type: 'commit', sha: cut.source } },
      release: { id: Number(cut.releaseId), tag_name: cut.tag, draft: true, prerelease: false, body: '<!-- vortx-channel: latest-beta -->' },
      ...mutations
    };
    for (const [key, value] of Object.entries(records)) writeFileSync(join(dir, `${key}.json`), JSON.stringify(value));
    const output = join(dir, 'outputs');
    const result = spawnSync('bash', ['-c', `
gh() {
  case "\${*: -1}" in
    */git/ref/heads/main) jq -r . "$RUNNER_TEMP/main.json" ;;
    */compare/*) command cat "$RUNNER_TEMP/comparison.json" ;;
    */git/ref/tags/*) command cat "$RUNNER_TEMP/tag.json" ;;
    */git/tags/*) command cat "$RUNNER_TEMP/peel.json" ;;
    */releases/${cut.releaseId}) command cat "$RUNNER_TEMP/release.json" ;;
    *) return 88 ;;
  esac
}
${script('Validate immutable Beta 1 source recovery', workflowText)}`], { cwd: dir, encoding: 'utf8', env: { ...process.env,
      RUNNER_TEMP: dir, GH_REPO: 'VortXTV/VortX', GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/main', GITHUB_SHA: code,
      BUILD_SOURCE_SHA: cut.source, TAG: cut.tag, RELEASE_ID: cut.releaseId, VORTX_NATIVE_ONLY: 'true', TVOS_TEST_ONLY: 'false',
      RESUME_HANDOFF: '', MPVKIT_URL: '', MPVKIT_SHA: '', GITHUB_OUTPUT: output, ...overrides } });
    const outputs = existsSync(output) ? readFileSync(output, 'utf8') : '';
    if (result.status !== 0) assert.equal(outputs, '', 'failed admission cannot emit an accepted source or pin');
    return { ...result, outputs };
  });
}

for (const cut of recoveryCuts) test(`actual recovery admission accepts exactly ${cut.tag} on current main with immutable tag peel`, () => {
  const admit = (overrides = {}, mutations = {}, workflowText = workflow) => admission(overrides, mutations, workflowText, cut);
  const result = admit(); assert.equal(result.status, 0, result.stderr);
  assert.equal(result.outputs, `source_sha=${cut.source}\nnative_revision=${historicalNative}\n`);
  assert.equal(admit({}, { tag: { object: { type: 'commit', sha: cut.source } } }).status, 0);
  assert.equal(admit({}, { comparison: { status: 'identical', merge_base_commit: { sha: cut.source } } }).status, 0);
  for (const invalid of [
    { GITHUB_EVENT_NAME: 'push' }, { GITHUB_REF: `refs/tags/${cut.tag}` }, { GITHUB_REF: 'refs/heads/feature' },
    { GH_REPO: 'fork/VortX' }, { BUILD_SOURCE_SHA: code }, { TAG: 'v0.5.0-beta.2' }, { RELEASE_ID: String(Number(cut.releaseId) + 1) },
    { VORTX_NATIVE_ONLY: 'false' }, { TVOS_TEST_ONLY: 'true' }, { RESUME_HANDOFF: '{}' },
    { MPVKIT_URL: 'https://github.com/VortXTV/VortX/releases/download/other/player.zip' }, { MPVKIT_SHA: 'd'.repeat(64) },
    ...recoveryCuts.filter(other => other !== cut).flatMap(other => [
      { BUILD_SOURCE_SHA: other.source }, { TAG: other.tag }, { RELEASE_ID: other.releaseId },
    ])
  ]) assert.notEqual(admit(invalid).status, 0, JSON.stringify(invalid));
  for (const invalid of [
    { main: cut.source }, { comparison: { status: 'diverged', merge_base_commit: { sha: cut.source } } },
    { comparison: { status: 'ahead', merge_base_commit: { sha: code } } },
    { peel: { object: { type: 'commit', sha: code } } }, { peel: { object: { type: 'tree', sha: cut.source } } },
    { peel: { object: { type: 'tag', sha: code } } },
    ...[{ draft: false }, { id: Number(cut.releaseId) + 1 }, { tag_name: 'v0.5.0-beta.2' }, { prerelease: true }, { body: '' },
      { body: 'prefix <!-- vortx-channel: latest-beta -->' }]
      .map(change => ({ release: { id: Number(cut.releaseId), tag_name: cut.tag, draft: true, prerelease: false, body: '<!-- vortx-channel: latest-beta -->', ...change } }))
  ]) assert.notEqual(admit({}, invalid).status, 0, JSON.stringify(invalid));
  const withoutMarker = { release: { id: Number(cut.releaseId), tag_name: cut.tag, draft: true, prerelease: true, body: '' } };
  assert.equal(admit({}, withoutMarker).status === 0, cut.tag === tag, 'Beta 1 keeps its prerelease contract; Beta 3 requires Latest-beta');
  assert.equal(admit({}, { release: { id: Number(cut.releaseId), tag_name: cut.tag, draft: true, prerelease: false,
    body: 'Release notes\r\n<!-- vortx-channel: latest-beta -->\r\n' } }).status, 0);
  const player = step('Fetch the MPVKit-DVFEL artifacts (pinned, sha256-verified)');
  for (const changed of [player.replace('vendor-mpvkit-dvfel-3/', 'vendor-mpvkit-dvfel-4/'),
    player.replace('737073f587b4d78c0436d3dc08c40bfab72b26e3d3a3ac3eab11a7a3a1c288d1', 'd'.repeat(64))]) {
    assert.notEqual(admit({}, {}, workflow.replace(player, changed)).status, 0);
  }
});

for (const cut of recoveryCuts) test(`recovered checkout accepts only clean exact ${cut.tag} source and pinned inputs`, () => fixture(dir => {
  mkdirSync(join(dir, '.github/workflows'), { recursive: true });
  const historicalWorkflow = historicalPinBlocks(cut.recordedNative);
  const otherCut = recoveryCuts.find(other => other.source !== cut.source);
  const verify = (head = cut.source, status = '', workflowText = historicalWorkflow, verifierWorkflow = workflow, buildSource = cut.source) => {
    writeFileSync(join(dir, '.github/workflows/release-tvos.yml'), workflowText);
    return spawnSync('bash', ['-c', `
git() {
  case "$*" in
    'rev-parse HEAD') printf '%s' "$CHECKOUT_HEAD" ;;
    'status --porcelain') printf '%s' "$CHECKOUT_STATUS" ;;
    *) return 88 ;;
  esac
}
${script('Verify immutable recovered source checkout', verifierWorkflow)}`], { cwd: dir, encoding: 'utf8', env: { ...process.env,
      BUILD_SOURCE_SHA: buildSource, CHECKOUT_HEAD: head, CHECKOUT_STATUS: status } });
  };
  assert.equal(verify().status, 0);
  assert.notEqual(verify(code).status, 0, 'wrong checkout');
  assert.notEqual(verify(cut.source, ' M app/fixture.swift').status, 0, 'dirty checkout');
  assert.notEqual(verify(code, '', historicalWorkflow, workflow, code).status, 0, 'unadmitted source cannot select a recorded profile');
  for (const changed of [
    historicalWorkflow.replace(`ref: ${cut.recordedNative}`, `ref: ${code}`),
    historicalWorkflow.replace(`ref: ${cut.recordedNative}`, `ref: ${normalNative}`),
    historicalWorkflow.replace(`ref: ${cut.recordedNative}`, `ref: ${otherCut.recordedNative}`),
    historicalWorkflow.replace(`"$NATIVE_REVISION" = ${cut.recordedNative}`, `"$NATIVE_REVISION" = ${otherCut.recordedNative}`),
    historicalWorkflow.replace(`"$NATIVE_REVISION" = ${cut.recordedNative}`, `"$NATIVE_REVISION" = ${normalNative}`),
    historicalPinBlocks(otherCut.recordedNative),
    historicalWorkflow.replace('vendor-mpvkit-dvfel-3/', 'vendor-mpvkit-dvfel-4/'),
    historicalWorkflow.replace(playerDigest, 'd'.repeat(64)),
    historicalWorkflow.replace(`ref: ${cut.recordedNative}`, '') + `\n# ref: ${cut.recordedNative}\n`,
    historicalWorkflow.replace(`          [ "$NATIVE_REVISION" = ${cut.recordedNative} ]`, '          true'),
    workflow,
  ]) assert.notEqual(verify(cut.source, '', changed).status, 0, 'wrong historical pin blocks');
  const wrongProfile = workflow.replace(`${cut.source}) RECORDED_NATIVE_PIN=${cut.recordedNative}`,
    `${cut.source}) RECORDED_NATIVE_PIN=${otherCut.recordedNative}`);
  assert.notEqual(wrongProfile, workflow, 'negative fixture must mutate the actual source-specific profile');
  assert.notEqual(verify(cut.source, '', historicalWorkflow, wrongProfile).status, 0, 'wrong-cut source profile');
}));

function selection(overrides = {}, workflowText = workflow) {
  return fixture(dir => {
    const output = join(dir, 'outputs');
    const result = spawnSync('/bin/bash', ['-c', `
git() {
  case "$*" in
    'rev-parse HEAD') printf '%s' "$CHECKOUT_HEAD" ;;
    'status --porcelain') printf '%s' "$CHECKOUT_STATUS" ;;
    *) return 88 ;;
  esac
}
${script('Select the authenticated native source revision', workflowText)}`], { cwd: dir, encoding: 'utf8', env: { ...process.env,
      GITHUB_OUTPUT: output, GITHUB_SHA: code, BUILD_SOURCE_SHA: code, CHECKOUT_HEAD: code, CHECKOUT_STATUS: '',
      NORMAL_NATIVE_REVISION: workflowText.match(/^      NORMAL_NATIVE_REVISION: (.+)$/m)?.[1] ?? '',
      RECOVERY_SOURCE: '', RECOVERY_OUTCOME: 'skipped', ADMITTED_SOURCE: '', ADMITTED_NATIVE_REVISION: '', ...overrides } });
    const outputs = existsSync(output) ? readFileSync(output, 'utf8') : '';
    if (result.status !== 0) assert.equal(outputs, '', 'failed selection must emit no revision');
    return { ...result, outputs };
  });
}

test('actual normal source selection emits only the new immutable pin and rejects ambiguous provenance', () => {
  const valid = selection();
  assert.equal(valid.status, 0, valid.stderr);
  assert.equal(valid.outputs, `revision=${normalNative}\n`);
  for (const invalid of [
    { CHECKOUT_HEAD: source }, { CHECKOUT_STATUS: ' M app/fixture.swift' }, { BUILD_SOURCE_SHA: source },
    { GITHUB_SHA: source }, { NORMAL_NATIVE_REVISION: historicalNative }, { NORMAL_NATIVE_REVISION: 'main' },
    { NORMAL_NATIVE_REVISION: '' }, { RECOVERY_OUTCOME: 'success' }, { RECOVERY_OUTCOME: '' },
    { ADMITTED_SOURCE: source }, { ADMITTED_NATIVE_REVISION: historicalNative }, { RECOVERY_SOURCE: source },
  ]) assert.notEqual(selection(invalid).status, 0, JSON.stringify(invalid));
});

for (const cut of recoveryCuts) test(`actual ${cut.tag} selection consumes only successful exact historical admission outputs`, () => {
  const admitted = admission({}, {}, workflow, cut);
  assert.equal(admitted.status, 0, admitted.stderr);
  const outputs = Object.fromEntries(admitted.outputs.trim().split('\n').map(line => line.split('=')));
  const env = { BUILD_SOURCE_SHA: cut.source, CHECKOUT_HEAD: cut.source, RECOVERY_SOURCE: cut.source,
    RECOVERY_OUTCOME: 'success', ADMITTED_SOURCE: outputs.source_sha, ADMITTED_NATIVE_REVISION: outputs.native_revision };
  const valid = selection(env);
  assert.equal(valid.status, 0, valid.stderr);
  assert.equal(valid.outputs, `revision=${historicalNative}\n`);
  for (const invalid of [
    { RECOVERY_OUTCOME: 'skipped' }, { RECOVERY_OUTCOME: 'failure' }, { RECOVERY_OUTCOME: '' },
    { RECOVERY_SOURCE: '' }, { RECOVERY_SOURCE: code }, { ADMITTED_SOURCE: '' }, { ADMITTED_SOURCE: code },
    { ADMITTED_NATIVE_REVISION: '' }, { ADMITTED_NATIVE_REVISION: normalNative }, { ADMITTED_NATIVE_REVISION: code },
    { ADMITTED_NATIVE_REVISION: 'main' }, { CHECKOUT_HEAD: code }, { CHECKOUT_STATUS: '?? untracked' },
    { BUILD_SOURCE_SHA: code },
    { BUILD_SOURCE_SHA: code, CHECKOUT_HEAD: code, RECOVERY_SOURCE: code, ADMITTED_SOURCE: code },
  ]) assert.notEqual(selection({ ...env, ...invalid }).status, 0, JSON.stringify(invalid));
  const admissionName = 'Validate immutable Beta 1 source recovery';
  const altered = workflow.replace(step(admissionName), step(admissionName).replace(`native_revision=${historicalNative}`, `native_revision=${normalNative}`));
  assert.notEqual(altered, workflow, 'negative fixture must alter the actual admission output');
  const badAdmission = admission({}, {}, altered, cut);
  assert.equal(badAdmission.status, 0);
  const badPin = Object.fromEntries(badAdmission.outputs.trim().split('\n').map(line => line.split('='))).native_revision;
  assert.notEqual(selection({ ...env, ADMITTED_NATIVE_REVISION: badPin }).status, 0, 'normal pin cannot replace the historical profile');
});

test('actual private promotion exports only the fetched commit matching authenticated selection', () => fixture(dir => {
  const body = script('Promote the vortx-core engine workspace + verify both engines (fail closed)');
  // Stop before filesystem promotion; execute the exact pin checks and provenance export.
  const guard = body.slice(0, body.indexOf('\nrm -rf vortx-core'));
  assert(guard.includes('VORTX_ENGINE_SOURCE_REVISION='));
  for (const selected of [normalNative, historicalNative]) {
    for (const actual of [selected, selected === normalNative ? historicalNative : normalNative, code, '', 'main']) {
      const output = join(dir, 'env');
      writeFileSync(output, '');
      const result = spawnSync('/bin/bash', ['-c', `git() { [ "$*" = '-C _vortx_core_src rev-parse HEAD^{commit}' ] || return 88; printf '%s' "$ACTUAL"; }\n${guard}`],
        { encoding: 'utf8', env: { ...process.env, GITHUB_ENV: output, EXPECTED_NATIVE_REVISION: selected, ACTUAL: actual } });
      assert.equal(result.status === 0, actual === selected, `selected=${selected}, actual=${actual}`);
      assert.equal(readFileSync(output, 'utf8'), actual === selected ? `VORTX_ENGINE_SOURCE_REVISION=${actual}\n` : '');
    }
  }
  for (const selected of ['', 'main', normalNative + '\ninjected=true']) {
    const result = spawnSync('/bin/bash', ['-c', `git() { printf '%s' "$EXPECTED_NATIVE_REVISION"; }\n${guard}`],
      { encoding: 'utf8', env: { ...process.env, GITHUB_ENV: join(dir, 'invalid'), EXPECTED_NATIVE_REVISION: selected } });
    assert.notEqual(result.status, 0);
  }
}));

const androidWorkflows = ['android.yml', 'android-release.yml'].map(name =>
  readFileSync(new URL(`../../.github/workflows/${name}`, import.meta.url), 'utf8'));
function assertNativeWiring(text = workflow, android = androidWorkflows) {
  assert.equal(text.match(/^      NORMAL_NATIVE_REVISION: (.+)$/m)?.[1], normalNative);
  const fetch = step('Fetch vortx-core (private monorepo, pinned)', text);
  assert.deepEqual(fetch.match(/^          ref: .*$/gm), ['          ref: ${{ steps.native_source.outputs.revision }}']);
  const selector = step('Select the authenticated native source revision', text);
  for (const binding of [
    'RECOVERY_SOURCE: ${{ inputs.recovery_source_commit }}', 'RECOVERY_OUTCOME: ${{ steps.recovery.outcome }}',
    'ADMITTED_SOURCE: ${{ steps.recovery.outputs.source_sha }}', 'ADMITTED_NATIVE_REVISION: ${{ steps.recovery.outputs.native_revision }}',
  ]) assert(selector.includes(`          ${binding}\n`), binding);
  assert.doesNotMatch(selector, /^        if:/m);
  const promote = step('Promote the vortx-core engine workspace + verify both engines (fail closed)', text);
  assert(promote.includes('EXPECTED_NATIVE_REVISION: ${{ steps.native_source.outputs.revision }}'));
  assert(promote.includes('[ "$NATIVE_REVISION" = "$EXPECTED_NATIVE_REVISION" ]'));
  assert(promote.includes('echo "VORTX_ENGINE_SOURCE_REVISION=$NATIVE_REVISION" >> "$GITHUB_ENV"'));
  const admission = step('Validate immutable Beta 1 source recovery', text);
  assert(admission.includes(`echo 'native_revision=${historicalNative}' >> "$GITHUB_OUTPUT"`));
  assert(admission.indexOf('echo "source_sha=') > admission.indexOf('then $latest != null and .prerelease == false'));
  const cache = step('Cache vortx-ffi xcframework', text);
  assert.match(cache, /^          key: .*\$\{\{ env\.VORTX_ENGINE_SOURCE_REVISION \}\}.*hashFiles/m);
  assert.doesNotMatch(cache, /restore-keys:/);
  const ordered = ['Validate immutable Beta 1 source recovery', "Preserve the workflow revision's native acceptance tool",
    'Checkout the immutable recovered app source', 'Verify immutable recovered source checkout',
    'Select the authenticated native source revision', 'Bind native acceptance tooling to workflow and source provenance',
    'Fetch vortx-core (private monorepo, pinned)', 'Promote the vortx-core engine workspace + verify both engines (fail closed)',
    'Cache vortx-ffi xcframework', 'Capture exact native SDK and player inputs before app compilation'];
  const offsets = ordered.map(name => text.indexOf(`      - name: ${name}\n`));
  assert(offsets.every(value => value >= 0));
  assert.deepEqual(offsets, [...offsets].sort((a, b) => a - b));
  for (const lane of android) {
    const checkout = step('Fetch vortx-core (private monorepo, pinned)', lane);
    assert.deepEqual(checkout.match(/^          ref: .*$/gm), [`          ref: ${normalNative}`]);
    const promotion = step('Promote the vortx-core workspace + record exact private source pins', lane);
    assert(promotion.includes(`test "$vortx_sha" = "${normalNative}"`));
    assert(promotion.includes('echo "VORTX_ENGINE_SOURCE_SHA=$vortx_sha" >> "$GITHUB_ENV"'));
    assert.match(lane, /^          key: .*\$\{\{ env\.VORTX_ENGINE_SOURCE_SHA \}\}.*hashFiles/m);
  }
}

test('normal and historical native selection wiring rejects scoped workflow mutations', () => {
  assertNativeWiring();
  const mutations = [
    ['Fetch vortx-core (private monorepo, pinned)', '${{ steps.native_source.outputs.revision }}', normalNative],
    ['Select the authenticated native source revision', '${{ steps.recovery.outputs.native_revision }}', '${{ inputs.recovery_source_commit }}'],
    ['Promote the vortx-core engine workspace + verify both engines (fail closed)', '${{ steps.native_source.outputs.revision }}', historicalNative],
    ['Promote the vortx-core engine workspace + verify both engines (fail closed)', '[ "$NATIVE_REVISION" = "$EXPECTED_NATIVE_REVISION" ]', 'true'],
    ['Validate immutable Beta 1 source recovery', `native_revision=${historicalNative}`, `native_revision=${normalNative}`],
    ['Cache vortx-ffi xcframework', '${{ env.VORTX_ENGINE_SOURCE_REVISION }}', 'unbound'],
  ];
  for (const [name, before, after] of mutations) {
    const original = step(name), changed = original.replace(before, after);
    assert.notEqual(changed, original, name);
    assert.throws(() => assertNativeWiring(workflow.replace(original, changed)), name);
  }
  const wrongNormal = workflow.replace(`NORMAL_NATIVE_REVISION: ${normalNative}`, `NORMAL_NATIVE_REVISION: ${historicalNative}`);
  assert.throws(() => assertNativeWiring(wrongNormal));
  assert.notEqual(selection({}, wrongNormal).status, 0);
  for (let index = 0; index < androidWorkflows.length; index++) {
    for (const [before, after] of [[`ref: ${normalNative}`, `ref: ${historicalNative}`],
      [`test "$vortx_sha" = "${normalNative}"`, 'true'], ['${{ env.VORTX_ENGINE_SOURCE_SHA }}', 'unbound']]) {
      const changed = [...androidWorkflows];
      changed[index] = changed[index].replace(before, after);
      assert.notEqual(changed[index], androidWorkflows[index]);
      assert.throws(() => assertNativeWiring(workflow, changed));
    }
  }
});

test('only the Apple build job receives the extended CI wall-clock budget', () => {
  const build = workflow.split('  build-tvos:\n')[1].split('  attach-release:\n')[0];
  assert.match(build, /^    timeout-minutes: 150$/m);
  assert.equal((workflow.match(/^    timeout-minutes: 150$/gm) ?? []).length, 1);
  assert.match(workflow.split('  attach-release:\n')[1], /^    timeout-minutes: 35$/m);
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
  assertNativeWiring();
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

for (const cut of recoveryCuts) test(`coordinator checks ${cut.tag} verifier against GitHub workflow bytes and exact run provenance`, () => fixture(dir => {
  mkdirSync(join(dir, 'out'));
  const verifier = 'reviewed acceptance tool bytes\n', digest = createHash('sha256').update(verifier).digest('hex');
  const receipt = { schemaVersion: 1, sourceCommit: cut.source, workflowCommit: code, verifierSha256: digest, tag: cut.tag, runId: 123, attempt: 2 };
  const identity = script('Bind the draft release, tag commit, and monotonic source before any write');
  const prefix = identity.slice(0, identity.indexOf('\njq -e --arg tag "$TAG" --arg commit'));
  const verify = (changes = {}) => {
    writeFileSync(join(dir, 'out/native-workflow-provenance.json'), JSON.stringify({ ...receipt, ...changes }));
    return spawnSync('bash', ['-c', `
gh() { printf '%s' '${JSON.stringify({ content: Buffer.from(verifier).toString('base64') })}'; }
${prefix}`], { cwd: dir, encoding: 'utf8', env: { ...process.env, RUNNER_TEMP: dir, GH_REPO: 'VortXTV/VortX', TAG: cut.tag,
      BUILD_SOURCE_SHA: cut.source, BUILD_WORKFLOW_SHA: code, BUILD_RUN_ID: '123', BUILD_ATTEMPT: '2' } });
  };
  const result = verify(); assert.equal(result.status, 0, result.stderr);
  for (const change of [{ sourceCommit: code }, { workflowCommit: cut.source }, { verifierSha256: 'd'.repeat(64) },
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
function uploadLog(data) {
  return ['apps', 'feed'].flatMap((key, index) => {
    const artifact = data[key], second = 30 + index;
    return [
      `2026-10-09T12:00:${second}.1000000Z SHA256 digest of uploaded artifact is ${artifact.digest.slice(7)}`,
      `2026-10-09T12:00:${second}.2000000Z Artifact ${artifact.name} successfully finalized. Artifact ID ${artifact.id}`,
      `2026-10-09T12:00:${second}.3000000Z Artifact ${artifact.name} has been successfully uploaded! Final size is ${artifact.size_in_bytes} bytes. Artifact ID is ${artifact.id}`,
    ];
  }).join('\n') + '\n';
}
function downloadEvidence() {
  const run = { id: 123, run_attempt: 2, repository: { id: 1, full_name: 'VortXTV/VortX' }, head_repository: { id: 1, full_name: 'VortXTV/VortX' },
    path: '.github/workflows/release-tvos.yml', event: 'workflow_dispatch', head_sha: code, head_branch: 'main', status: 'in_progress' };
  const jobs = [{ id: 321, name: 'build-tvos', head_sha: code, run_id: 123, run_attempt: 2, status: 'completed', conclusion: 'success',
    steps: [uploadStep('Upload the immutable app handoff'), uploadStep('Upload the immutable feed handoff')] }];
  const artifact = (id, name, bytes) => ({ id, name, expired: false, size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`,
    created_at: '2026-10-09T12:00:30Z', workflow_run: { id: 123, head_sha: code, head_branch: 'main', repository_id: 1, head_repository_id: 1 } });
  const data = { run, jobs, apps: artifact(456, 'VortX-tvOS-ci', acceptedBytes.appsZip), feed: artifact(457, 'VortX-release-feed', acceptedBytes.feedZip),
    appsZip: acceptedBytes.appsZip, feedZip: acceptedBytes.feedZip };
  data.log = uploadLog(data);
  return data;
}
function downloadHandoff(data, before = () => {}) {
  return fixture(dir => {
    for (const key of ['run', 'jobs', 'apps', 'feed']) writeFileSync(join(dir, `${key}.json`), JSON.stringify(data[key]));
    writeFileSync(join(dir, 'apps.zip'), data.appsZip);
    writeFileSync(join(dir, 'feed.zip'), data.feedZip);
    writeFileSync(join(dir, 'build-upload.log'), data.log);
    before(dir);
    const result = spawnSync('bash', ['-c', `
gh() {
  printf '%s\\n' "$*" >> "$RUNNER_TEMP/api-calls"
  case "\${*: -1}" in
    repos/VortXTV/VortX/actions/runs/123) command cat "$RUNNER_TEMP/run.json" ;;
    repos/VortXTV/VortX/actions/runs/123/attempts/2/jobs?per_page=100) jq '[{jobs:.}]' "$RUNNER_TEMP/jobs.json" ;;
    repos/VortXTV/VortX/actions/jobs/321/logs) command cat "$RUNNER_TEMP/build-upload.log" ;;
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
  // Keep authenticated upload evidence coherent so archive mutations exercise
  // the actual ZIP gate instead of failing early at the separate log-proof gate.
  data.log = uploadLog(data);
}

test('exact API IDs download once and the same authenticated ZIP bytes reach the coordinator', () => {
  const result = downloadHandoff(downloadEvidence());
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.writes, true);
  assert.equal(result.feedExists, true);
  assert.deepEqual(result.payload, acceptedBytes.apps[0].bytes);
  assert.equal((result.calls.match(/artifacts\/456\/zip/g) ?? []).length, 1);
  assert.equal((result.calls.match(/artifacts\/457\/zip/g) ?? []).length, 1);
  assert.equal((result.calls.match(/jobs\/321\/logs/g) ?? []).length, 1);
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
    e.log = uploadLog(e);
  },
  'authenticated ZIP with corrupt member CRC': e => {
    e.appsZip = Buffer.from(e.appsZip);
    e.appsZip[e.appsZip.indexOf(acceptedBytes.apps[0].bytes)] ^= 1;
    e.apps.digest = `sha256:${sha256(e.appsZip)}`;
    e.log = uploadLog(e);
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
