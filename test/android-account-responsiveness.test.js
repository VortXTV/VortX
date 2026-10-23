"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const source = fs.readFileSync(path.join(__dirname,
    "../android/app/src/main/kotlin/com/vortx/android/sync/VortXSyncManager.kt"), "utf8");

// Source boundaries, not an Android crash reproduction or a replacement for coroutine tests.
function method(signature) {
    const start = source.indexOf(signature);
    assert(start >= 0 && source.indexOf(signature, start + signature.length) < 0);
    const end = source.indexOf("\n    }", start);
    assert(end > start);
    return source.slice(start, end + 6);
}

test("key derivation moves computation, not secret ownership, across the dispatcher boundary", () => {
    const helper = method("    private suspend fun deriveAuthKey(");
    assert(helper.includes("val pending = AtomicReference<ByteArray?>()"));
    assert(helper.includes("withContext(Dispatchers.Default) { pending.set(derive()) }"));
    assert(helper.includes("return checkNotNull(pending.getAndSet(null))"));
    assert.match(helper, /finally \{\s*pending\.getAndSet\(null\)\?\.fill\(0\)/);
    assert(!helper.includes("catch"), "cancellation and fatal errors must propagate");
});

test("all auth flows preserve intent/adoption context and own temporary keys until cleanup", () => {
    for (const [name, keys] of [["register", ["masterKey", "recoveryKey"]],
        ["signIn", ["masterKey"]], ["recover", ["recoveryKey", "newMaster"]]]) {
        const body = method(`    suspend fun ${name}(`);
        assert(body.indexOf("beginAuthOperation()") < body.indexOf("deriveAuthKey {"));
        assert.equal((body.match(/deriveAuthKey \{/g) || []).length, keys.length);
        assert(!body.includes("withContext("), "adoption must stay on the caller context");
        assert(body.includes("adopt(operation, token, acct, dataKey)"));
        assert(!body.includes("dataKey.fill("), "do not wipe the adopted session key");
        for (const key of keys) {
            assert.match(body, new RegExp(`val ${key} = deriveAuthKey \\{[^\\n]+\\}\\n\\s*try \\{`));
            assert.match(body, new RegExp(`finally \\{\\s*${key}\\.fill\\(0\\)\\s*\\}`));
        }
    }
});

test("native sync uses only the worker dispatcher while retaining caller cancellation and mutex", () => {
    assert.match(source, /scope\.coroutineContext\[ContinuationInterceptor\] as\? CoroutineDispatcher \?: Dispatchers\.IO/);
    for (const [signature, call] of [["    private suspend fun syncUp(lease:", "nativeSyncUp(lease, gateway)"],
        ["    private suspend fun syncDown(\n", "nativeSyncDown(lease, gateway, force, routineReceive)"]]) {
        const body = method(signature);
        assert(body.includes("withContext(nativeWorkDispatcher)"));
        assert(body.includes("nativeSyncMutex.withLock {"));
        assert(body.includes("val gateway = nativeGateway ?: return@withLock false"));
        assert(body.includes(call));
        assert(body.indexOf("withContext(nativeWorkDispatcher)") < body.indexOf("nativeSyncMutex.withLock {"));
        assert(body.indexOf("nativeSyncMutex.withLock {") < body.indexOf("val gateway = nativeGateway"));
        assert(body.indexOf("val gateway = nativeGateway") < body.indexOf(call));
        assert(!body.includes("withContext(scope.coroutineContext"));
        assert(body.includes("catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel }"));
        assert(body.includes("if (!isSyncLeaseCurrent(lease)"));
    }
});
