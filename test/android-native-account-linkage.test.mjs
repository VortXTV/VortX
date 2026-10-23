import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const root = new URL('../android/app/src/main/kotlin/com/vortx/android/', import.meta.url);
const source = name => readFileSync(new URL(name, root), 'utf8');
const manager = source('sync/VortXSyncManager.kt');
const helper = source('sync/NativeAccountAttempt.kt');
function method(signature) {
  const start = manager.indexOf(signature);
  assert(start >= 0 && manager.indexOf(signature, start + signature.length) < 0);
  const end = manager.indexOf('\n    }', start);
  assert(end > start);
  return manager.slice(start, end + 6);
}
test('compatibility helper catches only linkage and preserves cancellation/fatal policy', () => {
  assert.match(helper, /catch \(cancel: CancellationException\) \{\s*throw cancel/);
  assert.match(helper, /catch \(_: LinkageError\) \{[\s\S]*currentCoroutineContext\(\)\.ensureActive\(\)[\s\S]*onUnavailable\(\)[\s\S]*false/);
  assert.doesNotMatch(helper, /catch[^\n]*:\s*(?:Throwable|VirtualMachineError|AssertionError|Exception)\)/);
  assert.doesNotMatch(helper, /\.message|\.stackTrace|\.cause|prepareEmptyAccount|signOut|Preview|retired\.remove/);
});
test('post-auth background and manual native sync share the same compatibility boundary', () => {
  for (const [signature, call] of [['    private suspend fun syncUp(lease:', 'nativeSyncUp(lease, gateway)'],
    ['    private suspend fun syncDown(\n', 'nativeSyncDown(lease, gateway, force, routineReceive)']]) {
    const body = method(signature);
    assert(body.includes('return try { withContext(nativeWorkDispatcher) {'));
    assert(!body.includes('BuildConfig.NATIVE_ENGINE_ENABLED'));
    assert(body.includes('val gateway = nativeGateway ?: return@withLock false'));
    assert(body.includes('runNativeAccountAttempt(onUnavailable = { markNativeAccountUnavailable(lease, gateway) })'));
    assert(body.includes('withContext(nativeWorkDispatcher)'));
    assert(body.includes('nativeSyncMutex.withLock {'));
    assert(body.includes(call));
    assert(body.includes('.also { if (it) clearNativeAccountUnavailable(lease, gateway) }'));
    assert(body.indexOf('nativeSyncMutex.withLock {') < body.indexOf('val gateway = nativeGateway'));
    assert(body.indexOf('val gateway = nativeGateway') < body.indexOf('runNativeAccountAttempt('));
    const lockStart = body.indexOf('nativeSyncMutex.withLock {');
    const lockEnd = body.indexOf('\n            }', lockStart);
    assert(lockEnd > lockStart);
    const locked = body.slice(lockStart, lockEnd);
    assert(locked.includes('markNativeAccountUnavailable(lease, gateway)'));
    assert(locked.includes('clearNativeAccountUnavailable(lease, gateway)'));
    assert(body.includes('catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }'));
    assert(body.includes('catch (_: Exception) { false }'));
  }
});
test('native failure notice and one fixed diagnostic line retain captured account admission', () => {
  const body = method('    private fun markNativeAccountUnavailable(');
  assert.match(body, /publishIfSyncLeaseCurrent\(lease\) \{[\s\S]*_syncProblem\.value = NATIVE_ACCOUNT_UNAVAILABLE/);
  assert(body.includes('firstNotice = _syncProblem.value != NATIVE_ACCOUNT_UNAVAILABLE'));
  assert(body.includes('if (nativeGateway === gateway && !requiresUpgrade(lease)) {'));
  assert(body.includes('if (firstNotice) DiagnosticsLog.log("native-account", "sync result=failed reason=native_linkage_unavailable")'));
  assert.doesNotMatch(body, /error\.|throwable|\.message|\.stackTrace|\.cause|accountId|token/);
});
test('native recovery cannot clear another account or an unrelated upgrade notice', () => {
  const body = method('    private fun clearNativeAccountUnavailable(');
  assert.match(body, /publishIfSyncLeaseCurrent\(lease\) \{\s*if \(nativeGateway === gateway && _syncProblem\.value == NATIVE_ACCOUNT_UNAVAILABLE\) _syncProblem\.value = null/);
  assert.doesNotMatch(body, /upgradeRequiredLease\s*=|clearPushed|setLastVersion|signOut|sessionState/);
});
test('failed native compatibility is not an empty-account or retired-writer acknowledgement', () => {
  const coordinator = source('engine/NativeAccountCoordinator.kt');
  assert(coordinator.includes('dispose { old.session.close(); retired.remove(old.session) }'));
  assert(coordinator.includes('prior.close(); retired.remove(prior)'));
  assert.match(method('    private suspend fun nativeSyncDown('), /catch \(_: Exception\) \{ return false \}/);
  assert.doesNotMatch(helper, /\b(?:reset|clear|fallback|nativeInitRuntime|prepareEmptyAccount|replaceSession)\s*\(/);
});
test('the actual operation uses the same captured gateway, including empty-account delegation', () => {
  const down = method('    private suspend fun nativeSyncDown(');
  const up = method('    private suspend fun nativeSyncUp(');
  for (const body of [up, down]) {
    assert(body.includes('gateway: NativeAccountGateway'));
    assert(body.includes('if (gateway !== nativeGateway) return false'));
    assert(!body.includes('val gateway = nativeGateway'));
  }
  assert.match(down, /if \(pulled is SyncDocPull\.Empty\) \{\s*return nativeSyncUp\(lease, gateway\)/);
});
