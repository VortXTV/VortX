#!/usr/bin/env node
// Actual native receive wrapper, account choice, compatibility helper and notice methods.
// The native transaction, account lease, gateway and storage collaborators are synthetic.
// This is NOT the full native join/ACK algorithm, JNI, Android composition or device proof.
import assert from "node:assert/strict";
import { readFile, writeFile, mkdir, mkdtemp, readdir } from "node:fs/promises";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
const repo = resolve(fileURLToPath(new URL("..", import.meta.url)));
const kotlin = process.env.VORTX_KOTLIN_LIB;
const java = process.env.VORTX_TEST_JAVA || "java";
assert(kotlin, "VORTX_KOTLIN_LIB is required");
assert(!process.env.VORTX_SYNC_RECEIVE_REVISION && process.env.VORTX_SYNC_RECEIVE_UNFIXED !== "1",
    "Current native receive evidence cannot be relabelled as historical comparison evidence");
const relative = "android/app/src/main/kotlin/com/vortx/android/sync/VortXSyncManager.kt";
const source = await readFile(join(repo, relative), "utf8");
function method(name, prefix) {
    const match = source.match(new RegExp("    " + prefix + "fun " + name + "\\([^]*?\\n    \\}"));
    assert(match, "Missing exact source method " + name);
    return match[0];
}
const down = method("syncDown", "private suspend ");
const use = method("useAccountData", "suspend ");
const mark = method("markNativeAccountUnavailable", "private ");
const clear = method("clearNativeAccountUnavailable", "private ");
const notice = source.match(/        private const val NATIVE_ACCOUNT_UNAVAILABLE =\n            "[^"\n]+"/)?.[0];
assert(notice, "Fixed compatibility notice must be extracted from actual source");
assert(!down.includes("BuildConfig") && !use.includes("onComparisonReceiveCompleted"),
    "This lane requires the native-only receive and choice boundary");
assert(down.includes("nativeSyncDown(lease, gateway, force, routineReceive)") &&
       down.includes("nativeSyncMutex.withLock"), "Actual gateway-bound worker/mutex required");
const helper = join(repo, "android/app/src/main/kotlin/com/vortx/android/sync/NativeAccountAttempt.kt");
const helperSource = await readFile(helper, "utf8");
console.log("Native receive manager SHA-256:", createHash("sha256").update(source).digest("hex"));
console.log("Native attempt helper SHA-256:", createHash("sha256").update(helperSource).digest("hex"));
const parent = join(repo, "android/app/build");
await mkdir(parent, { recursive: true });
const out = await mkdtemp(join(parent, "native-receive-boundary."));
const fixture = `package com.vortx.android.sync
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal data class SyncSessionLease(val generation: Int)
internal class NativeAccountGateway
internal object DiagnosticsLog {
    var lines = 0
    fun log(category: String, text: String) {
        check(category == "native-account")
        check(text == "sync result=failed reason=native_linkage_unavailable")
        lines++
    }
}
internal class FixtureReceiveManager {
    var generation = 0
    var signedIn = true
    var nativeReceived = true
    var nativeGateway: NativeAccountGateway? = NativeAccountGateway()
    var failure: Throwable? = null
    var beforeResult: (() -> Unit)? = null
    var calls = 0
    var forceSeen = false
    var upgrade = false
    private val nativeSyncMutex = Mutex()
    private val nativeWorkDispatcher = Dispatchers.Unconfined
    private val _syncProblem = MutableStateFlow<String?>(null)
    var notice: String?
        get() = _syncProblem.value
        set(value) { _syncProblem.value = value }
    private fun captureSyncLease() = if (signedIn) SyncSessionLease(generation) else null
    private fun isSyncLeaseCurrent(lease: SyncSessionLease) = signedIn && lease.generation == generation
    private fun publishIfSyncLeaseCurrent(lease: SyncSessionLease, action: () -> Unit): Boolean {
        if (!isSyncLeaseCurrent(lease)) return false
        action(); return true
    }
    private fun requiresUpgrade(lease: SyncSessionLease) = upgrade && isSyncLeaseCurrent(lease)
    private suspend fun nativeSyncDown(lease: SyncSessionLease, gateway: NativeAccountGateway,
                                      force: Boolean, routineReceive: Boolean): Boolean {
        calls++; forceSeen = force
        check(!routineReceive)
        beforeResult?.invoke()
        failure?.let { throw it }
        return nativeReceived && isSyncLeaseCurrent(lease)
    }
${mark}
${clear}
${down}
${use}
    companion object {
${notice}
    }
}
private var cases = 0
private suspend fun case(name: String, action: suspend () -> Unit) {
    action(); cases++; println("PASS " + name)
}
fun main() = runBlocking {
    val unavailable = "The native engine is unavailable or incompatible. Your saved data and pending changes are preserved. Update VortX or export diagnostics, then retry sync."
    case("native account choice requires admitted native success") {
        val good = FixtureReceiveManager()
        check(good.useAccountData() && good.calls == 1 && good.forceSeen)
        val failed = FixtureReceiveManager(); failed.nativeReceived = false
        check(!failed.useAccountData() && failed.calls == 1)
        val off = FixtureReceiveManager(); off.signedIn = false
        check(!off.useAccountData() && off.calls == 0)
    }
    case("missing gateway cannot mint receive success or a compatibility notice") {
        val m = FixtureReceiveManager(); m.nativeGateway = null
        check(!m.useAccountData() && m.calls == 0 && m.notice == null)
    }
    case("stale account cannot settle old receive") {
        val m = FixtureReceiveManager(); m.beforeResult = { m.generation++ }
        check(!m.useAccountData() && m.calls == 1 && m.notice == null)
    }
    case("linkage becomes fixed recoverable failure and logs once") {
        val m = FixtureReceiveManager()
        m.failure = UnsatisfiedLinkError("fixture/private?token=fixture-private")
        val before = DiagnosticsLog.lines
        check(!m.useAccountData() && m.notice == unavailable && DiagnosticsLog.lines == before + 1)
        check(!m.useAccountData() && m.notice == unavailable && DiagnosticsLog.lines == before + 1)
    }
    case("ordinary failure retains existing policy and cannot clear native notice") {
        val m = FixtureReceiveManager(); m.notice = unavailable
        m.failure = IllegalStateException("fixture ordinary")
        check(!m.useAccountData() && m.notice == unavailable)
        m.failure = null; m.nativeReceived = false
        check(!m.useAccountData() && m.notice == unavailable)
    }
    case("cancellation and fatal identities remain exact and produce no retry notice") {
        for (failure in listOf(CancellationException("fixture"),
            AssertionError("fixture"), OutOfMemoryError("fixture"), StackOverflowError("fixture"))) {
            val m = FixtureReceiveManager(); m.failure = failure
            var caught: Throwable? = null
            try { m.useAccountData() } catch (actual: Throwable) { caught = actual }
            check(caught === failure && m.notice == null)
        }
    }
    case("replacement account and gateway reject old linkage status") {
        val account = FixtureReceiveManager()
        account.beforeResult = { account.generation++ }
        account.failure = UnsatisfiedLinkError("fixture")
        check(!account.useAccountData() && account.notice == null)
        val gateway = FixtureReceiveManager()
        gateway.beforeResult = { gateway.nativeGateway = NativeAccountGateway() }
        gateway.failure = UnsatisfiedLinkError("fixture")
        check(!gateway.useAccountData() && gateway.notice == null)
    }
    case("only successful current native operation clears its own notice") {
        val success = FixtureReceiveManager(); success.notice = unavailable
        check(success.useAccountData() && success.notice == null)
        val replacement = FixtureReceiveManager(); replacement.notice = unavailable
        replacement.beforeResult = { replacement.nativeGateway = NativeAccountGateway() }
        replacement.useAccountData()
        check(replacement.notice == unavailable)
    }
    case("upgrade-required status is neither replaced nor cleared") {
        val m = FixtureReceiveManager(); m.upgrade = true; m.notice = "upgrade fixture"
        m.failure = UnsatisfiedLinkError("fixture")
        check(!m.useAccountData() && m.notice == "upgrade fixture")
        m.failure = null
        check(m.useAccountData() && m.notice == "upgrade fixture")
    }
    println("OK actual native receive boundary: " + cases + " cases")
}
`;
const fixturePath = join(out, "NativeReceiveBoundary.kt");
await writeFile(fixturePath, fixture);
const jars = await readdir(kotlin);
const stdlib = jars.find(x => /^kotlin-stdlib-[0-9][^/]*\.jar$/.test(x));
const coroutines = jars.find(x => /^kotlinx-coroutines-core-jvm-.*\.jar$/.test(x));
assert(stdlib && coroutines, "Compiler distribution stdlib/coroutines jars required");
const cp = [join(kotlin, stdlib), join(kotlin, coroutines)].join(":");
function run(args) {
    const result = spawnSync(java, ["-XX:ActiveProcessorCount=1", ...args], { cwd: repo, stdio: "inherit" });
    assert.equal(result.status, 0, "Actual-native receive boundary check failed");
}
run(["-Xmx512m", "-cp", join(kotlin, "*"), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
    "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-Xbackend-threads=1", "-classpath", cp,
    fixturePath, helper, "-d", join(out, "classes")]);
run(["-Xmx128m", "-cp", join(out, "classes") + ":" + cp, "com.vortx.android.sync.NativeReceiveBoundaryKt"]);
console.log("Retained native boundary source/classes (not full native transaction):", out);
