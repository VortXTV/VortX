package com.vortx.android.sync

import com.vortx.android.data.AddonTombstonePersistence
import com.vortx.android.data.AddonTombstones
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

private class MemoryAddonTombstonePersistence : AddonTombstonePersistence {
    private val values = HashMap<String, String>()

    override fun read(key: String): String? = values[key]

    override fun write(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
    }
}

class AddonTombstoneSyncTest {

    private val url = "https://example.com/manifest.json"

    @Before
    fun activateTestAccount() {
        AddonTombstones.activateAccount("test-account")
    }

    @Test
    fun `tombstones are isolated by account and survive switching back`() {
        var scope = "account-a"
        var now = 100.0
        val persistence = MemoryAddonTombstonePersistence()
        val tombstones = AddonTombstones(persistence, { now }) { scope }
        val aUrl = "https://a.example/manifest.json"
        val bUrl = "https://b.example/manifest.json"

        assertTrue(tombstones.tombstone(aUrl))
        scope = "account-b"
        assertFalse(aUrl in tombstones.all())
        now = 200.0
        assertTrue(tombstones.tombstone(bUrl))
        assertTrue(bUrl in tombstones.all())
        scope = "account-a"
        assertTrue(aUrl in tombstones.all())
        assertFalse(bUrl in tombstones.all())
    }

    @Test
    fun `separate tombstone instances retain concurrent independent removals`() {
        var scope = "account"
        val persistence = MemoryAddonTombstonePersistence()
        val first = AddonTombstones(persistence, { 100.0 }) { scope }
        val second = AddonTombstones(persistence, { 200.0 }) { scope }
        val start = CountDownLatch(1)
        val done = CountDownLatch(2)

        thread {
            start.await(2, TimeUnit.SECONDS)
            first.tombstone("https://first.example/manifest.json")
            done.countDown()
        }
        thread {
            start.await(2, TimeUnit.SECONDS)
            second.tombstone("https://second.example/manifest.json")
            done.countDown()
        }
        start.countDown()
        assertTrue(done.await(2, TimeUnit.SECONDS))
        assertEquals(
            setOf("https://first.example/manifest.json", "https://second.example/manifest.json"),
            first.all(),
        )
    }

    @Test
    fun `peer deletion suppresses seeded state and later explicit reinstall wins`() {
        var now = 100.0
        val tombstones = AddonTombstones(MemoryAddonTombstonePersistence()) { now }

        // A prior Android install is represented by addedAt. A newer peer removal must still win.
        tombstones.forget(url)
        val pulled = VortXSyncDoc.parse(
            JSONObject().put(
                "vortx",
                JSONObject()
                    .put("deletedAddons", JSONArray().put(url))
                    .put(
                        "deletedAddonsTs",
                        JSONObject().put(url, JSONObject().put("removedAt", 200.0)),
                    ),
            ),
        )
        // syncDown calls this production seam before its equal/older-version return, so the remote stamp
        // converges even when the rest of the account document is skipped by version-wins.
        val equalVersionFold = foldAddonTombstonesForSyncDown(
            tombstones = tombstones,
            parsed = pulled,
            pulledVersion = 10L,
            lastSyncedVersion = 10L,
            force = false,
        )
        assertTrue(equalVersionFold.changed)
        assertTrue(equalVersionFold.shouldFoldLibraryTombstones)
        assertFalse(equalVersionFold.shouldApplyVersionedPayload)
        assertTrue(url in tombstones.all())

        // EngineStremioRepository calls forget only after a successful explicit install.
        now = 300.0
        assertTrue(tombstones.forget(url))
        assertFalse(url in tombstones.all())
    }

    @Test
    fun `older authenticated sync down doc folds only add-on tombstones`() {
        var now = 100.0
        val tombstones = AddonTombstones(MemoryAddonTombstonePersistence()) { now }
        val peerRemoval = "https://peer.example/manifest.json"
        val olderDoc = JSONObject()
            .put("settings", JSONObject().put("shouldNotApply", true))
            .put("foreignAccountField", "preserve")
            .put(
                "vortx",
                JSONObject()
                    .put("profiles", JSONArray().put(JSONObject().put("id", "peer-profile")))
                    .put("deletedLibrary", JSONArray().put("library-entry"))
                    .put("futureSurfaceField", JSONObject().put("keep", true))
                    .put(
                        "deletedAddonsTs",
                        JSONObject().put(peerRemoval, JSONObject().put("removedAt", 200.0)),
                    ),
            )

        // syncDown reaches this production fold only after the replayed envelope has authenticated and decrypted.
        val staleFold = foldAddonTombstonesForSyncDown(
            tombstones = tombstones,
            parsed = VortXSyncDoc.parse(olderDoc),
            pulledVersion = 9L,
            lastSyncedVersion = 10L,
            force = true,
        )

        assertTrue(staleFold.changed)
        assertFalse(staleFold.shouldFoldLibraryTombstones)
        assertFalse(staleFold.shouldApplyVersionedPayload)
        assertTrue(peerRemoval in tombstones.all())
        // The seam returns guards only and does not publish profile/settings/foreign data from a replayed doc.
        assertTrue(olderDoc.getJSONObject("settings").getBoolean("shouldNotApply"))
        assertEquals("preserve", olderDoc.getString("foreignAccountField"))
        assertTrue(olderDoc.getJSONObject("vortx").getJSONObject("futureSurfaceField").getBoolean("keep"))

        now = 300.0
        assertTrue(tombstones.forget(peerRemoval))
        assertFalse(peerRemoval in tombstones.all())
    }

    @Test
    fun `legacy app and web removals fold into the timestamped store`() {
        var now = 500.0
        val tombstones = AddonTombstones(MemoryAddonTombstonePersistence()) { now }
        val appLegacy = "https://legacy.example/manifest.json"
        val webLegacy = "https://web.example/manifest.json"
        val pulled = VortXSyncDoc.parse(
            JSONObject()
                .put("webAddonRemovals", JSONArray().put(webLegacy))
                .put("vortx", JSONObject().put("deletedAddons", JSONArray().put(appLegacy))),
        )

        assertTrue(
            foldAddonTombstonesForSyncDown(tombstones, pulled, 10L, 0L, force = false).changed,
        )
        assertTrue(appLegacy in tombstones.all())
        assertTrue(webLegacy in tombstones.all())

        // A genuine later install beats the migration-epoch legacy app removal.
        now = 600.0
        assertTrue(tombstones.forget(appLegacy))
        assertFalse(appLegacy in tombstones.all())
    }

    @Test
    fun `add-on wire parsing ignores malformed mixed entries`() {
        val valid = "https://valid.example/manifest.json"
        val parsed = VortXSyncDoc.parse(
            JSONObject()
                .put(
                    "webAddonRemovals",
                    JSONArray().put(valid).put(99).put(JSONObject.NULL).put(JSONObject().put("url", valid)),
                )
                .put(
                    "vortx",
                    JSONObject()
                        .put(
                            "deletedAddons",
                            JSONArray().put(valid).put(false).put(JSONObject.NULL).put(JSONArray().put(valid)),
                        )
                        .put(
                            "deletedAddonsTs",
                            JSONObject()
                                .put(valid, JSONObject().put("removedAt", 123.0).put("addedAt", 122.0))
                                .put("not-an-object", "bad")
                                .put("null-entry", JSONObject.NULL)
                                .put("non-numeric", JSONObject().put("removedAt", "bad")),
                        ),
                ),
        )

        assertEquals(listOf(valid), parsed.deletedAddons)
        assertEquals(listOf(valid), parsed.webAddonRemovals)
        assertEquals(mapOf("removedAt" to 123.0, "addedAt" to 122.0), parsed.deletedAddonsTs[valid])
        assertEquals(setOf(valid), parsed.deletedAddonsTs.keys)
    }

    @Test
    fun `identical legacy web removal is minted once`() {
        var now = 700.0
        val tombstones = AddonTombstones(MemoryAddonTombstonePersistence()) { now }
        val webUrl = "https://web.example/manifest.json"
        val parsed = VortXSyncDoc.parse(JSONObject().put("webAddonRemovals", JSONArray().put(webUrl)))

        assertTrue(
            foldAddonTombstonesForSyncDown(tombstones, parsed, 10L, 0L, force = false).changed,
        )
        val firstStamp = tombstones.timestampsForSync().getValue(webUrl).getValue("removedAt")
        now = 900.0
        assertFalse(
            foldAddonTombstonesForSyncDown(tombstones, parsed, 10L, 10L, force = false).changed,
        )
        assertEquals(firstStamp, tombstones.timestampsForSync().getValue(webUrl).getValue("removedAt"), 0.0)
    }

    @Test
    fun `publishing effective tombstones preserves foreign account fields`() {
        var now = 1_000.0
        val tombstones = AddonTombstones(MemoryAddonTombstonePersistence()) { now }
        tombstones.tombstone(url)
        val vortx = JSONObject()
            .put("addons", JSONArray().put(JSONObject().put("transportUrl", "https://foreign.example/manifest.json")))
            .put("addonsOwnedAt", 42.0)
            .put("library", JSONArray().put(JSONObject().put("id", "tt123")))
            .put("futureSurfaceField", JSONObject().put("keep", true))

        applyAddonTombstonesToVortx(vortx, tombstones)

        assertEquals(42.0, vortx.getDouble("addonsOwnedAt"), 0.0)
        assertEquals("tt123", vortx.getJSONArray("library").getJSONObject(0).getString("id"))
        assertTrue(vortx.getJSONObject("futureSurfaceField").getBoolean("keep"))
        assertEquals(url, vortx.getJSONArray("deletedAddons").getString(0))
        assertEquals(1_000.0, vortx.getJSONObject("deletedAddonsTs").getJSONObject(url).getDouble("removedAt"), 0.0)
    }
}
