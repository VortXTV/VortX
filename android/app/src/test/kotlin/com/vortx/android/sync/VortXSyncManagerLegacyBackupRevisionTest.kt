package com.vortx.android.sync

import android.content.Context
import com.vortx.android.BuildConfig
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Runs only in the explicit legacy configuration, with the actual manager/crypto/roster merge. */
@OptIn(ExperimentalCoroutinesApi::class)
class VortXSyncManagerLegacyBackupRevisionTest {
    private class Fixture {
        val context = RevisionContext()
        val manager = VortXSyncManager(context)
        val key = ByteArray(32) { 42 }
        val account = VortXSyncManager.Account("legacy-revision-fixture", "fixture@example.invalid", "Fixture", false)
        var revision: Long? = 40L
        var cloud = JSONObject().put("baseline", "keep")
        var beforePut: ((Int) -> Unit)? = null
        var rawGet: JSONObject? = null
        var failGet = false
        val attempts = mutableListOf<Long>()
        init {
            check(!BuildConfig.NATIVE_ENGINE_ENABLED)
            val store = ProfileStore::class.java.getDeclaredConstructor(Context::class.java)
                .apply { isAccessible = true }.newInstance(context)
            manager.attachSyncSeams(store)
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, { method, _, body, _ ->
                if (method == "GET") {
                    val version = revision
                    when {
                        failGet -> 500 to null
                        rawGet != null -> 200 to rawGet
                        version == null -> 404 to null
                        else -> 200 to JSONObject().put("version", version).put("document",
                            VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, version, true))
                    }
                } else {
                    val request = requireNotNull(body); val version = request.getLong("version")
                    attempts += version
                    beforePut?.invoke(attempts.size)
                    if (revision == null || version > requireNotNull(revision)) {
                        cloud = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), account.id, version))))
                        revision = version
                        200 to JSONObject().put("accepted", true)
                    } else 200 to JSONObject().put("accepted", false).put("version", revision)
                }
            })
        }
    }

    @Test fun `legacy merged upload also rejects stale peer then preserves fresh winner fields`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.beforePut = { if (it == 1) { fixture.cloud.put("peerA", "must survive"); fixture.revision = 41 } }
            assertTrue(fixture.manager.syncUp())
            assertEquals(listOf(41L, 42L), fixture.attempts)
            assertEquals("must survive", fixture.cloud.getString("peerA"))
            assertEquals("keep", fixture.cloud.getString("baseline"))
            assertEquals(42L, fixture.manager.lastAppliedVersion())
        } finally { fixture.manager.cancelSyncTestWork(); Dispatchers.resetMain() }
    }

    @Test fun `legacy missing row seeds zero and colliding seed must rederive from winner`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.revision = null
            fixture.beforePut = { if (it == 1) { fixture.cloud = JSONObject().put("peerA", "seed winner"); fixture.revision = 0 } }
            assertTrue(fixture.manager.syncUp())
            assertEquals(listOf(0L, 1L), fixture.attempts)
            assertEquals("seed winner", fixture.cloud.getString("peerA"))
            assertEquals(1L, fixture.manager.lastAppliedVersion())
        } finally { fixture.manager.cancelSyncTestWork(); Dispatchers.resetMain() }
    }

    @Test fun `legacy malformed success is not permission to seed or upload`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            val sealed = requireNotNull(VortXCrypto.sealDocument(fixture.key, fixture.cloud.toString().toByteArray(), fixture.account.id, 40, true))
            for (body in listOf(JSONObject(), JSONObject().put("document", JSONObject.NULL).put("version", 0),
                JSONObject().put("document", sealed), JSONObject().put("document", sealed).put("version", "40"),
                JSONObject().put("document", sealed).put("version", 40.5))) {
                fixture.rawGet = body
                assertFalse(fixture.manager.syncUp())
                assertTrue(fixture.attempts.isEmpty())
                assertEquals(0L, fixture.manager.lastAppliedVersion())
            }
        } finally { fixture.manager.cancelSyncTestWork(); Dispatchers.resetMain() }
    }

    @Test fun `legacy failed repull cannot blindly retry a stale derived blob`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.beforePut = { fixture.cloud.put("peerA", "winner"); fixture.revision = 41; fixture.failGet = true }
            assertFalse(fixture.manager.syncUp())
            assertEquals(listOf(41L), fixture.attempts)
            assertEquals(0L, fixture.manager.lastAppliedVersion())
            assertEquals("winner", fixture.cloud.getString("peerA"))
        } finally { fixture.manager.cancelSyncTestWork(); Dispatchers.resetMain() }
    }
}
