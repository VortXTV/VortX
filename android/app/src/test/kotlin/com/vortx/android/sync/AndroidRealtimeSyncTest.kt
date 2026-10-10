package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.profile.UserProfile
import java.lang.reflect.Proxy
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.test.*
import okhttp3.Request
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual manager/channel crypto and scheduling with synthetic local transport/gateway/socket.
 * Does not substitute a second sync algorithm or claim to test the private native join kernel. */
@OptIn(ExperimentalCoroutinesApi::class)
class AndroidRealtimeSyncTest {
    private val key = ByteArray(32) { 17 }
    private val account = VortXSyncManager.Account("00000000-0000-0000-0000-000000000123", "fixture@example.invalid", "Fixture", false)
    private val scopeId = "account.${account.id}"
    private fun native(facts: JSONObject = JSONObject()) = JSONObject().put("schemaVersion", 1)
        .put("scope", scopeId).put("ownerProfileId", UserProfile.OWNER_ID).put("facts", facts)
    private fun document(carrier: JSONObject = native()) = JSONObject().put("foreign", "preserved").put("nativeSync", carrier)

    private inner class Gateway : NativeAccountGateway {
        var carrier = native()
        var applied = 0
        var reopenFails = false
        var applyFails = false
        var ackFails = false
        var exportFails = false
        var host: JSONObject? = null
        var applyGate: CompletableDeferred<Unit>? = null
        var applyEntered: CompletableDeferred<Unit>? = null
        override fun retire() {}
        override suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): Boolean {
            check(isCurrent()); if (reopenFails) error("checkpoint unavailable"); return true
        }
        override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean {
            applied++; applyEntered?.complete(Unit); applyGate?.await()
            if (!isCurrent() || applyFails) return false
            document.optJSONObject("nativeSync")?.let { incoming ->
                // Synthetic collaborator retains local facts; tests exercise manager admission/ACK,
                // not the implementation of the native causal join itself.
                val merged = JSONObject(incoming.toString())
                val facts = merged.optJSONObject("facts") ?: JSONObject().also { merged.put("facts", it) }
                carrier.optJSONObject("facts")?.let { local -> local.keys().forEach { facts.put(it, local.get(it)) } }
                carrier = merged
            }
            return true
        }
        override fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport? = if (exportFails) null else NativeAccountExport(
            JSONObject(carrier.toString()), listOf(UserProfile(id = UserProfile.OWNER_ID, name = "Fixture", avatar = "star", isOwner = true)),
            0.0, hostPreferences = host)
        override fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean = !ackFails
        override suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean) = document()
    }

    private inner class Fixture(scheduler: TestCoroutineScheduler, val context: MemoryContext = MemoryContext()) {
        val work = CoroutineScope(SupervisorJob() + StandardTestDispatcher(scheduler))
        val manager = VortXSyncManager(context, work)
        val gateway = Gateway()
        val providers = NativeProviderTestStore()
        var cloud = document()
        var version = 10L
        var gets = 0
        var puts = 0
        var putFails = false
        var getFails = false
        var beforePut: (() -> Unit)? = null
        var getGate: CompletableDeferred<Unit>? = null
        val tokens = mutableListOf<String?>()
        val sockets = mutableListOf<Socket>()
        val realtime = VortXSyncRealtime(manager, work, "wss://fixture.invalid/v1/sync/connect") { request, listener ->
            Socket(request, listener).also(sockets::add)
        }
        init {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-a", account, key), 10, transport = { method, _, body, token ->
                tokens += token
                if (method == "GET") {
                    gets++; getGate?.await()
                    if (getFails) 500 to null else 200 to JSONObject().put("version", version).put("document",
                        VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, version, true))
                } else {
                    puts++; beforePut?.invoke()
                    if (putFails) 500 to null else {
                        val sent = requireNotNull(body)
                        version = sent.getLong("version")
                        cloud = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, sent.getString("document"), account.id, version))))
                        200 to JSONObject().put("accepted", true)
                    }
                }
            })
            manager.installSessionRestoreTestSeam(manager.currentSession())
            manager.installNativeGatewayTestSeam(gateway, providers)
            manager.installRealtimeTestSeam(realtime)
        }
        fun edit(name: String) {
            gateway.carrier.getJSONObject("facts").put(name, true)
            manager.onLocalNativeMutation(SessionOwnerSnapshot.Account(account.id, 1))
        }
        fun dirty() = context.getSharedPreferences("vortx_sync_state", 0).getBoolean("pendingPush.${account.id}", false)
        suspend fun close() { realtime.stop(); manager.cancelSyncTestWork(); NativeProviderAccess.unbindForTest() }
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        try { block() } finally { NativeProviderAccess.unbindForTest(); Dispatchers.resetMain() }
    }

    @Test fun `continuous progress does not postpone upload and PUT edit survives exact ACK`() = test {
        val f = Fixture(testScheduler)
        try {
            f.edit("first"); runCurrent()
            advanceTimeBy(1_000); f.edit("second"); runCurrent()
            advanceTimeBy(1_000); f.edit("third"); runCurrent()
            f.beforePut = { f.beforePut = null; f.edit("during-put") }
            advanceTimeBy(501); runCurrent()
            assertEquals(1, f.puts)
            assertFalse(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").has("during-put"))
            assertTrue(f.dirty())
            advanceTimeBy(2_500); runCurrent()
            assertEquals(2, f.puts)
            assertTrue(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("during-put"))
            assertFalse(f.dirty())
            assertEquals("preserved", f.cloud.getString("foreign"))
        } finally { f.close() }
    }

    @Test fun `failed upload retains durable pending intent and cold restart retries`() = test {
        val context = MemoryContext()
        val first = Fixture(testScheduler, context)
        first.putFails = true; first.edit("persisted")
        runCurrent(); advanceTimeBy(2_501); runCurrent()
        assertEquals(1, first.puts); assertTrue(first.dirty()); first.close()
        val second = Fixture(testScheduler, context)
        try {
            second.gateway.carrier = native(JSONObject().put("persisted", true))
            assertFalse(second.manager.syncDown()) // restored dirty marker defers pull
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, second.puts); assertFalse(second.dirty())
            assertTrue(second.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("persisted"))
        } finally { second.close() }
    }

    @Test fun `failed native apply and failed host receipt do not advance revision`() = test {
        val f = Fixture(testScheduler)
        try {
            f.version = 11; f.gateway.applyFails = true
            assertFalse(f.manager.syncDown()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.gateway.applyFails = false; f.gateway.host = JSONObject().put("globals", JSONObject().put("fields", JSONObject()))
            f.context.rejectCommitKey = "vortx_settings:"
            assertFalse(f.manager.syncDown()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.context.rejectCommitKey = null
            assertTrue(f.manager.syncDown()); assertEquals(11L, f.manager.lastAppliedVersion())
        } finally { f.close() }
    }

    @Test fun `accepted PUT cannot stamp until host provider and durable revision receipts succeed`() = test {
        val f = Fixture(testScheduler)
        try {
            f.gateway.host = JSONObject().put("globals", JSONObject().put("fields", JSONObject()))
            f.gateway.ackFails = true
            assertFalse(f.manager.syncUp()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.gateway.ackFails = false
            f.beforePut = { f.beforePut = null; f.providers.failWrite = true }
            assertFalse(f.manager.syncUp()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.providers.failWrite = false
            f.context.rejectCommitKey = "vortx_sync_state:lastSyncedVersion."
            assertFalse(f.manager.syncUp()); assertEquals(10L, f.manager.lastAppliedVersion())
            f.context.rejectCommitKey = null
            assertTrue(f.manager.syncUp()); assertEquals(f.version, f.manager.lastAppliedVersion())
        } finally { f.close() }
    }

    @Test fun `accepted create-only backup with failed local apply remains unacknowledged`() = test {
        val f = Fixture(testScheduler)
        try {
            f.context.getSharedPreferences("vortx_sync_state", 0).edit().remove("lastSyncedVersion.${account.id}").commit()
            f.getFails = false
            // GET 404 without prior-backup evidence is the only path allowed to seed.
            f.manager.installSyncTestSeam(VortXSyncManager.Session("fixture-a", account, key), 0, transport = { method, _, _, _ ->
                if (method == "GET") 404 to null else 200 to JSONObject().put("accepted", true)
            })
            f.context.getSharedPreferences("vortx_sync_state", 0).edit().remove("lastSyncedVersion.${account.id}").commit()
            f.gateway.applyFails = true
            assertFalse(f.manager.syncUp())
            assertFalse(f.context.getSharedPreferences("vortx_sync_state", 0).contains("lastSyncedVersion.${account.id}"))
        } finally { f.close() }
    }

    @Test fun `equal acknowledged carrier neither joins remounts nor repushes`() = test {
        val f = Fixture(testScheduler)
        try {
            repeat(4) { assertTrue(f.manager.syncDown()) }
            assertEquals(0, f.gateway.applied); assertFalse(f.dirty())
            runCurrent(); advanceTimeBy(10_000); runCurrent(); assertEquals(0, f.puts)
        } finally { f.close() }
    }

    @Test fun `version zero without durable acknowledgement still applies recovered checkpoint`() = test {
        val f = Fixture(testScheduler)
        try {
            f.version = 0
            f.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("peer", true)
            f.context.getSharedPreferences("vortx_sync_state", 0).edit().remove("lastSyncedVersion.${account.id}").commit()
            assertTrue(f.manager.syncDown()); assertEquals(1, f.gateway.applied)
            assertTrue(f.gateway.carrier.getJSONObject("facts").getBoolean("peer"))
        } finally { f.close() }
    }

    @Test fun `checkpoint-only local fact heals equal cloud once without echo loop`() = test {
        val f = Fixture(testScheduler)
        try {
            f.gateway.carrier.getJSONObject("facts").put("checkpoint-only", true)
            assertTrue(f.manager.syncDown()); assertTrue(f.dirty()); assertEquals(0, f.gateway.applied)
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, f.puts); assertFalse(f.dirty())
            repeat(3) { assertTrue(f.manager.syncDown()) }
            advanceTimeBy(10_000); runCurrent(); assertEquals(1, f.puts)
        } finally { f.close() }
    }

    @Test fun `legacy rollback higher envelope heals causal fact without replacing foreign fields`() = test {
        val f = Fixture(testScheduler)
        try {
            f.gateway.carrier.getJSONObject("facts").put("new-local", true)
            f.version = 1_760_000_000_000L
            assertTrue(f.manager.syncDown()); assertTrue(f.dirty())
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1_760_000_000_001L, f.version)
            assertTrue(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("new-local"))
            assertEquals("preserved", f.cloud.getString("foreign")); assertFalse(f.dirty())
        } finally { f.close() }
    }

    @Test fun `legacy-only cloud recovers checkpoint edit before lost callback without equal join loop`() = test {
        val f = Fixture(testScheduler)
        try {
            f.cloud.remove("nativeSync")
            f.gateway.carrier.put("legacyImport", JSONObject().put("receipt", true))
            f.gateway.carrier.getJSONObject("facts").put("checkpoint-before-callback", true)
            assertTrue(f.manager.syncDown()); assertTrue(f.dirty()); assertEquals(0, f.gateway.applied)
            runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, f.puts); assertFalse(f.dirty())
            assertTrue(f.cloud.getJSONObject("nativeSync").getJSONObject("facts").getBoolean("checkpoint-before-callback"))
            repeat(3) { assertTrue(f.manager.syncDown()) }
            advanceTimeBy(10_000); runCurrent(); assertEquals(1, f.puts)
        } finally { f.close() }
    }

    @Test fun `verified legacy-only baseline heals but missing or mismatched carrier authority cannot`() = test {
        val joined = NativeAccountExport(native().put("legacyImport", JSONObject().put("receipt", true)), emptyList(), 0.0)
        assertTrue(NativeSyncPublicationPolicy.needsRepublish(JSONObject().put("foreign", "keep"), joined))
        assertFalse(NativeSyncPublicationPolicy.needsRepublish(JSONObject(), joined.copy(nativeSync = native())))
        assertFalse(NativeSyncPublicationPolicy.needsRepublish(document(native().put("scope", "account.other")), joined))
        assertFalse(NativeSyncPublicationPolicy.needsRepublish(JSONObject().put("nativeSync", "malformed"), joined))
        val equal = JSONObject("""{"a":1.0,"b":[{"x":2}]}""")
        assertTrue(NativeSyncPublicationPolicy.same(equal, JSONObject("""{"b":[{"x":2.0}],"a":1}""")))
    }

    @Test fun `origin mutation cannot arm different account or same-account new epoch`() = test {
        val f = Fixture(testScheduler)
        try {
            val origin = SessionOwnerSnapshot.Account(account.id, 1)
            val b = account.copy(id = "00000000-0000-0000-0000-000000000999")
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-b", b, key))
            f.manager.onLocalNativeMutation(origin)
            assertFalse(f.context.getSharedPreferences("vortx_sync_state", 0).getBoolean("pendingPush.${b.id}", false))
            f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session("fixture-a", account, key), 2)
            // Production restore reconciles persisted epoch after unavailable storage; exercise
            // the same durable-session transition without signing into any account.
            f.manager.installUnavailableSessionRestoreTestSeam(); f.manager.sessionOwnerSnapshot()
            f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session("fixture-a", account, key), 2)
            f.manager.sessionOwnerSnapshot(); f.manager.onLocalNativeMutation(origin)
            assertFalse(f.dirty())
        } finally { f.close() }
    }

    @Test fun `queued realtime work and old socket cannot adopt A B A replacement`() = test {
        val f = Fixture(testScheduler)
        try {
            f.realtime.start(); val old = f.sockets.single()
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-b", account.copy(id = "00000000-0000-0000-0000-000000000999"), key))
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-a", account, key))
            old.updated(11); runCurrent(); assertEquals(0, f.gets)
            f.realtime.start(); assertEquals(2, f.sockets.size); runCurrent(); assertEquals(1, f.gets)
            old.updated(12); runCurrent(); assertEquals(1, f.gets)
            assertEquals(listOf("fixture-a"), f.tokens)
        } finally { f.close() }
    }

    @Test fun `notification burst is conflated with at most one in-flight and one followup`() = test {
        val f = Fixture(testScheduler)
        try {
            f.getGate = CompletableDeferred(); f.realtime.start(); runCurrent(); assertEquals(1, f.gets)
            repeat(100) { f.sockets.single().updated(11) }
            runCurrent(); assertEquals(1, f.gets)
            f.getGate!!.complete(Unit); f.getGate = null; runCurrent(); assertEquals(2, f.gets)
            f.sockets.single().updated(10); f.sockets.single().message("{\"type\":\"updated\",\"version\":10.5}")
            runCurrent(); assertEquals(2, f.gets)
        } finally { f.close() }
    }

    @Test fun `active fallback catches missed broadcast at three seconds and stops on background`() = test {
        val f = Fixture(testScheduler)
        try {
            f.manager.setRealtimeForeground(true); runCurrent(); assertEquals(1, f.gets)
            f.version = 11; f.cloud.getJSONObject("nativeSync").getJSONObject("facts").put("peer", true)
            advanceTimeBy(3_001); runCurrent(); assertEquals(2, f.gets); assertEquals(11L, f.manager.lastAppliedVersion())
            f.manager.setRealtimeForeground(false); f.manager.startRealtime() // delayed auth completion
            advanceTimeBy(30_000); runCurrent(); assertEquals(2, f.gets); assertFalse(f.realtime.isActive())
            assertEquals(1, f.sockets.size)
        } finally { f.close() }
    }

    @Test fun `reconnect uses captured bearer catches up and revoked reconnect stays closed`() = test {
        val f = Fixture(testScheduler)
        try {
            f.realtime.start(); runCurrent(); f.sockets.single().fail()
            advanceTimeBy(1_001); runCurrent(); assertEquals(2, f.sockets.size); assertEquals(2, f.gets)
            assertEquals("Bearer fixture-a", f.sockets.last().request().header("authorization"))
            f.sockets.last().fail(); f.realtime.stop()
            advanceTimeBy(30_000); runCurrent(); assertEquals(2, f.sockets.size); assertEquals(2, f.gets)
        } finally { f.close() }
    }

    @Test fun `stop cancels queued and in-flight pull without applying or stamping`() = test {
        val f = Fixture(testScheduler)
        try {
            f.getGate = CompletableDeferred(); f.version = 11
            f.realtime.start(); runCurrent(); assertEquals(1, f.gets)
            f.realtime.stop(); f.getGate!!.complete(Unit); runCurrent()
            assertEquals(0, f.gateway.applied); assertEquals(10L, f.manager.lastAppliedVersion())
        } finally { f.close() }
    }

    @Test fun `delayed native apply rejects same account generation replacement and failed reopen is retryable`() = test {
        val f = Fixture(testScheduler)
        try {
            f.version = 11; f.gateway.reopenFails = true
            assertFalse(f.manager.syncDown()); assertEquals(0, f.gets)
            f.gateway.reopenFails = false; f.gateway.applyEntered = CompletableDeferred(); f.gateway.applyGate = CompletableDeferred()
            val applying = async { f.manager.syncDown() }; runCurrent(); f.gateway.applyEntered!!.await()
            f.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("fixture-a", account, key))
            f.gateway.applyGate!!.complete(Unit); assertFalse(applying.await()); assertEquals(10L, f.manager.lastAppliedVersion())
        } finally { f.close() }
    }

    private class Socket(private val openingRequest: Request, val listener: WebSocketListener) : WebSocket {
        var cancelled = false
        override fun request() = openingRequest
        override fun queueSize() = 0L
        override fun send(text: String) = !cancelled
        override fun send(bytes: ByteString) = !cancelled
        override fun close(code: Int, reason: String?): Boolean { cancelled = true; return true }
        override fun cancel() { cancelled = true }
        fun message(value: String) = listener.onMessage(this, value)
        fun updated(version: Long) = message(JSONObject().put("type", "updated").put("version", version).toString())
        fun fail() = listener.onFailure(this, IllegalStateException("fixture-only disconnect"), null)
    }

    private class MemoryContext : ContextWrapper(null) {
        private val stores = mutableMapOf<String, SharedPreferences>()
        var rejectCommitKey: String? = null
        override fun getApplicationContext(): Context = this
        override fun getPackageName() = "com.vortx.android.sync.fixture"
        override fun getSharedPreferences(name: String, mode: Int) = stores.getOrPut(name) {
            val values = linkedMapOf<String, Any?>()
            fun editor(): SharedPreferences.Editor {
                val edits = linkedMapOf<String, Any?>(); var clear = false
                return Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
                    when (method.name) {
                        "clear" -> { clear = true; proxy }
                        "remove" -> { edits[args!![0] as String] = null; proxy }
                        "commit", "apply" -> {
                            val rejected = method.name == "commit" && rejectCommitKey?.let { prefix ->
                                prefix == "$name:" || edits.keys.any { "$name:$it".startsWith(prefix) }
                            } == true
                            if (!rejected) { if (clear) values.clear(); edits.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value } }
                            if (method.name == "commit") !rejected else null
                        }
                        else -> if (method.name.startsWith("put")) { edits[args!![0] as String] = args[1]; proxy } else null
                    }
                } as SharedPreferences.Editor
            }
            Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
                when (method.name) {
                    "getAll" -> values.toMap()
                    "contains" -> values.containsKey(args!![0])
                    "edit" -> editor()
                    "registerOnSharedPreferenceChangeListener", "unregisterOnSharedPreferenceChangeListener" -> null
                    else -> if (method.name.startsWith("get")) values[args!![0]] ?: args[1] else null
                }
            } as SharedPreferences
        }
    }
}
