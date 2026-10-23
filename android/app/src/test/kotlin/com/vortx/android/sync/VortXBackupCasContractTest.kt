package com.vortx.android.sync

import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.integrations.NativeProviderCredentials
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual manager, authenticated crypto, candidate fences and receipts; synthetic mounted gateway.
 * This verifies host transport contracts without claiming execution of the private JNI engine. */
@OptIn(ExperimentalCoroutinesApi::class)
class VortXBackupCasContractTest {
    private class Gateway : NativeAccountGateway {
        var installation: Any? = Any()
        var acknowledgments = 0
        var document = JSONObject()
        var hostPreferences = JSONObject().put("globals", JSONObject().put("fields", JSONObject()))
        var beforePrepare: (() -> Unit)? = null
        override fun retire() { installation = Any() }
        override fun currentMountToken(account: SessionOwnerSnapshot.Account) = installation?.let { NativeAccountMountToken(it, 0) }
        override suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean) = isCurrent()
        override suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): JSONObject? {
            beforePrepare?.invoke()
            return JSONObject().put("nativeSync", JSONObject().put("scope", "account.${account.id}").put("fixture", true))
                .takeIf { isCurrent() }
        }
        override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean {
            if (!isCurrent()) return false
            if (installation == null) installation = Any()
            this.document = JSONObject(document.toString()); return true
        }
        override fun exportDocument(account: SessionOwnerSnapshot.Account) = NativeAccountExport(
            document.optJSONObject("nativeSync") ?: JSONObject().put("scope", "account.${account.id}").put("fixture", true),
            listOf(UserProfile(id = UserProfile.OWNER_ID, name = "Fixture", avatar = "star", isOwner = true)), 0.0,
            hostPreferences = hostPreferences)
        override fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean {
            acknowledgments++; return true
        }
    }

    private class Fixture {
        val key = ByteArray(32) { 25 }
        val account = VortXSyncManager.Account("00000000-0000-0000-0000-000000000123", "fixture@example.invalid", "Fixture", false)
        val dispatcher = UnconfinedTestDispatcher()
        val context = RevisionContext()
        val manager = VortXSyncManager(context, CoroutineScope(SupervisorJob() + dispatcher))
        val gateway = Gateway()
        val providers = NativeProviderTestStore()
        var revision: Long? = 40L
        var cloud = JSONObject().put("foreign", JSONObject().put("keep", true))
            .put("nativeSync", JSONObject().put("scope", "account.${account.id}").put("fixture", true))
        val bases = mutableListOf<Long?>()
        val versions = mutableListOf<Long>()
        var puts = 0
        var gets = 0
        var beforePut: (suspend (Int) -> Unit)? = null
        var failPut: Pair<Int, JSONObject?>? = null
        var loseAcceptedResponse = false
        init {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, body, _ ->
                if (method == "GET") {
                    gets++
                    revision?.let { version -> 200 to JSONObject().put("version", version).put("document",
                        VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, version, true)) } ?: (404 to null)
                } else {
                    val request = requireNotNull(body)
                    check(request.has("baseRevision"))
                    val base = if (request.isNull("baseRevision")) null else request.getLong("baseRevision")
                    val version = request.getLong("version")
                    bases += base; versions += version; puts++
                    beforePut?.invoke(puts)
                    failPut ?: if (base == revision && version == BackupRevisionPolicy.next(base)) {
                        cloud = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key,
                            request.getString("document"), account.id, version))))
                        revision = version
                        if (loseAcceptedResponse) { loseAcceptedResponse = false; 0 to null }
                        else 200 to JSONObject().put("accepted", true)
                    } else 200 to JSONObject().put("accepted", false).put("version", revision ?: JSONObject.NULL)
                }
            })
            manager.installSessionRestoreTestSeam(manager.currentSession())
            manager.installNativeGatewayTestSeam(gateway, providers)
        }
        suspend fun close() { manager.cancelSyncTestWork(); NativeProviderAccess.unbindForTest() }
    }

    @Test fun `native create and concurrent absent race retain exact existence witness`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.revision = null
            fixture.gateway.installation = null
            fixture.beforePut = { if (it == 1) { fixture.revision = 0; fixture.cloud.put("seedWinner", "keep") } }
            assertTrue(fixture.manager.syncUp())
            assertEquals(listOf(null, 0L), fixture.bases); assertEquals(listOf(0L, 1L), fixture.versions)
            assertEquals("keep", fixture.cloud.getString("seedWinner"))
            assertEquals(1, fixture.gateway.acknowledgments)
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `native successful create is version zero and cannot omit null witness`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.revision = null
            fixture.gateway.installation = null
            assertTrue(fixture.manager.syncUp())
            assertEquals(listOf<Long?>(null), fixture.bases); assertEquals(listOf(0L), fixture.versions)
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `same bearer later GET cannot bless earlier candidate while PUT waits`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            val suspended = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            fixture.beforePut = { if (it == 1) { suspended.complete(Unit); release.await() } }
            val pending = async { fixture.manager.syncUp() }
            suspended.await()
            fixture.cloud.put("interveningWinner", "keep"); fixture.revision = 41
            assertNotEquals(VortXSyncManager.AccountDataProbe.UNREACHABLE, fixture.manager.accountHasSyncData())
            release.complete(Unit)
            assertTrue(pending.await())
            assertEquals(listOf(40L, 41L), fixture.bases); assertEquals(listOf(41L, 42L), fixture.versions)
            assertEquals("keep", fixture.cloud.getString("interveningWinner"))
            assertEquals(1, fixture.gateway.acknowledgments)
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `native lost accepted response never ACKs and fresh retry preserves newer fields`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.loseAcceptedResponse = true
            assertFalse(fixture.manager.syncUp()); assertEquals(0, fixture.gateway.acknowledgments)
            assertEquals(0L, fixture.manager.lastAppliedVersion())
            fixture.cloud.put("afterLostResponse", "keep"); fixture.revision = 42
            assertTrue(fixture.manager.syncUp())
            assertEquals(listOf(40L, 42L), fixture.bases); assertEquals(listOf(41L, 43L), fixture.versions)
            assertEquals("keep", fixture.cloud.getString("afterLostResponse"))
            assertEquals(1, fixture.gateway.acknowledgments)
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `native upgrade required retains durable pending and stops automatic retry loop`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.failPut = 426 to JSONObject().put("error", "upgrade_required").put("accepted", false)
            fixture.manager.requestSyncSoon()
            fixture.dispatcher.scheduler.advanceTimeBy(2_501); fixture.dispatcher.scheduler.runCurrent()
            assertEquals(1, fixture.puts); assertEquals(0, fixture.gateway.acknowledgments)
            assertEquals(0L, fixture.manager.lastAppliedVersion())
            assertEquals("Update VortX to keep syncing. Your changes are still on this device.", fixture.manager.syncProblem.value)
            assertTrue(fixture.context.getSharedPreferences("vortx_sync_state", android.content.Context.MODE_PRIVATE)
                .getBoolean("pendingPush.${fixture.account.id}", false))
            fixture.dispatcher.scheduler.advanceTimeBy(600_000); fixture.dispatcher.scheduler.runCurrent()
            fixture.manager.requestSyncSoon(); fixture.dispatcher.scheduler.advanceTimeBy(600_000)
            assertEquals(1, fixture.puts)
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `native reauthentication and remount cannot ACK an accepted retired candidate`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        for (reauthenticate in listOf(true, false)) {
            val fixture = Fixture()
            try {
                fixture.beforePut = { if (reauthenticate) fixture.manager.replaceSyncSessionTestSeam(
                    VortXSyncManager.Session("replacement-token", fixture.account, fixture.key)) else fixture.gateway.retire() }
                assertFalse(fixture.manager.syncUp()); assertEquals(0, fixture.gateway.acknowledgments)
                assertEquals(0L, fixture.manager.lastAppliedVersion())
            } finally { fixture.close() }
        }
        Dispatchers.resetMain()
    }

    @Test fun `unmounted seed cannot ACK after an installation appears during PUT`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.revision = null; fixture.gateway.installation = null
            fixture.beforePut = { fixture.gateway.installation = Any() }
            assertFalse(fixture.manager.syncUp())
            assertEquals(listOf<Long?>(null), fixture.bases); assertEquals(listOf(0L), fixture.versions)
            assertEquals(0, fixture.gateway.acknowledgments); assertEquals(0L, fixture.manager.lastAppliedVersion())
            assertEquals(0, fixture.gateway.document.length())
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `seed prepared by retired gateway cannot borrow replacement gateway witness`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.revision = null; fixture.gateway.installation = null
            fixture.gateway.beforePrepare = {
                fixture.manager.installNativeGatewayTestSeam(Gateway(), fixture.providers)
            }
            assertFalse(fixture.manager.syncUp())
            assertEquals(0, fixture.puts); assertEquals(0, fixture.gateway.acknowledgments)
            assertEquals(0L, fixture.manager.lastAppliedVersion()); assertNull(fixture.revision)
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `seed preparation cannot borrow installation mounted after capture`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.revision = null; fixture.gateway.installation = null
            fixture.gateway.beforePrepare = { fixture.gateway.installation = Any() }
            assertFalse(fixture.manager.syncUp())
            assertEquals(0, fixture.puts); assertEquals(0, fixture.gateway.acknowledgments)
            assertEquals(0L, fixture.manager.lastAppliedVersion()); assertNull(fixture.revision)
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `post PUT host application remount cannot ACK or success stamp`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.gateway.hostPreferences.getJSONObject("globals").getJSONObject("fields")
                .put("stremiox.autoSkip", JSONObject().put("value", true))
            val preferences = fixture.context.getSharedPreferences("vortx_settings", android.content.Context.MODE_PRIVATE)
            var remounted = false
            val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, field ->
                if (field == "stremiox.autoSkip") { remounted = true; fixture.gateway.retire() }
            }
            preferences.registerOnSharedPreferenceChangeListener(listener)
            assertFalse(fixture.manager.syncUp())
            assertTrue(remounted); assertEquals(41L, fixture.revision)
            assertEquals(0, fixture.gateway.acknowledgments); assertEquals(0L, fixture.manager.lastAppliedVersion())
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `same account different data key cannot ACK delayed accepted response`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.beforePut = { fixture.manager.replaceSyncSessionTestSeam(
                VortXSyncManager.Session("fixture-only", fixture.account, ByteArray(32) { 26 })) }
            assertFalse(fixture.manager.syncUp())
            assertEquals(41L, fixture.revision); assertEquals(0, fixture.gateway.acknowledgments)
            assertEquals(0L, fixture.manager.lastAppliedVersion())
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `bodyless upgrade status is terminal without any ACK or repeated PUT`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.failPut = 426 to null
            assertFalse(fixture.manager.syncUp())
            assertEquals("Update VortX to keep syncing. Your changes are still on this device.", fixture.manager.syncProblem.value)
            assertFalse(fixture.manager.syncUp())
            assertEquals(1, fixture.puts); assertEquals(0, fixture.gateway.acknowledgments)
            assertEquals(0L, fixture.manager.lastAppliedVersion())
        } finally { fixture.close(); Dispatchers.resetMain() }
    }

    @Test fun `ACKed provider-only stale rollback schedules durable repair visible to cold reader`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            val principal = SessionOwnerSnapshot.Account(fixture.account.id, 1)
            val credential = NativeProviderCredentials("account.${fixture.account.id}")
            credential.edit(mapOf("tmdb" to "synthetic-older"))
            val older = credential.mirror(JSONObject())
            credential.edit(mapOf("tmdb" to "synthetic-newer")); credential.acknowledge(credential.document())
            fixture.providers.values["native.providers.account.${fixture.account.id}"] = credential.encoded()
            fixture.cloud.put("nativeHostPreferences", fixture.gateway.exportDocument(principal).hostPreferences)
                .put("nativeProviderCredentials", older.getJSONObject("nativeProviderCredentials"))
                .put("apiKeys", older.getJSONObject("apiKeys"))
            assertFalse(NativeSyncPublicationPolicy.needsRepublish(fixture.cloud, fixture.gateway.exportDocument(principal)))
            assertTrue(fixture.manager.syncDown(true))
            assertFalse(requireNotNull(NativeProviderAccess.hasPending(principal)))
            assertTrue(fixture.context.getSharedPreferences("vortx_sync_state", android.content.Context.MODE_PRIVATE)
                .getBoolean("pendingPush.${fixture.account.id}", false))
            fixture.dispatcher.scheduler.advanceTimeBy(2_501); fixture.dispatcher.scheduler.runCurrent()
            assertEquals(listOf(40L), fixture.bases); assertEquals(listOf(41L), fixture.versions)
            assertEquals("synthetic-newer", fixture.cloud.getJSONObject("apiKeys").getString("tmdb"))
            val cold = NativeProviderCredentials("account.${fixture.account.id}"); cold.merge(fixture.cloud)
            assertEquals("synthetic-newer", cold.value("tmdb"))
            assertFalse(NativeSyncPublicationPolicy.needsProviderRepublish(fixture.cloud, cold.mirror(fixture.cloud)))
        } finally { fixture.close(); Dispatchers.resetMain() }
    }
}
