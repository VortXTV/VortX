#!/usr/bin/env node
// Compile current native-only source-extracted decisions with synthetic collaborators. No Android app build.
// Exact manager/VM methods are extracted at execution time; no reimplementation of those methods.
import assert from "node:assert/strict";
import { readFile, writeFile, mkdir, mkdtemp, readdir } from "node:fs/promises";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
const repo = resolve(fileURLToPath(new URL("..", import.meta.url)));
const kotlin = process.env.VORTX_KOTLIN_LIB;
const deps = process.env.VORTX_ANDROID_AUDIT_DEPS;
const java = process.env.VORTX_TEST_JAVA || "java";
assert(kotlin && deps, "VORTX_KOTLIN_LIB and VORTX_ANDROID_AUDIT_DEPS are required");
const manager = await readFile(join(repo, "android/app/src/main/kotlin/com/vortx/android/sync/VortXSyncManager.kt"), "utf8");
const vm = await readFile(join(repo, "android/app/src/main/kotlin/com/vortx/android/ui/viewmodel/VortXAccountViewModel.kt"), "utf8");
const backup = await readFile(join(repo, "android/app/src/main/kotlin/com/vortx/android/backup/SettingsBackup.kt"), "utf8");
function method(text, name) {
  const match = text.match(new RegExp("    (?:private )?(?:suspend )?fun " + name + "\\([^]*?\\n    \\}"));
  assert(match, "Missing source method: " + name);
  return match[0];
}
const note = method(manager, "noteLocalSettingsChange");
const use = method(manager, "useAccountData");
const merge = method(manager, "mergeBoth");
const reconcile = method(vm, "resolveReconcile");
const profileKeys = manager.match(/        private val NATIVE_PROFILE_SETTING_KEYS = setOf\([^]*?\n        \)/)?.[0];
const settingTypes = backup.match(/    val SYNCABLE_SETTING_TYPES:[^]*?\n    \)/)?.[0];
const settingEnum = backup.match(/    enum class SettingType[^\n]*/)?.[0];
assert(profileKeys && settingTypes && settingEnum, "Expected current production setting ownership definitions");
assert(use.includes(": Boolean") && reconcile.includes("() -> Boolean"), "Manager and VM must retain real outcome types");
assert(![note, use, merge].some(text => text.includes("BuildConfig.NATIVE_ENGINE_ENABLED") || text.includes("onComparisonReceiveCompleted")),
    "This lane checks native-only decisions, not the retired comparison implementation");
console.log("Native-only manager SHA-256:", createHash("sha256").update(manager).digest("hex"));
console.log("Account ViewModel SHA-256:", createHash("sha256").update(vm).digest("hex"));
const parent = join(repo, "android/app/build");
await mkdir(parent, { recursive: true });
const out = await mkdtemp(join(parent, "sync-decisions."));
const fixture = `package com.vortx.android.sync

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow

// State/transport/publication collaborators are synthetic. Methods below are copied from source.
internal object SettingsBackup {
${settingEnum}
${settingTypes}
    fun isSyncable(key: String) = key in SYNCABLE_SETTING_TYPES
}
internal data class FixtureLease(val generation: Int)
internal class FixtureManager {
    var settings = mapOf<String, Any>()
    private var settingsShadow = mapOf<String, Any>()
    var signedIn = true
    val isSignedIn get() = signedIn
    var applyingRemote = false
    var generation = 0
    var invalidateCapture = false
    var staleDuringDomainRead = false
    val dirty = mutableMapOf<String, Double>()
    var armed = 0
    var recordEditSeen = false
    var receive = true
    var push = true
    var pending = false
    var staleAfterReceive = false
    var gets = 0
    var puts = 0
    var realtime = 0
    val syncProblem = MutableStateFlow<String?>(null)
    private fun currentSyncableDomain() = settings.also { if (staleDuringDomainRead) generation++ }
    private fun readDirtySettings() = dirty.toMutableMap()
    private fun writeDirtySettings(value: Map<String, Double>) { dirty.clear(); dirty.putAll(value) }
    private fun captureSyncLease(): FixtureLease? = if (!signedIn) null else FixtureLease(generation).also { if (invalidateCapture) generation++ }
    private fun isSyncLeaseCurrent(lease: FixtureLease) = signedIn && lease.generation == generation
    private fun publishIfSyncLeaseCurrent(lease: FixtureLease, block: () -> Unit): Boolean {
        if (!isSyncLeaseCurrent(lease)) return false
        block(); return true
    }
    private fun armPendingSync(lease: FixtureLease, recordEdit: Boolean) {
        check(isSyncLeaseCurrent(lease)); armed++; recordEditSeen = recordEdit
    }
    private fun retryPendingPushBeforePull(lease: FixtureLease): Boolean { check(isSyncLeaseCurrent(lease)); return pending }
    private suspend fun syncDown(lease: FixtureLease, force: Boolean): Boolean {
        check(isSyncLeaseCurrent(lease)); check(force); gets++; if (staleAfterReceive) generation++
        return receive
    }
    private suspend fun syncUp(lease: FixtureLease): Boolean { check(isSyncLeaseCurrent(lease)); puts++; return push }
    fun captureLocalLibraryMutationAdmission(): ((() -> Boolean) -> Boolean)? {
        val captured = generation
        return { block -> captured == generation && block() }
    }
    fun startRealtime() { realtime++ }
    fun changed() = noteLocalSettingsChange()
${note}
${use}
${merge}
    companion object {
${profileKeys}
    }
}
internal class FixtureViewModel(val sync: FixtureManager) {
    val _syncing = MutableStateFlow(false)
    val _showReconcile = MutableStateFlow(true)
    val _syncNotice = MutableStateFlow<String?>(null)
    val viewModelScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    fun choose(action: suspend () -> Boolean) = resolveReconcile(action)
${reconcile}
    companion object { const val RECONCILE_RETRY_NOTICE = "retry fixture" }
}
private var cases = 0
private suspend fun case(name: String, block: suspend () -> Unit) { block(); cases++; println("PASS " + name) }
fun main() = runBlocking {
    case("global-only edit owns native upload") {
        val m = FixtureManager(); m.settings = mapOf("vortx.player.matchFrameRate" to true); m.changed()
        check(m.armed == 1 && m.recordEditSeen && "vortx.player.matchFrameRate" in m.dirty)
        m.changed(); check(m.armed == 1)
    }
    case("remote applies and native profile mirrors do not upload globals") {
        val remote = FixtureManager(); remote.applyingRemote = true
        remote.settings = mapOf("vortx.player.matchFrameRate" to true); remote.changed()
        check(remote.armed == 0 && remote.dirty.isEmpty())
        val m = FixtureManager()
        for (key in listOf("stremiox.theme.accent", "stremiox.sub.color", "stremiox.sub.sizeScale")) {
            m.settings = m.settings + (key to "fixture"); m.changed()
        }
        check(m.armed == 0)
    }
    case("signed-out and stale-capture listeners cannot record another account's edit") {
        val off = FixtureManager(); off.signedIn = false; off.settings = mapOf("vortx.player.matchFrameRate" to true); off.changed()
        check(off.armed == 0 && off.dirty.isEmpty())
        val stale = FixtureManager(); stale.invalidateCapture = true; stale.settings = mapOf("vortx.player.matchFrameRate" to true); stale.changed()
        check(stale.armed == 0 && stale.dirty.isEmpty())
    }
    case("callback cannot adopt the account replacing its original domain read") {
        val m = FixtureManager(); m.staleDuringDomainRead = true
        m.settings = mapOf("vortx.player.matchFrameRate" to true); m.changed()
        check(m.armed == 0 && m.dirty.isEmpty())
    }
    case("failed native receive never becomes a merge success by later push") {
        val m = FixtureManager(); m.receive = false
        check(!m.mergeBoth() && m.gets == 1 && m.puts == 0)
    }
    case("native merge requires receive push and a current account") {
        val good = FixtureManager(); check(good.mergeBoth() && good.gets == 1 && good.puts == 1)
        val rejected = FixtureManager(); rejected.push = false; check(!rejected.mergeBoth() && rejected.puts == 1)
        val stale = FixtureManager(); stale.staleAfterReceive = true; check(!stale.mergeBoth() && stale.puts == 0)
        val pending = FixtureManager(); pending.pending = true; check(!pending.mergeBoth() && pending.gets == 0 && pending.puts == 0)
    }
    case("use-account outcome retains receive failure and account fencing") {
        val fail = FixtureManager(); fail.receive = false; check(!fail.useAccountData())
        val good = FixtureManager(); check(good.useAccountData())
        val stale = FixtureManager(); stale.staleAfterReceive = true; check(!stale.useAccountData())
    }
    case("failed reconciliation stays visible and can retry") {
        val m = FixtureManager(); val v = FixtureViewModel(m)
        v.choose { false }; check(v._showReconcile.value && !v._syncing.value && v._syncNotice.value != null && m.realtime == 0)
        v.choose { true }; check(!v._showReconcile.value && !v._syncing.value && v._syncNotice.value == null && m.realtime == 1)
        v.viewModelScope.cancel()
    }
    case("pending reconciliation keeps choice and admits only one submission") {
        val m = FixtureManager(); val v = FixtureViewModel(m); val gate = CompletableDeferred<Boolean>(); var calls = 0
        v.choose { calls++; gate.await() }
        check(v._showReconcile.value && v._syncing.value && calls == 1)
        v.choose { calls++; true }; check(calls == 1)
        gate.complete(false)
        check(v._showReconcile.value && !v._syncing.value && v._syncNotice.value != null)
        v.viewModelScope.cancel()
    }
    case("reconcile exception and cancelled action never settle the choice") {
        val m = FixtureManager(); val v = FixtureViewModel(m)
        v.choose { error("synthetic transport") }
        check(v._showReconcile.value && !v._syncing.value && v._syncNotice.value != null && m.realtime == 0)
        val cancelled = FixtureViewModel(m)
        cancelled.choose { throw CancellationException("synthetic cancellation") }
        check(cancelled._showReconcile.value && !cancelled._syncing.value && m.realtime == 0)
        v.viewModelScope.cancel(); cancelled.viewModelScope.cancel()
    }
    case("late reconciliation cannot settle a replacement account") {
        val m = FixtureManager(); val v = FixtureViewModel(m); val gate = CompletableDeferred<Boolean>()
        v.choose { gate.await() }; m.generation++; gate.complete(true)
        check(v._showReconcile.value && v._syncNotice.value == null && m.realtime == 0)
        v.viewModelScope.cancel()
    }
    println("OK source-extracted sync decisions: " + cases + " cases")
}
`;
const fixturePath = join(out, "SyncDecisions.kt");
await writeFile(fixturePath, fixture);
const jars = await readdir(kotlin);
const stdlib = jars.find(x => /^kotlin-stdlib-[0-9][^/]*\.jar$/.test(x));
const coroutines = jars.find(x => /^kotlinx-coroutines-core-jvm-.*\.jar$/.test(x));
assert(stdlib && coroutines, "Compiler distribution stdlib/coroutines jars required");
const cp = [join(kotlin, stdlib), join(kotlin, coroutines)].join(":");
function run(args) {
  const result = spawnSync(java, ["-XX:ActiveProcessorCount=1", ...args], { cwd: repo, stdio: "inherit" });
  assert.equal(result.status, 0, "Standalone compiler or extracted JVM cases failed");
}
run(["-Xmx512m", "-cp", join(kotlin, "*"), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
  "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-Xbackend-threads=1", "-classpath", cp,
  fixturePath, join(repo, "android/app/src/main/kotlin/com/vortx/android/sync/SettingsDirtyKeys.kt"),
  "-d", join(out, "classes")]);
run(["-Xmx128m", "-cp", join(out, "classes") + ":" + cp, "com.vortx.android.sync.SyncDecisionsKt"]);
console.log("Retained generated source and classes:", out);
