#!/usr/bin/env node
// The actual orchestration wrapper with inert shell commands, not xcodebuild/app verification.
import assert from 'node:assert/strict';
import {readFileSync, mkdirSync, mkdtempSync, writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {resolve, join} from 'node:path';

const root = resolve(import.meta.dirname, '..');
const path = join(root, '.github/workflows/release-packaging-validation.yml');
const source = readFileSync(path, 'utf8');
const start = source.indexOf('          export -f build_one_shell\n');
const last = '          [ "$shell_failures" -eq 0 ] || { echo "::error::$shell_failures shell checks failed"; exit 1; }';
const end = source.indexOf(last, start);
assert(start >= 0 && end > start && source.indexOf(last, end + 1) < 0);
const wrapper = source.slice(start, end + last.length).split('\n').map(line => line.slice(10)).join('\n');
const calls = [...wrapper.matchAll(/^build_shell\s+(\S+)/gm)].map(match => match[1]);
assert.deepEqual(calls, ['VortXTVLite', 'VortXTV', 'VortXTVLite', 'VortXiOSNative', 'VortXMac']);
assert(wrapper.includes("bash -euo pipefail -c 'build_one_shell \"$@\"' -- \"$@\""));
mkdirSync(join(root, 'app/build'), {recursive: true});
const output = mkdtempSync(join(root, 'app/build/shell-aggregation.'));
// Only this external boundary is substituted. A failed command must prevent AFTER; the
// parent's actual wrapper must still visit all five unchanged platform/architecture calls.
const inert = `build_one_shell() {
  printf 'VISIT|%s|%s|%s\\n' "$1" "$4" "\${6:-default}"
  case "$SCENARIO" in
    command) false ;;
    pipeline) false | true ;;
    exit) exit 17 ;;
    one) if [ "$1" = VortXMac ]; then false; fi ;;
  esac
  printf 'AFTER|%s\\n' "$1"
}
`;
const outcomes = [];
for (const [scenario, status, after] of [['success', 0, 5], ['command', 1, 0],
  ['pipeline', 1, 0], ['exit', 1, 0], ['one', 1, 4]]) {
  const result = spawnSync('bash', ['-euo', 'pipefail', '-c', inert + wrapper], {
    env: {...process.env, SCENARIO: scenario, RUNNER_TEMP: '/synthetic output with spaces'},
    encoding: 'utf8', timeout: 10000
  });
  const log = (result.stdout ?? '') + (result.stderr ?? '');
  writeFileSync(join(output, `${scenario}.log`), log);
  assert(!result.error && result.signal === null, `${scenario} did not finish normally`);
  assert.equal(result.status, status, `${scenario}: wrong aggregate outcome`);
  assert.equal((log.match(/^VISIT\|/gm) ?? []).length, 5, `${scenario}: hidden platform check`);
  assert.equal((log.match(/^AFTER\|/gm) ?? []).length, after, `${scenario}: child errexit lost`);
  assert.equal((log.match(/^::notice::shell passed:/gm) ?? []).length, after);
  assert.equal((log.match(/^::error::shell failed:/gm) ?? []).length, 5 - after);
  assert(log.includes('VISIT|VortXTVLite|/synthetic output with spaces/dd-tvlite-x86|x86_64'));
  outcomes.push({scenario, status: result.status, visited: 5, completed: after});
}
assert.equal(readFileSync(path, 'utf8'), source, 'workflow changed during verification');
writeFileSync(join(output, 'receipt.json'), JSON.stringify({
  workflowSHA256: createHash('sha256').update(source).digest('hex'), outcomes,
  boundary: 'Actual aggregation/calls only. Inner xcodebuild/package/bundle/nm gates are inert here; no app/SDK/build/signing/device claim.'
}, null, 2) + '\n');
console.log(`PASS five normal/early-error/pipefail/exit/partial-failure scenarios; retained ${output}`);
