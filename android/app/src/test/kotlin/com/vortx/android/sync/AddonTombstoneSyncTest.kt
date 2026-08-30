package com.vortx.android.sync

import com.vortx.android.data.AddonTombstonePersistence
import com.vortx.android.data.AddonTombstones
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private class MemoryAddonTombstonePersistence : AddonTombstonePersistence {
    private val values = HashMap<String, String>()

    override fun read(key: String): String? = values[key]

    override fun write(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
    }
}

class AddonTombstoneSyncTest {

    private val url = "https://example.com/manifest.json"

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
        assertFalse(equalVersionFold.shouldApplyVersionedPayload)
        assertTrue(url in tombstones.all())

        // EngineStremioRepository calls forget only after a successful explicit install.
        now = 300.0
        assertTrue(tombstones.forget(url))
        assertFalse(url in tombstones.all())
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
