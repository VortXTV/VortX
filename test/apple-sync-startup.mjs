import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

// Actual-source scheduling regression. No installed app, customer state, network or SDK access.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
assert(args.length === 0 || (args.length === 2 && args[0] === '--baseline-ref'),
  'Usage: test-apple-sync-startup.sh [--baseline-ref <immutable commit>]');
const baseline = args.length > 0;
const sourcePath = 'app/SourcesShared/VortXSyncManager.swift';
const source = baseline
  ? execFileSync('git', ['-C', root, 'show', `${args[1]}:${sourcePath}`], { encoding: 'utf8' })
  : await readFile(resolve(root, sourcePath), 'utf8');
const policyPath = resolve(root, 'app/SourcesShared/NativeForegroundSyncPolicy.swift');
const policy = await readFile(policyPath, 'utf8');
const sha = value => createHash('sha256').update(value).digest('hex');
await mkdir(resolve(root, 'app/build'), { recursive: true });
const out = await mkdtemp(resolve(root, 'app/build/sync-startup.'));
const members = ['startRealtime', 'stopRealtime', 'startPoll', 'ensureNativeCheckpoint',
  'nativeMutationDidCommit', 'drainNativeMutationPush', 'requestSyncSoon'];
function method(name) {
  const start = source.search(new RegExp(`^    (?:private )?func ${name}\\(`, 'm'));
  assert(start >= 0, `Production method missing: ${name}`);
  const end = source.indexOf('\n    }', start);
  assert(end > start, `Production method boundary missing: ${name}`);
  return source.slice(start, end + 6);
}
const extracted = members.map(method).join('\n');
const fallbackStart = source.indexOf('                    let selectedRecord = state["roster"]?');
const fallbackEnd = source.indexOf('\n                    if state["activeProfileId"]', fallbackStart);
assert(fallbackStart > 0 && fallbackEnd > fallbackStart, 'Restore fallback boundary');
const fallback = source.slice(fallbackStart, fallbackEnd);
const guardStart = source.indexOf('        let mustRestore = !hasAppliedAccountDoc || hasPendingAccountDocApply(for: capture)');
const guardEnd = source.indexOf('\n        let pulled:', guardStart);
assert(guardStart > 0 && guardEnd > guardStart, 'Pending-push pull guard boundary');
const pullGuard = source.slice(guardStart, guardEnd);
const template = await readFile(resolve(root, 'app/Tests/NativeSyncStartupHarness.swift.in'), 'utf8');
const generated = template.replace('/* PRODUCTION_METHODS */', extracted)
  .replace('/* PRODUCTION_RESTORE_FALLBACK */', fallback)
  .replace('/* PRODUCTION_PULL_GUARD */', pullGuard);
assert(!generated.includes('/* PRODUCTION_'), 'Every production injection must be resolved');
const generatedPath = resolve(out, 'Combined.swift');
const executable = resolve(out, 'startup-probe');
await writeFile(generatedPath, generated);
execFileSync('xcrun', ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
  '-parse-as-library', '-D', 'VORTX_NATIVE_DATA_ENGINE', policyPath, generatedPath, '-o', executable],
  { stdio: 'inherit' });
const output = execFileSync(executable, { encoding: 'utf8' });
await writeFile(resolve(out, 'observations.json'), output);
const result = JSON.parse(output);
assert.equal(result.deletedProfile.activeOwner, true);
assert.equal(result.deletedProfile.workerExists, false);
assert.equal(result.deletedProfile.uploads, baseline ? 0 : 1);
assert.equal(result.deletedProfile.durablePending, baseline);
assert(result.deletedProfile.pullAttempts > 3);
if (!baseline) assert(result.deletedProfile.remotePullsApplied > 0);
else assert.equal(result.deletedProfile.remotePullsApplied, 0);
assert.equal(result.sameProfile.uploads, 1);
assert.equal(result.sameProfile.durablePending, false);
assert(result.sameProfile.remotePullsApplied > 0);
assert.equal(result.accountKeyABA.uploads, 0);
assert.equal(result.accountKeyABA.workerExists, false);
assert.equal(result.accountKeyABA.durablePending, true);
assert.equal(result.suppression.beforeDrainWorkerExists, false);
assert.equal(result.suppression.beforeDrainAdmission, !baseline);
assert.equal(result.suppression.uploads, baseline ? 0 : 1);
assert.equal(result.cleanFallback.uploads, 0);
assert.equal(result.cleanFallback.durablePending, false);
assert.equal(result.cleanSameProfile.uploads, 1);
assert.equal(result.cleanSameProfile.durablePending, false);
assert.equal(result.backgrounded.uploads, 0);
assert.equal(result.backgrounded.workerExists, false);
assert.equal(result.backgrounded.durablePending, true);
const receipt = {
  result: baseline ? 'BASELINE_BUG_REPRODUCED' : 'CURRENT_SOURCE_GREEN', scenarios: 7,
  managerSHA256: sha(source), policySHA256: sha(policy), extractedMethodsSHA256: sha(extracted),
  generatedSHA256: sha(generated), members, observations: result,
  boundary: 'Verbatim production startup/session/queue/stop/poll methods, restore fallback expression and pending-push guard. In-memory credential/profile/mount/defaults/transport collaborators; not full restore/syncDown bodies, customer state, native FFI, network or device proof. Existing injectable poll interval shortened; production 2.5-second upload debounce unchanged.'
};
await writeFile(resolve(out, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
process.stdout.write(`${receipt.result}: ${receipt.scenarios} scenarios; ${out}/receipt.json\n`);
