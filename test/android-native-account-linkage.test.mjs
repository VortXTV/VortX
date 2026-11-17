import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const root = new URL('../android/app/src/main/kotlin/com/vortx/android/', import.meta.url);
const source = name => readFileSync(new URL(name, root), 'utf8');
const manager = source('sync/VortXSyncManager.kt');
const helper = source('sync/NativeAccountAttempt.kt');
function method(signature, file = manager) {
  const start = file.indexOf(signature);
  assert(start >= 0 && file.indexOf(signature, start + signature.length) < 0);
  const end = file.indexOf('\n    }', start);
  assert(end > start);
  return file.slice(start, end + 6);
}
test('compatibility helper catches only linkage and preserves cancellation/fatal policy', () => {
  assert.match(helper, /catch \(cancel: CancellationException\) \{\s*throw cancel/);
  assert.match(helper, /catch \(_: LinkageError\) \{[\s\S]*currentCoroutineContext\(\)\.ensureActive\(\)[\s\S]*onUnavailable\(\)[\s\S]*false/);
  assert.doesNotMatch(helper, /catch[^\n]*:\s*(?:Throwable|VirtualMachineError|AssertionError|Exception)\)/);
  assert.doesNotMatch(helper, /\.message|\.stackTrace|\.cause|prepareEmptyAccount|signOut|Preview|retired\.remove/);
});
test('post-auth background and manual native sync share the same compatibility boundary', () => {
  const up = method('    private suspend fun syncUp(lease:');
  const down = method('    private suspend fun syncDown(\n');
  for (const body of [up, down]) {
    assert.doesNotMatch(body, /BuildConfig\.NATIVE_ENGINE_ENABLED/);
    assert.match(body, /= accountFileManagedWriter\(false\) \{[\s\S]*return@accountFileManagedWriter try \{ withContext\(nativeWorkDispatcher\) \{\s*nativeSyncMutex\.withLock \{/);
    assert.match(body, /catch \(cancel: kotlinx\.coroutines\.CancellationException\) \{ throw cancel \}\s*catch \(_: Exception\) \{ false \}/);
  }
  const insideLock = body => {
    const start = body.indexOf('nativeSyncMutex.withLock {');
    const end = body.indexOf('\n            }', start);
    assert(end > start);
    return body.slice(start, end);
  };
  assert.match(insideLock(up), /val gateway = nativeGateway \?: return@withLock false\s*runNativeAccountAttempt\(onUnavailable = \{\s*markNativeAccountUnavailable\(lease, gateway\)\s*\}\) \{\s*nativeSyncUp\(lease, gateway\)\s*\}\.also \{\s*if \(it\) clearNativeAccountUnavailable\(lease, gateway\)\s*\}/);
  assert.match(insideLock(down), /val gateway = nativeGateway \?: return@withLock false\s*runNativeAccountAttempt\(onUnavailable = \{\s*if \(publicationCurrent\(\)\) markNativeAccountUnavailable\(lease, gateway\)\s*\}\) \{\s*nativeSyncDown\(lease, gateway, force, routineReceive, publicationCurrent\)\s*\}\.also \{\s*if \(it && publicationCurrent\(\)\) clearNativeAccountUnavailable\(lease, gateway\)\s*\}/);
});
test('native failure notice and one fixed diagnostic line retain captured account admission', () => {
  const body = method('    private fun markNativeAccountUnavailable(');
  assert.match(body, /var firstNotice = false\s*publishIfSyncLeaseCurrent\(lease\) \{\s*if \(nativeGateway === gateway && !requiresUpgrade\(lease\) && !backupWritesRequireSignIn\(lease\)\) \{\s*firstNotice = _syncProblem\.value != NATIVE_ACCOUNT_UNAVAILABLE\s*_syncProblem\.value = NATIVE_ACCOUNT_UNAVAILABLE\s*\}\s*\}\s*if \(firstNotice\) DiagnosticsLog\.log\("native-account", "sync result=failed reason=native_linkage_unavailable"\)/);
  assert.equal([...body.matchAll(/DiagnosticsLog\.log\(/g)].length, 1);
  assert.doesNotMatch(body, /error\.|throwable|\.message|\.stackTrace|\.cause|accountId|token/);
});
test('native recovery cannot clear another account or an unrelated upgrade notice', () => {
  const body = method('    private fun clearNativeAccountUnavailable(');
  assert.match(body, /publishIfSyncLeaseCurrent\(lease\) \{\s*if \(nativeGateway === gateway && _syncProblem\.value == NATIVE_ACCOUNT_UNAVAILABLE\) _syncProblem\.value = null/);
  assert.doesNotMatch(body, /upgradeRequiredLease\s*=|clearPushed|setLastVersion|signOut|sessionState/);
});
test('failed native compatibility is not an empty-account or retired-writer acknowledgement', () => {
  const coordinator = source('engine/NativeAccountCoordinator.kt');
  const retire = method('    override fun retire() {', coordinator);
  assert.match(retire, /mounted\.getAndSet\(null\)\.also \{ if \(it != null\) \{ it\.retireRead\(\); retired\.add\(it\.session\) \} \}/);
  assert.match(retire, /if \(old != null\) \{\s*dispose \{ closeRetired\(old\.session\) \}/);
  assert.doesNotMatch(retire, /retired\.remove\(/);
  const close = method('    private fun closeRetired(', coordinator);
  assert.match(close, /= synchronized\(session\) \{\s*try \{ session\.close\(\) \}\s*catch \(failure: Throwable\) \{\s*noteUnconfirmedRestoreRetirement\(\)\s*throw failure\s*\}\s*retired\.remove\(session\)/);
  for (const [signature, checkpointRead] of [
    ['    private suspend fun reopenCheckpointLocked(', 'checkpoints.discover(namespace)'],
    ['    private suspend fun applyRawDocumentInternal(', 'checkpoints.captureCheckpoint(scope)'],
    ['    private suspend fun applyDocumentLocked(', 'val resources = transport()'],
  ]) {
    const body = method(signature, coordinator);
    const closeWriter = body.indexOf('while (true) { val prior = retired.peek() ?: break; closeRetired(prior) }');
    assert(closeWriter >= 0 && closeWriter < body.indexOf(checkpointRead));
  }
  const down = method('    private suspend fun nativeSyncDown(');
  assert.match(down, /fun restoreFailed\(stage: String\): Boolean \{\s*if \(recovering && isSyncLeaseCurrent\(lease\) && publicationCurrent\(\)\) \{\s*DiagnosticsLog\.log\("native-account", "restore result=failed stage=\$stage"\)\s*\}\s*return false\s*\}/);
  assert.match(down, /val reopened = try \{[^\n]*gateway\.reopenCheckpoint\(account\)[^\n]*\}\s*catch \(cancel: kotlinx\.coroutines\.CancellationException\) \{ throw cancel \}\s*catch \(_: Exception\) \{ return restoreFailed\("checkpoint_open"\) \}/);
  assert.doesNotMatch(helper, /\b(?:reset|clear|fallback|nativeInitRuntime|prepareEmptyAccount|replaceSession)\s*\(/);
});
test('the actual operation uses the same captured gateway, including empty-account delegation', () => {
  const down = method('    private suspend fun nativeSyncDown(');
  const up = method('    private suspend fun nativeSyncUp(');
  for (const body of [up, down]) {
    assert(body.includes('gateway: NativeAccountGateway'));
    assert.match(body, /\): Boolean \{\s*if \(gateway !== nativeGateway \|\| !publicationCurrent\(\)\) return false/);
    assert(!body.includes('val gateway = nativeGateway'));
  }
  assert.match(down, /val pulled = pullSyncDocResult\(lease, allowOlderAddonTombstones = false,\s*ifNoneMatch = conditionalVersion, publicationCurrent = publicationCurrent\)\s*if \(!publicationCurrent\(\)\) return false/);
  assert.match(down, /if \(pulled is SyncDocPull\.Empty\) \{\s*val seeded = nativeSyncUp\(lease, gateway, publicationCurrent\)\s*return seeded \|\| restoreFailed\("account_create"\)\s*\}/);
  assert.match(down, /val originalPull = pulled as\? SyncDocPull\.Doc \?: return restoreFailed\("backup_read"\)/);
});
