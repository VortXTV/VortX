package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.library.NativeWatchlistCodec
import com.vortx.android.library.WatchlistEntry
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.SessionOwnerSnapshot
import java.nio.file.Files
import java.util.Base64
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class NativeWatchlistAccessTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 7)
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
    private val scope = VortxAccountScope("account.${account.id}", owner.id)
    private val first = WatchlistEntry("tt123", "movie", "🍿 / Revised", null, 123.5)
    private val second = WatchlistEntry("tt456", "series", "Independent", null, 130.0)
    private fun bindings(): VortxRuntimeBindings {
        assumeTrue(System.getenv("VORTX_JNI_SYNC") == "1" && !System.getenv("VORTX_JNI_LIBRARY").isNullOrBlank())
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        return object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
    }
    private fun document() = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode()))
        .put("rosterModified", 1).put("library", JSONArray()).put("addons", JSONArray()))
    private fun settings(vararg entries: Pair<String, Any>): String = Base64.getEncoder().encodeToString(
        requireNotNull(SettingsBackup.encode(linkedMapOf(*entries), "tv.vortx", "Fixture")))
    private fun values(vararg entries: WatchlistEntry) = JSONArray().also { result -> entries.forEach { result.put(NativeWatchlistCodec.value(it)) } }
        .toString().toByteArray()
    private inner class Fixture : AutoCloseable {
        val directory = Files.createTempDirectory("native-watchlist-").toFile()
        val disk = VortxEncryptedCheckpointStore(directory) { SecretKeySpec(ByteArray(32) { 41 }, "AES") }
        var fail = false
        val store = object : VortxCheckpointStore by disk {
            override fun commit(scope: VortxAccountScope, snapshot: String) { check(!fail) { "Fixture commit failure" }; disk.commit(scope, snapshot) }
        }
        var current = true
        var invalidated = 0
        val accounts = NativeAccountCoordinator(bindings(), store, { object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No network")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network")
        } }, { it == account && current }, { it() }, {},
            captureOwnAccountAdmission = { expected -> { action -> expected == account && current && action() } },
            onAuthorityChanged = { invalidated += 1 })
        val access = NativeWatchlistAccess(accounts)
        override fun close() { accounts.retire(); directory.deleteRecursively() }
    }

    @Test fun `authenticated UUID Data seeds absent registers after remote merge without changing native library`() = runBlocking {
        Fixture().use { fixture ->
            val remote = NativeHostPreferences.recordProfileFields(scope, NativeHostPreferences.local(scope), owner.id,
                JSONObject().put(NativeWatchlistCodec.field(second.id, second.type), JSONObject.NULL)).getJSONObject("document")
            val original = document().put("settings", settings("vortx.watchlist.${owner.id}" to values(first, second)))
                .put("nativeHostPreferences", remote)
            assertTrue(fixture.accounts.applyDocument(account, original) { fixture.current })
            val snapshot = fixture.access.capture().getOrThrow()
            assertEquals(listOf(first), NativeWatchlistCodec.entries(snapshot.registers))
            val register = snapshot.registers.getJSONObject(NativeWatchlistCodec.field(first.id, first.type))
            assertEquals(0L, register.getLong("clock"))
            assertEquals("e2845c02-42cf-6e8c-1cc4-bef50778d4b4", register.getString("actor"))
            assertTrue(snapshot.registers.getJSONObject(NativeWatchlistCodec.field(second.id, second.type)).isNull("value"))
            val state = fixture.accounts.session().read().state
            assertEquals(0, state.getJSONObject("nativeSync").getJSONObject("libraries").getJSONObject(owner.id).getJSONObject("records").length())
            assertFalse(state.getJSONObject("hostProfilePreferences").getJSONObject(owner.id).has(NativeWatchlistCodec.field(first.id, first.type)))
            assertEquals(original.getString("settings"), state.getJSONObject("hostDocument").getString("settings"))
            fixture.accounts.retire()
            assertTrue(fixture.accounts.reopenCheckpoint(account) { fixture.current })
            assertEquals(listOf(first), NativeWatchlistCodec.entries(fixture.access.capture().getOrThrow().registers))
        }
    }

    @Test fun `per item durable edits reject stale ordinary revision and survive peer merge and cold reopen`() = runBlocking {
        Fixture().use { fixture ->
            assertTrue(fixture.accounts.applyDocument(account, document()) { fixture.current })
            val initial = fixture.access.capture().getOrThrow()
            val native = fixture.accounts.session().read().state.getJSONObject("nativeSync").toString()
            val added = fixture.access.mutate(initial.owner, NativeWatchlistCodec.change(first, true)).getOrThrow()
            var published = false
            assertFalse(fixture.access.publishIfCurrent(initial.owner) { published = true }); assertFalse(published)
            assertTrue(fixture.access.mutate(initial.owner, NativeWatchlistCodec.change(second, true)).isFailure)
            assertTrue(fixture.access.publishIfCurrent(added.owner) { published = true }); assertTrue(published)
            val deleted = fixture.access.mutate(added.owner, NativeWatchlistCodec.change(first, false)).getOrThrow()
            assertTrue(NativeWatchlistCodec.entries(deleted.registers).isEmpty())
            val peer = NativeHostPreferences.recordProfileFields(scope, NativeHostPreferences.local(scope), owner.id,
                NativeWatchlistCodec.change(second, true)).getJSONObject("document")
            assertTrue(fixture.accounts.applyDocument(account, document().put("nativeHostPreferences", peer)) { fixture.current })
            assertEquals(listOf(second), NativeWatchlistCodec.entries(fixture.access.capture().getOrThrow().registers))
            assertEquals(native, fixture.accounts.session().read().state.getJSONObject("nativeSync").toString())
            fixture.accounts.retire(); assertTrue(fixture.accounts.reopenCheckpoint(account) { fixture.current })
            val cold = fixture.access.capture().getOrThrow()
            assertEquals(listOf(second), NativeWatchlistCodec.entries(cold.registers))
            assertTrue(cold.registers.getJSONObject(NativeWatchlistCodec.field(first.id, first.type)).isNull("value"))
            assertTrue(fixture.access.mutate(deleted.owner, NativeWatchlistCodec.change(first, true)).isFailure)
        }
    }

    @Test fun `profile and same account reopen ABA clear publication and reject captured actions`() = runBlocking {
        Fixture().use { fixture ->
            assertTrue(fixture.accounts.applyDocument(account, document()) { fixture.current })
            val profiles = NativeProfileAccess { fixture.accounts.session() }
            val guest = UserProfile(id = "00000000-0000-0000-0000-000000000009", name = "Guest", avatar = "🎬")
            profiles.save(guest, true)
            val ownerCapture = fixture.access.capture().getOrThrow(); val before = fixture.invalidated
            profiles.select(guest.id)
            assertTrue(fixture.invalidated > before)
            val guestCapture = fixture.access.capture().getOrThrow()
            assertTrue(NativeWatchlistCodec.entries(guestCapture.registers).isEmpty())
            profiles.select(owner.id)
            assertFalse(fixture.access.publishIfCurrent(ownerCapture.owner) { fail("Stale profile publication") })
            assertTrue(fixture.access.mutate(guestCapture.owner, NativeWatchlistCodec.change(first, true)).isFailure)
            val priorMount = fixture.access.capture().getOrThrow()
            fixture.accounts.retire(); assertTrue(fixture.accounts.reopenCheckpoint(account) { fixture.current })
            assertFalse(fixture.access.publishIfCurrent(priorMount.owner) { fail("Stale mount publication") })
            fixture.current = false
            assertTrue(fixture.access.capture().isFailure)
        }
    }

    @Test fun `checkpoint failure never acknowledges an edit or publishes an uncommitted ledger`() = runBlocking {
        Fixture().use { fixture ->
            assertTrue(fixture.accounts.applyDocument(account, document()) { fixture.current })
            val before = fixture.disk.read(scope); val capture = fixture.access.capture().getOrThrow()
            fixture.fail = true
            assertTrue(fixture.access.mutate(capture.owner, NativeWatchlistCodec.change(first, true)).isFailure)
            assertFalse(fixture.access.publishIfCurrent(capture.owner) { fail("Poisoned publication") })
            assertEquals(before, fixture.disk.read(scope))
            fixture.accounts.retire(); fixture.fail = false
            assertTrue(fixture.accounts.reopenCheckpoint(account) { fixture.current })
            assertTrue(NativeWatchlistCodec.entries(fixture.access.capture().getOrThrow().registers).isEmpty())
        }
    }

    @Test fun `unqualified unknown and malformed authenticated Watchlists stay preserved and pending`() = runBlocking {
        Fixture().use { fixture ->
            val blob = settings("vortx.watchlist" to values(first), "vortx.watchlist.${owner.id}" to "{}".toByteArray(),
                "vortx.watchlist.00000000-0000-0000-0000-000000000999" to values(second))
            assertTrue(fixture.accounts.applyDocument(account, document().put("settings", blob)) { fixture.current })
            assertEquals(3, fixture.accounts.migrationStatus()!!.watchlistPending)
            assertTrue(NativeWatchlistCodec.entries(fixture.access.capture().getOrThrow().registers).isEmpty())
            assertEquals(blob, fixture.accounts.session().read().state.getJSONObject("hostDocument").getString("settings"))
        }
    }

    @Test fun `host validation admits long canonical keys and plain titles but rejects malformed tombstones and encoded secrets`() {
        val long = WatchlistEntry("tt" + "1".repeat(510), "movie", "Independent", null, 1.0)
        val field = NativeWatchlistCodec.field(long.id, long.type)
        assertTrue(field.length > 512)
        NativeHostPreferences.recordProfileFields(scope, NativeHostPreferences.local(scope), owner.id, NativeWatchlistCodec.change(long, true))
        NativeHostPreferences.recordProfileFields(scope, NativeHostPreferences.local(scope), owner.id, JSONObject().put(field, JSONObject.NULL))
        assertTrue(runCatching { NativeHostPreferences.recordProfileFields(scope, NativeHostPreferences.local(scope), owner.id,
            JSONObject().put("watchlist.movie.notcanonical!", JSONObject.NULL)) }.isFailure)
        val secret = first.copy(name = Base64.getEncoder().encodeToString("{\"authKey\":\"never-archive\"}".toByteArray()))
        assertTrue(runCatching { NativeHostPreferences.recordProfileFields(scope, NativeHostPreferences.local(scope), owner.id,
            NativeWatchlistCodec.change(secret, true)) }.isFailure)
        for (key in listOf("vortx.quickViewEnabled", "vortx.cinema.quickView")) {
            assertTrue(runCatching { NativeHostPreferences.recordGlobals(scope, NativeHostPreferences.local(scope), JSONObject().put(key, "true")) }.isFailure)
        }
        val fields = NativeHostPreferences.recordGlobals(scope, NativeHostPreferences.local(scope),
            JSONObject().put("vortx.quickViewEnabled", true).put("vortx.cinema.quickView", false)).getJSONObject("document").getJSONObject("globals").getJSONObject("fields")
        assertTrue(fields.getJSONObject("vortx.quickViewEnabled").getBoolean("value"))
        assertFalse(fields.getJSONObject("vortx.cinema.quickView").getBoolean("value"))
    }
}
