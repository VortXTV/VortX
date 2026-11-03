package com.vortx.android.integrations

import com.vortx.android.engine.AccountFileLocalPresence
import com.vortx.android.security.AccountFileProviderWriters
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.sync.SessionOwnerSnapshot
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

internal class NativeProviderTestStore : CredentialStoreAccess {
    val values = linkedMapOf<String, String?>()
    var failWrite = false
    var unavailable = false
    override fun string(key: String) = values[key]
    override fun confirmedSnapshot(vararg keys: String) = PersistentCredentialSnapshot(
        if (unavailable) PersistentCredentialAvailability.UNAVAILABLE else PersistentCredentialAvailability.AVAILABLE,
        if (unavailable) emptyMap() else keys.associateWith(values::get))
    override fun inspectExisting(key: String, isInert: (String) -> Boolean): AccountFileLocalPresence =
        if (unavailable) AccountFileLocalPresence.UNAVAILABLE
        else if (values[key]?.let { !isInert(it) } == true) AccountFileLocalPresence.PRESENT
        else AccountFileLocalPresence.ABSENT
    override fun set(key: String, value: String?) = set(mapOf(key to value))
    override fun set(values: Map<String, String?>): Boolean {
        if (failWrite || unavailable) return false
        this.values.putAll(values); return true
    }
    override fun clear(vararg keys: String) = set(keys.associateWith { null })
}

class NativeProviderCredentialsTest {
    private val id = "00000000-0000-0000-0000-000000000123"
    private val scope = "account.$id"
    private val actor = "aaaaaaaa-0000-0000-0000-000000000000"
    @After fun clean() { NativeProviderAccess.unbindForTest() }
    private fun wire(values: Map<String, String?>, clock: Long = 10) = JSONObject().put("schemaVersion", 1).put("scope", scope)
        .put("fields", JSONObject().also { fields -> values.forEach { (key, value) ->
            fields.put(key, JSONObject().put("clock", clock).put("actor", actor).put("value", value ?: JSONObject.NULL))
        } })
    private fun tuple(value: String?) = mapOf("traktAccess" to value, "traktRefresh" to value?.let { "$it-refresh" }, "traktExpiry" to value?.let { "2000000000" })

    @Test fun `wire mirrors both metadata aliases preserves unknown and clears explicitly`() {
        val helper = NativeProviderCredentials(scope)
        helper.edit(mapOf("tmdb" to "fixture", "realDebrid" to "fixture-debrid"))
        val original = JSONObject("""{"apiKeys":{"unknown":"keep","metadata":{"future":"keep"}}} """)
        val positive = helper.mirror(original)
        assertEquals("fixture", positive.getJSONObject("apiKeys").getString("tmdb"))
        assertEquals("fixture", positive.getJSONObject("apiKeys").getJSONObject("metadata").getString("tmdb"))
        helper.edit(mapOf("tmdb" to null, "realDebrid" to null))
        val cleared = helper.mirror(positive).getJSONObject("apiKeys")
        assertFalse(cleared.has("tmdb")); assertFalse(cleared.has("realDebrid"))
        assertFalse(cleared.getJSONObject("metadata").has("tmdb"))
        assertEquals("keep", cleared.getString("unknown")); assertEquals("keep", cleared.getJSONObject("metadata").getString("future"))
        assertTrue(NativeProviderCredentials(scope, helper.encoded()).hasPending())
    }

    @Test fun `legacy fallback is not register authority and cannot revive a native clear`() {
        val helper = NativeProviderCredentials(scope)
        val legacy = JSONObject("""{"apiKeys":{"tmdb":"old","metadata":{"tmdb":"old"}}}""")
        helper.merge(legacy)
        assertEquals("old", helper.value("tmdb")); assertEquals(0, helper.document().getJSONObject("fields").length())
        helper.edit(mapOf("tmdb" to null)); helper.merge(legacy)
        assertNull(helper.value("tmdb"))
        val before = helper.encoded()
        assertThrows(IllegalArgumentException::class.java) { helper.merge(JSONObject("""{"apiKeys":{"tmdb":"a","metadata":{"tmdb":"b"}}}""")) }
        assertEquals(before, helper.encoded())
    }

    @Test fun `OAuth tuples require complete same-event same-clear-state and canonical expiry`() {
        val helper = NativeProviderCredentials(scope)
        helper.mergeWire(wire(mapOf("tmdb" to "integral-json")).also { it.getJSONObject("fields").getJSONObject("tmdb").put("clock", 1.0) })
        helper.mergeWire(wire(tuple("fixture")))
        val before = helper.encoded()
        val malformed = listOf(
            wire(mapOf("traktAccess" to "partial")),
            wire(tuple("fixture")).also { it.getJSONObject("fields").getJSONObject("traktRefresh").put("clock", 11) },
            wire(tuple("fixture")).also { it.getJSONObject("fields").getJSONObject("traktAccess").put("value", JSONObject.NULL) },
            wire(tuple("fixture")).also { it.getJSONObject("fields").getJSONObject("traktExpiry").put("value", "01") },
            wire(mapOf("tmdb" to "fixture")).also { it.getJSONObject("fields").getJSONObject("tmdb").put("clock", 1.5) },
            wire(mapOf("tmdb" to "fixture")).put("scope", "account.00000000-0000-0000-0000-000000000999"),
            wire(mapOf("unknown" to "fixture")),
        )
        malformed.forEach { assertThrows(Exception::class.java) { helper.mergeWire(it) }; assertEquals(before, helper.encoded()) }
        helper.mergeWire(wire(tuple(null), 11)); assertNull(helper.value("traktAccess"))
        assertThrows(IllegalArgumentException::class.java) { helper.edit(mapOf("traktAccess" to null)) }
    }

    @Test fun `exact event ack never clears newer local edit and equal event equivocation fails`() {
        val helper = NativeProviderCredentials(scope)
        helper.edit(mapOf("tmdb" to "first")); val sent = helper.document()
        helper.edit(mapOf("tmdb" to null)); helper.acknowledge(sent)
        assertTrue(helper.hasPending()); assertNull(helper.value("tmdb"))
        val clear = helper.document(); helper.acknowledge(clear); assertFalse(helper.hasPending())
        val wrong = JSONObject(clear.toString()).also { it.getJSONObject("fields").getJSONObject("tmdb").put("value", "resurrect") }
        assertThrows(IllegalArgumentException::class.java) { helper.mergeWire(wrong) }
        helper.mergeWire(wire(mapOf("tmdb" to "remote"), NativeProviderCredentials.MAX_CLOCK))
        assertThrows(IllegalArgumentException::class.java) { helper.edit(mapOf("tmdb" to "overflow")) }
    }

    private class Owner(var current: SessionOwnerSnapshot.Account?) : NativeProviderAdmission {
        val lock = Any()
        override fun <T> withCurrent(expected: SessionOwnerSnapshot.Account?, action: (SessionOwnerSnapshot.Account) -> T): T? = synchronized(lock) {
            current?.takeIf { expected == null || expected == it }?.let(action)
        }
    }
    private fun bind(store: NativeProviderTestStore, owner: Owner) = NativeProviderAccess.bind(NativeProviderVault(store), owner) {}

    @Test fun `Restore excludes lazy provider bootstrap direct writes and binding replacement`() {
        val account = SessionOwnerSnapshot.Account(id, 1)
        val owner = Owner(account)
        val store = NativeProviderTestStore()
        var legacyReads = 0
        var changed = 0
        val vault = NativeProviderVault(store) { legacyReads++; JSONObject() }
        NativeProviderAccess.bind(vault, owner) { changed++ }
        val replacement = NativeProviderVault(NativeProviderTestStore())

        val reservation = checkNotNull(AccountFileProviderWriters.tryReserve())
        try {
            assertNull(NativeProviderAccess.read(setOf("tmdb")))
            assertNull(NativeProviderAccess.captureProspective(account))
            assertNull(NativeProviderAccess.capture(setOf("tmdb")) { error("Guarded read must not run") })
            assertFalse(NativeProviderAccess.authorize("tmdb", "synthetic", 0) { error("Issue must not run") })
            assertNull(NativeProviderAccess.merge(account, JSONObject()))
            assertNull(NativeProviderAccess.hasPending(account))
            assertFalse(NativeProviderAccess.edit(mapOf("tmdb" to "synthetic")))
            assertFalse(NativeProviderAccess.acknowledge(account, JSONObject()))
            val oauth = NativeProviderAccess.oauthStore("simkl")
            assertFalse(oauth.set(mapOf("vortx.simkl.accessToken" to "synthetic", "vortx.simkl.expiresAt" to "2000000000")))
            assertEquals(PersistentCredentialAvailability.UNAVAILABLE,
                oauth.confirmedSnapshot("vortx.simkl.accessToken").availability)
            NativeProviderAccess.bind(replacement, owner) { error("Replacement must not publish") }
            NativeProviderAccess.unbindForTest()
            assertEquals(AccountFileLocalPresence.ABSENT, NativeProviderAccess.inspectRestoreVaultPresence(account, vault))
            assertEquals(AccountFileLocalPresence.UNAVAILABLE,
                NativeProviderAccess.inspectRestoreVaultPresence(account, replacement))
            assertEquals(AccountFileLocalPresence.UNAVAILABLE,
                NativeProviderAccess.inspectRestoreVaultPresence(account.copy(generation = 2), vault))
            assertTrue(AccountFileProviderWriters.isCurrent(reservation))
            assertTrue(store.values.isEmpty())
            assertEquals(0, legacyReads)
            assertEquals(0, changed)
        } finally {
            AccountFileProviderWriters.release(reservation)
        }
        assertNotNull(NativeProviderAccess.read(setOf("tmdb")))
        assertEquals(1, legacyReads)
        assertTrue(NativeProviderAccess.edit(mapOf("tmdb" to "synthetic")))
        assertEquals(1, changed)
    }

    @Test fun `provider physical carriers are counted before binding and refused during reservation`() {
        val carriers = listOf("vortx_native_provider_credentials", "vortx_debrid_keys", "vortx_metadata_credentials")
        for (carrier in carriers) {
            assertTrue(AccountFileProviderWriters.withCarrierWriter(carrier, false) {
                assertNull(AccountFileProviderWriters.tryReserve())
                true
            })
        }
        val reservation = checkNotNull(AccountFileProviderWriters.tryReserve())
        try {
            for (carrier in carriers) {
                assertFalse(AccountFileProviderWriters.withCarrierWriter(carrier, false) {
                    error("Direct physical provider opener/writer must not run")
                })
            }
            assertTrue(AccountFileProviderWriters.withCarrierWriter("synthetic-unrelated-store", false) { true })
            assertTrue(AccountFileProviderWriters.isCurrent(reservation))
        } finally { AccountFileProviderWriters.release(reservation) }
        assertTrue(AccountFileProviderWriters.withCarrierWriter(carriers.first(), false) { true })
    }

    @Test fun `native one-shot publication holds provider writer through await and publish`() = runBlocking {
        val account = SessionOwnerSnapshot.Account(id, 1)
        val owner = Owner(account)
        bind(NativeProviderTestStore(), owner)
        val operation = CredentialMutationCoordinator(NativeProviderCredentials.GROUPS[1]).operation()
        val entered = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        var requests = 0
        val response = async {
            operation.publishAfter(
                awaitValue = {
                    requests++
                    entered.complete(Unit)
                    finish.await()
                    "synthetic-token"
                },
                publish = { token ->
                    assertNull(AccountFileProviderWriters.tryReserve())
                    NativeProviderAccess.oauthStore("simkl").set(
                        mapOf("vortx.simkl.accessToken" to token, "vortx.simkl.expiresAt" to "0"),
                    )
                },
            )
        }
        try {
            entered.await()
            assertNull(AccountFileProviderWriters.tryReserve())
            finish.complete(Unit)
            assertEquals(CredentialMutationResult.Applied(true), response.await())
            assertEquals(1, requests)
            val next = CredentialMutationCoordinator(NativeProviderCredentials.GROUPS[1]).operation()
            val restore = checkNotNull(AccountFileProviderWriters.tryReserve())
            try {
                val refused = next.publishAfter(
                    awaitValue = { requests++; "must not issue" },
                    publish = { error("Must not publish under Restore") },
                )
                assertSame(CredentialMutationResult.Stale, refused)
                assertEquals(1, requests)
            } finally {
                AccountFileProviderWriters.release(restore)
            }

            val pending = next.publishAfter(
                awaitValue = { requests++; "pending" },
                publish = { it },
            )
            assertEquals(CredentialMutationResult.Applied("pending"), pending)
            val afterPending = checkNotNull(AccountFileProviderWriters.tryReserve())
            AccountFileProviderWriters.release(afterPending)
            assertEquals(2, requests)
        } finally {
            finish.complete(Unit)
            response.cancelAndJoin()
        }
    }

    @Test fun `native publication retains provider writer during cancellation cleanup`() = runBlocking {
        bind(NativeProviderTestStore(), Owner(SessionOwnerSnapshot.Account(id, 1)))
        val operation = CredentialMutationCoordinator(NativeProviderCredentials.GROUPS[0]).operation()
        val entered = CompletableDeferred<Unit>()
        val cleaning = CompletableDeferred<Unit>()
        val cleanupComplete = CompletableDeferred<Unit>()
        val response = async {
            operation.publishAfter(
                awaitValue = {
                    entered.complete(Unit)
                    try {
                        awaitCancellation()
                    } finally {
                        withContext(NonCancellable) {
                            cleaning.complete(Unit)
                            cleanupComplete.await()
                        }
                    }
                },
                publish = { error("Cancelled response must not publish") },
            )
        }
        try {
            entered.await()
            response.cancel()
            cleaning.await()
            assertNull(AccountFileProviderWriters.tryReserve())
        } finally {
            cleanupComplete.complete(Unit)
            response.cancelAndJoin()
        }
        val restore = checkNotNull(AccountFileProviderWriters.tryReserve())
        AccountFileProviderWriters.release(restore)
    }

    @Test fun `actual OAuth persistence commits tuple and intent atomically and secure failure changes neither`() {
        val store = NativeProviderTestStore(); val owner = Owner(SessionOwnerSnapshot.Account(id, 1)); bind(store, owner)
        val persistence = SIMKLAuth.TokenPersistence(NativeProviderAccess.oauthStore("simkl")) { 100L }
        persistence.save("fixture-token")
        assertTrue(persistence.isSignedIn)
        val old = store.values.toMap(); store.failWrite = true
        assertThrows(SIMKLException.SecureStorage::class.java) { persistence.clear() }
        assertEquals(old, store.values); assertTrue(persistence.isSignedIn)
        store.failWrite = false; persistence.clear(); assertFalse(persistence.isSignedIn)
        assertTrue(NativeProviderAccess.hasPending(owner.current!!)!!)
        bind(store, owner); assertFalse(persistence.isSignedIn)
        val exported = NativeProviderAccess.merge(owner.current!!, JSONObject())!!.getJSONObject("nativeProviderCredentials")
        assertTrue(exported.getJSONObject("fields").getJSONObject("simklAccess").isNull("value"))
        assertEquals(exported.getJSONObject("fields").getJSONObject("simklAccess").getLong("clock"), exported.getJSONObject("fields").getJSONObject("simklExpiry").getLong("clock"))
    }

    @Test fun `original provider snapshot never reads successor bearer or falls back after refusal`() {
        val original = SessionOwnerSnapshot.Account(id, 1)
        val replacement = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000999", 2)
        val store = NativeProviderTestStore()
        val owner = Owner(original)
        bind(store, owner)
        for ((index, provider) in listOf("trakt", "simkl").withIndex()) {
            owner.current = original
            val oauth = NativeProviderAccess.oauthStore(provider)
            val tokenKey = "vortx.$provider.accessToken"
            val values = if (provider == "trakt")
                mapOf(tokenKey to "fixture-original", "vortx.trakt.refreshToken" to "fixture-refresh",
                    "vortx.trakt.expiresAt" to "2000000000", "vortx.trakt.createdAt" to "100")
            else mapOf(tokenKey to "fixture-original", "vortx.simkl.expiresAt" to "0")
            assertTrue(oauth.set(values))
            val coordinator = CredentialMutationCoordinator(NativeProviderCredentials.GROUPS[index])
            val capture = checkNotNull(coordinator.snapshotForOwner(original) { oauth.string(tokenKey) })
            assertEquals("fixture-original", capture.value)
            owner.current = replacement
            assertTrue(oauth.set(values + (tokenKey to "fixture-successor")))
            assertNull(coordinator.snapshotForOwner(original) { fail("Refused owner performed a token read") })
            assertEquals("fixture-successor", checkNotNull(coordinator.snapshotForOwner(replacement) { oauth.string(tokenKey) }).value)
            assertSame(CredentialMutationResult.Stale, capture.operation.mutate { fail("Original operation ran for successor") })
            owner.current = original.copy(generation = 3)
            assertNull(coordinator.snapshotForOwner(original) { fail("Same ID with a new epoch performed a token read") })
        }
    }

    @Test fun `captured OAuth operation rejects newer remote intent and same-account reopen ABA`() {
        val store = NativeProviderTestStore(); val owner = Owner(SessionOwnerSnapshot.Account(id, 1)); bind(store, owner)
        val persistence = TraktAuth.TokenPersistence(NativeProviderAccess.oauthStore("trakt")) { 100L }
        val coordinator = CredentialMutationCoordinator(NativeProviderCredentials.GROUPS[0])
        val old = coordinator.operation()
        NativeProviderAccess.merge(owner.current!!, JSONObject().put("nativeProviderCredentials", wire(tuple(null))))
        var called = false
        assertSame(CredentialMutationResult.Stale, old.mutate { called = true }); assertFalse(called)
        val sameAccount = coordinator.operation()
        owner.current = null; owner.current = SessionOwnerSnapshot.Account(id, 2)
        assertSame(CredentialMutationResult.Stale, sameAccount.mutate { called = true }); assertFalse(called)
        assertFalse(persistence.isSignedIn)
        val unavailable = coordinator.operation(); store.unavailable = true
        assertFalse(unavailable.isCurrent()); assertFalse(persistence.isSignedIn)
    }

    @Test fun `newer local clear defeats delayed remote positive and cold state stays account isolated`() {
        val store = NativeProviderTestStore(); val owner = Owner(SessionOwnerSnapshot.Account(id, 1)); bind(store, owner)
        NativeProviderAccess.merge(owner.current!!, JSONObject().put("nativeProviderCredentials", wire(tuple("remote"))))
        val oauth = NativeProviderAccess.oauthStore("trakt")
        assertTrue(oauth.clear("vortx.trakt.accessToken", "vortx.trakt.refreshToken", "vortx.trakt.expiresAt", "vortx.trakt.createdAt"))
        NativeProviderAccess.merge(owner.current!!, JSONObject().put("nativeProviderCredentials", wire(tuple("remote"))))
        assertNull(oauth.string("vortx.trakt.accessToken"))
        val exported = NativeProviderAccess.merge(owner.current!!, JSONObject())!!.getJSONObject("nativeProviderCredentials")
        assertEquals(11L, exported.getJSONObject("fields").getJSONObject("traktAccess").getLong("clock"))
        owner.current = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000999", 2)
        assertTrue(NativeProviderAccess.edit(mapOf("tmdb" to "other-account")))
        owner.current = SessionOwnerSnapshot.Account(id, 3); bind(store, owner)
        assertNull(NativeProviderAccess.read(setOf("tmdb"))!!.values["tmdb"])
        assertNull(oauth.string("vortx.trakt.accessToken")); assertTrue(NativeProviderAccess.hasPending(owner.current!!)!!)
    }

    @Test fun `both OAuth publication paths reject delayed response after remote or local clear`() = runBlocking {
        for (provider in listOf("trakt", "simkl")) {
            val store = NativeProviderTestStore(); val owner = Owner(SessionOwnerSnapshot.Account(id, 1)); bind(store, owner)
            val keys = NativeProviderCredentials.GROUPS[if (provider == "trakt") 0 else 1]
            val persistence = NativeProviderAccess.oauthStore(provider)
            val coordinator = CredentialMutationCoordinator(keys)
            val values = if (provider == "trakt") mapOf(
                "vortx.trakt.accessToken" to "fixture", "vortx.trakt.refreshToken" to "fixture-refresh",
                "vortx.trakt.expiresAt" to "2000000000", "vortx.trakt.createdAt" to "100",
            ) else mapOf("vortx.simkl.accessToken" to "fixture", "vortx.simkl.expiresAt" to "0")
            assertTrue(persistence.set(values))
            if (provider == "trakt") {
                val actual = TraktAuth.TokenPersistence(persistence) { 100L }
                assertEquals("fixture", actual.load()!!.accessToken)
                store.failWrite = true
                assertThrows(TraktAuthException.SecureStorage::class.java) { actual.clear() }
                assertEquals("fixture", actual.load()!!.accessToken)
                store.failWrite = false
            }
            for (remote in listOf(true, false)) {
                val operation = coordinator.operation()
                val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
                var published = false
                val response = async {
                    operation.publishAfter(awaitValue = { entered.complete(Unit); release.await(); values }, publish = {
                        published = true; persistence.set(it)
                    })
                }
                entered.await()
                if (remote) NativeProviderAccess.merge(owner.current!!,
                    JSONObject().put("nativeProviderCredentials", wire(keys.associateWith { null }, 100)))
                else assertTrue(persistence.clear(*values.keys.toTypedArray()))
                release.complete(Unit)
                assertSame(CredentialMutationResult.Stale, response.await()); assertFalse(published)
                assertNull(persistence.string(values.keys.first()))
            }
        }
    }

    @Test fun `native Trakt single flight reuses current winner but never a different account epoch`() = runBlocking {
        val store = NativeProviderTestStore(); val owner = Owner(SessionOwnerSnapshot.Account(id, 1)); bind(store, owner)
        val now = System.currentTimeMillis() / 1000L
        val persistence = TraktAuth.TokenPersistence(NativeProviderAccess.oauthStore("trakt")) { now }
        persistence.save(TraktToken("expired", "expired-refresh", expiresIn = 60, createdAt = now - 3600))
        val coordinator = CredentialMutationCoordinator(NativeProviderCredentials.GROUPS[0])
        val first = coordinator.operation(); val waiting = coordinator.operation()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var requests = 0
        val winner = async {
            TraktAuth.refreshAfterSerialization(first, persistence) { spent ->
                TraktAuth.performRefresh(first, spent, persistence, { coordinator.invalidate(persistence::clear) }) {
                    requests++; entered.complete(Unit); release.await()
                    IntegrationsHttp.Response(200, JSONObject().put("access_token", "fresh").put("refresh_token", "fresh-refresh")
                        .put("expires_in", 3600).put("created_at", now).toString())
                }
            }
        }
        entered.await()
        assertNull(AccountFileProviderWriters.tryReserve())
        val follower = async { TraktAuth.refreshAfterSerialization(waiting, persistence) { error("Second refresh must reuse the winner") } }
        release.complete(Unit)
        assertEquals("fresh", winner.await().accessToken); assertEquals("fresh", follower.await().accessToken)
        assertEquals(1, requests)
        val restore = checkNotNull(AccountFileProviderWriters.tryReserve())
        AccountFileProviderWriters.release(restore)
        val obsolete = coordinator.operation()
        owner.current = SessionOwnerSnapshot.Account(id, 2)
        var rejected = false
        try { TraktAuth.refreshAfterSerialization(obsolete, persistence) { error("Old epoch cannot refresh") } }
        catch (_: TraktAuthException.NotSignedIn) { rejected = true }
        assertTrue(rejected)
    }

    @Test fun `native credential journal and installation actor are excluded from system backup and transfer`() {
        fun source(name: String): String = listOf(java.io.File("src/main/res/xml/$name"), java.io.File("app/src/main/res/xml/$name"))
            .first { it.isFile }.readText()
        val rule = "<exclude domain=\"sharedpref\" path=\"vortx_native_provider_credentials.xml\" />"
        assertTrue(source("backup_rules.xml").contains(rule))
        assertEquals(2, source("data_extraction_rules.xml").windowed(rule.length).count { it == rule })
    }
}
