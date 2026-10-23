#!/usr/bin/env node
// Default: current native-only receive boundary. Explicit pinned revision: retired comparison regression.
// Historical comparison is evidence about that immutable revision only, not shipping behavior.
// Storage, parsed projection, publication, native gateway and transport collaborators are synthetic.
import assert from "node:assert/strict";
import { readFile, writeFile, mkdir, mkdtemp, readdir } from "node:fs/promises";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
const repo = resolve(fileURLToPath(new URL("..", import.meta.url)));
const historicalRevision = "27d4d91747789ebc8192b751bf1e3ef7e1d0c224";
if (!process.env.VORTX_SYNC_RECEIVE_REVISION) {
  assert(process.env.VORTX_SYNC_RECEIVE_UNFIXED !== "1",
      "Comparison reversal requires the explicit pinned historical revision, not current native source");
  const result = spawnSync(process.execPath, [join(repo, "scripts/test-android-native-receive.mjs")],
      { cwd: repo, stdio: "inherit", env: process.env });
  assert.equal(result.status, 0, "Current native receive boundary failed");
  process.exit(0);
}
assert.equal(process.env.VORTX_SYNC_RECEIVE_REVISION, historicalRevision,
    "Retired comparison regression must use its reviewed immutable source revision");
console.log("HISTORICAL ONLY: retired comparison implementation at", historicalRevision);
const kotlin = process.env.VORTX_KOTLIN_LIB;
const deps = process.env.VORTX_ANDROID_AUDIT_DEPS;
const java = process.env.VORTX_TEST_JAVA || "java";
assert(kotlin && deps, "Compiler and public standalone dependencies required");
const relative = "android/app/src/main/kotlin/com/vortx/android/sync/VortXSyncManager.kt";
let source;
if (process.env.VORTX_SYNC_RECEIVE_REVISION) {
  const result = spawnSync("git", ["-C", repo, "show", process.env.VORTX_SYNC_RECEIVE_REVISION + ":" + relative], { encoding: "utf8" });
  assert.equal(result.status, 0, "Pinned comparison baseline must resolve");
  source = result.stdout;
} else source = await readFile(join(repo, relative), "utf8");
if (process.env.VORTX_SYNC_RECEIVE_UNFIXED === "1") {
  // Reverse only the exact source hunks of this correction in memory. The prior Git HEAD
  // predates the Boolean outcome API, so it is not the behavioral baseline for this repair.
  const replacements = [
    ["        onComparisonReceiveCompleted: () -> Unit = {},\n", ""],
    ["        // Comparison mode's return value describes changed fields, not admission. A valid no-op\n" +
      "        // restore is complete only here, after publication/library receipts and durable revision ACK.\n" +
      "        if (!isSyncLeaseCurrent(lease)) return false\n" +
      "        onComparisonReceiveCompleted()\n", ""],
    ["        var comparisonReceiveCompleted = false\n" +
      "        val restored = syncDown(lease, force = true,\n" +
      "            onComparisonReceiveCompleted = { comparisonReceiveCompleted = true })\n" +
      "        val received = if (com.vortx.android.BuildConfig.NATIVE_ENGINE_ENABLED) restored else comparisonReceiveCompleted\n" +
      "        return received && isSyncLeaseCurrent(lease)",
      "        val restored = syncDown(lease, force = true)\n" +
      "        return restored && isSyncLeaseCurrent(lease)"],
  ];
  for (const [fixed, original] of replacements) {
    assert.equal(source.split(fixed).length, 2, "Exact correction hunk must occur once");
    source = source.replace(fixed, original);
  }
}
function extract(name, prefix) {
  const match = source.match(new RegExp("    " + prefix + "fun " + name + "\\([^]*?\\n    \\}"));
  assert(match, "Missing exact source method " + name);
  return match[0];
}
const down = extract("syncDown", "private suspend ");
const use = extract("useAccountData", "suspend ");
const historicalHelper = spawnSync("git", ["-C", repo, "show",
  historicalRevision + ":android/app/src/main/kotlin/com/vortx/android/sync/NativeAccountAttempt.kt"], { encoding: "utf8" });
assert.equal(historicalHelper.status, 0, "Pinned historical compatibility helper must resolve");
const nativeAttemptSource = historicalHelper.stdout;
const nativeAttempt = nativeAttemptSource.slice(nativeAttemptSource.indexOf("/**"));
assert(nativeAttempt.includes("internal suspend fun runNativeAccountAttempt("), "Exact native compatibility helper required");
console.log("Manager source SHA-256:", createHash("sha256").update(source).digest("hex"));
console.log("Source mode:", process.env.VORTX_SYNC_RECEIVE_UNFIXED === "1" ? "pinned historical source with exact comparison correction reversed in memory" :
    process.env.VORTX_SYNC_RECEIVE_REVISION || "current worktree");
const parent = join(repo, "android/app/build");
await mkdir(parent, { recursive: true });
const out = await mkdtemp(join(parent, "comparison-receive."));
const fixture = `@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package com.vortx.android.sync
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import org.json.JSONObject

internal data class SyncSessionLease(val generation: Int, val accountId: String = "fixture")
internal sealed interface SyncDocPull {
    data class Doc(val doc: JSONObject, val version: Long): SyncDocPull
    data object Failed: SyncDocPull
}
internal class FixtureParsed {
    val deletedLibrary = emptySet<String>()
    val deletedProfiles = emptySet<String>()
    val overlays = emptyMap<String, List<String>>()
    val ownerLibrary: List<String>? = null
    val roster: List<String>? = null
    val rosterModifiedSeconds: Double? = null
    val rosterIsLossless = true
}
internal object VortXSyncDoc { fun parse(document: JSONObject) = FixtureParsed() }
internal object OwnerLibraryHistoryPolicy { fun canonicalLibraryTombstones(parsed: FixtureParsed) = emptyMap<String, Double>() }
internal class FixtureTombstones { fun merge(rows: Set<String>, stamps: Map<String, Double>) = false }
internal data class FixtureFold(val changed: Boolean = false, val shouldApplyVersionedPayload: Boolean, val shouldFoldLibraryTombstones: Boolean = false)
internal data class FixtureRoster(val roster: List<String>? = null, val modifiedSeconds: Double? = null)
internal object SettingsBackup {
    fun resolveRosterForPull(pulledBlob: Any?, fallbackRoster: List<String>?, fallbackModifiedSeconds: Double?, fallbackIsLossless: Boolean) = FixtureRoster()
}
internal class FixtureStore {
    fun mergeDeletedTombstones(ids: Set<String>) = false
    fun applyRemoteOverlay(id: String, rows: List<String>) {}
    fun applyLocalTombstones() {}
}
internal class FixtureWatchedIntents { fun merge(accountId: String, value: JSONObject?) = true }
internal class FixtureLibraryGateway {
    fun captureAccountLibraryLease(): Int? = null
    fun ownerWatchedChanged(native: Int, admission: ((() -> Boolean) -> Boolean)) = true
}
${nativeAttempt}
internal class FixtureReceiveManager {
    var generation = 0
    var signedIn = true
    var pending = false
    var failPull = false
    var failPublication = false
    var failLibraryReceipt = false
    var failVersionAck = false
    var invalidateAtAck = false
    var applyFields = false
    var nativeReceived = true
    var gets = 0
    var acks = 0
    var version = 7L
    var lastVersion = 0L
    private var applyingRemote = false
    private val nativeSyncMutex = Mutex()
    private val nativeWorkDispatcher = Dispatchers.Unconfined
    private val nativeGateway: Any? = Any()
    private fun markNativeAccountUnavailable(lease: SyncSessionLease, gateway: Any) {}
    private fun clearNativeAccountUnavailable(lease: SyncSessionLease, gateway: Any) {}
    private val addonTombstones = FixtureTombstones()
    private val libraryTombstones = FixtureTombstones()
    private val ownerWatchedIntents = FixtureWatchedIntents()
    private val libraryGateway: FixtureLibraryGateway? = null
    private val versionedPayloadTestObserver: (() -> Unit)? = null
    private fun captureSyncLease() = if (signedIn) SyncSessionLease(generation) else null
    private fun isSyncLeaseCurrent(lease: SyncSessionLease) = signedIn && lease.generation == generation
    private suspend fun nativeSyncDown(lease: SyncSessionLease, force: Boolean, routineReceive: Boolean) = nativeReceived && isSyncLeaseCurrent(lease)
    private suspend fun nativeSyncDown(lease: SyncSessionLease, gateway: Any, force: Boolean, routineReceive: Boolean) = nativeReceived && isSyncLeaseCurrent(lease)
    private fun retryPendingPushBeforePull(lease: SyncSessionLease) = pending
    private suspend fun pullSyncDocResult(lease: SyncSessionLease, allowOlderAddonTombstones: Boolean): SyncDocPull {
        gets++
        return if (failPull) SyncDocPull.Failed else SyncDocPull.Doc(JSONObject().put("unknownPreservedField", "fixture"), version)
    }
    private fun lastSyncedVersion(lease: SyncSessionLease) = lastVersion
    private fun publishIfSyncLeaseCurrent(lease: SyncSessionLease, action: () -> Unit): Boolean {
        if (failPublication || !isSyncLeaseCurrent(lease)) return false
        action(); return true
    }
    private fun foldAddonTombstonesForSyncDown(tombstones: FixtureTombstones, parsed: FixtureParsed, pulledVersion: Long, lastSyncedVersion: Long, force: Boolean) =
        FixtureFold(shouldApplyVersionedPayload = pulledVersion >= lastSyncedVersion && (force || pulledVersion > lastSyncedVersion))
    private fun applyAddonTombstonesToVortx(value: JSONObject, tombstones: FixtureTombstones) = value
    private fun applyLibraryTombstonesToVortx(value: JSONObject) = value
    private fun refreshSettingsShadow() {}
    private fun requestSyncSoon() {}
    private fun enforceRemovedAccountAddons(lease: SyncSessionLease) = true
    private fun syncLeaseAdmission(lease: SyncSessionLease): ((() -> Boolean) -> Boolean) = { action -> isSyncLeaseCurrent(lease) && action() }
    private fun resolveStore() = FixtureStore()
    private fun foldNativeProfileRoster(store: FixtureStore, doc: JSONObject, roster: List<String>, modified: Double?, carrierIsLossless: Boolean) {}
    private fun foldDashboardProfileEdits(store: FixtureStore, doc: JSONObject) = false
    private fun applyDeviceSettings(value: Any?) = applyFields
    private fun applyRemoteAccountAddons(lease: SyncSessionLease, parsed: FixtureParsed) = false
    private fun applyRemoteOwnerLibrary(lease: SyncSessionLease, parsed: FixtureParsed) = !failLibraryReceipt
    private fun applyDebridKeys(value: JSONObject?) = false
    private fun applyMetadataKeys(value: JSONObject?) = false
    private fun advanceVersion(lease: SyncSessionLease, next: Long): Boolean {
        if (failVersionAck || !isSyncLeaseCurrent(lease)) return false
        acks++; lastVersion = next
        if (invalidateAtAck) generation++
        return true
    }
    private fun readDirtySettings() = emptyMap<String, Double>()
${down}
${use}
}
private var cases = 0
private suspend fun case(name: String, block: suspend () -> Unit) { block(); cases++; println("PASS " + name) }
fun main() = runBlocking {
    Dispatchers.setMain(Dispatchers.Unconfined)
    try {
        com.vortx.android.BuildConfig.NATIVE_ENGINE_ENABLED = false
        case("comparison changed-field positive control admits only after durable version ACK") {
            val m = FixtureReceiveManager(); m.applyFields = true
            check(m.useAccountData() && m.gets == 1 && m.acks == 1)
        }
        case("valid no-applicable-field comparison restore completes after durable version ACK") {
            val m = FixtureReceiveManager()
            check(m.useAccountData()) { "A completed no-op receive must settle account reconciliation" }
            check(m.gets == 1 && m.acks == 1 && m.lastVersion == 7L)
        }
        case("pull publication library-receipt and durable-ACK failures never complete") {
            val failures: List<(FixtureReceiveManager) -> Unit> = listOf(
                { it.failPull = true }, { it.failPublication = true },
                { it.failLibraryReceipt = true }, { it.failVersionAck = true })
            for (fail in failures) {
                val m = FixtureReceiveManager(); fail(m)
                check(!m.useAccountData() && m.acks == 0)
            }
        }
        case("pending local edits cannot mint comparison completion") {
            val m = FixtureReceiveManager(); m.pending = true
            check(!m.useAccountData() && m.gets == 0 && m.acks == 0)
        }
        case("older authenticated envelope cannot settle the forced account choice") {
            val m = FixtureReceiveManager(); m.lastVersion = 9L
            check(!m.useAccountData() && m.acks == 0)
        }
        case("account replacement at final ACK cannot settle the old choice") {
            val m = FixtureReceiveManager(); m.invalidateAtAck = true
            check(!m.useAccountData() && m.acks == 1)
        }
        case("native admission result remains strict and does not use comparison completion") {
            com.vortx.android.BuildConfig.NATIVE_ENGINE_ENABLED = true
            val fail = FixtureReceiveManager(); fail.nativeReceived = false
            check(!fail.useAccountData())
            val good = FixtureReceiveManager(); check(good.useAccountData() && good.acks == 0)
        }
        println("OK full source-extracted receive: " + cases + " cases")
    } finally { Dispatchers.resetMain() }
}
`;
await writeFile(join(out, "ComparisonReceive.kt"), fixture);
await writeFile(join(out, "BuildConfig.kt"), "package com.vortx.android\nobject BuildConfig { var NATIVE_ENGINE_ENABLED = true }\n");
const jars = await readdir(kotlin);
const stdlib = jars.find(x => /^kotlin-stdlib-[0-9][^/]*\.jar$/.test(x));
const coroutines = jars.find(x => /^kotlinx-coroutines-core-jvm-.*\.jar$/.test(x));
assert(stdlib && coroutines);
const cp = [join(kotlin, stdlib), join(kotlin, coroutines), join(deps, "kotlinx-coroutines-test-jvm-1.6.4.jar"), join(deps, "json-20240303.jar")].join(":");
function run(args) {
    const result = spawnSync(java, ["-XX:ActiveProcessorCount=1", ...args], { cwd: repo, stdio: "inherit" });
    assert.equal(result.status, 0, "Source-extracted comparison receive check failed");
}
run(["-Xmx512m", "-cp", join(kotlin, "*"), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
    "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-Xbackend-threads=1", "-classpath", cp,
    join(out, "ComparisonReceive.kt"), join(out, "BuildConfig.kt"), "-d", join(out, "classes")]);
run(["-Xmx128m", "-cp", join(out, "classes") + ":" + cp, "com.vortx.android.sync.ComparisonReceiveKt"]);
console.log("Retained generated comparison source and classes:", out);
