package com.vortx.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** In-memory persistence so the tombstone logic is exercised without Android SharedPreferences. */
private class FakeTombstonePersistence : AddonTombstonePersistence {
    val store = HashMap<String, String>()
    val reads = mutableListOf<String>()
    val writes = mutableListOf<String>()

    override fun read(key: String): String? {
        reads += key
        return store[key]
    }

    override fun write(key: String, value: String?) {
        writes += key
        if (value == null) store.remove(key) else store[key] = value
    }
}

class AddonTombstonesTest {

    private fun store(persistence: FakeTombstonePersistence, now: () -> Double) =
        AddonTombstones(persistence, now)

    private val url = "https://example.com/manifest.json"

    @Before
    fun activateTestAccount() {
        AddonTombstones.activateAccount("test-account")
    }

    @Test
    fun `tombstone marks a url effectively removed`() {
        val p = FakeTombstonePersistence()
        var now = 1_000.0
        val t = store(p) { now }

        assertTrue(t.tombstone(url))
        assertTrue(url in t.all())
        // Idempotent: a second removal is not a NEW removal.
        now = 2_000.0
        assertFalse(t.tombstone(url))
        assertTrue(url in t.all())
    }

    @Test
    fun `a later install out-races an earlier removal`() {
        val p = FakeTombstonePersistence()
        var now = 1_000.0
        val t = store(p) { now }

        t.tombstone(url)
        assertTrue(url in t.all())
        now = 2_000.0
        assertTrue(t.forget(url))
        assertFalse(url in t.all())
        // And a NEW removal after that install wins again.
        now = 3_000.0
        assertTrue(t.tombstone(url))
        assertTrue(url in t.all())
    }

    @Test
    fun `normalize matches across casing and whitespace`() {
        val p = FakeTombstonePersistence()
        val t = store(p) { 1_000.0 }
        t.tombstone("  HTTPS://Example.com/Manifest.json  ")
        assertTrue("https://example.com/manifest.json" in t.all())
    }

    @Test
    fun `legacy deleted array folds at the migration epoch and a real install out-races it`() {
        val p = FakeTombstonePersistence()
        var now = 10_000.0
        val t = store(p) { now }

        // A stamp-less legacy removal folds at the epoch (removedAt == MIGRATION_EPOCH_MS).
        assertTrue(t.merge(legacyIds = listOf(url), stamps = emptyMap()))
        assertTrue(url in t.all())
        // A genuine local install (real wall-clock addedAt) out-races the epoch removal.
        assertTrue(t.forget(url))
        assertFalse(url in t.all())
    }

    @Test
    fun `merge folds peer stamps by max and a peer reinstall flips removed to present`() {
        val p = FakeTombstonePersistence()
        var now = 100_000.0
        val t = store(p) { now }

        t.tombstone(url) // local removedAt = 100000
        assertTrue(url in t.all())

        // Peer install stamp newer than the local removal flips it back to present, and merge reports change.
        val stamps = mapOf(url to mapOf("addedAt" to 200_000.0))
        assertTrue(t.merge(legacyIds = emptyList(), stamps = stamps))
        assertFalse(url in t.all())

        // Re-folding the same stamps is a no-op (monotone).
        assertFalse(t.merge(legacyIds = emptyList(), stamps = stamps))
    }

    @Test
    fun `web removal is minted only for an untracked url`() {
        val p = FakeTombstonePersistence()
        val t = store(p) { 500_000.0 }

        // Never tracked: minted removedAt = now, so it is effectively removed.
        assertTrue(t.merge(legacyIds = emptyList(), stamps = emptyMap(), webIds = listOf(url)))
        assertTrue(url in t.all())

        // Locally installed after: a stamp-less web re-emit must NOT re-remove it.
        val other = "https://other.example/manifest.json"
        val t2 = store(p) { 600_000.0 }
        t2.forget(other) // addedAt present -> tracked
        assertFalse(t2.merge(legacyIds = emptyList(), stamps = emptyMap(), webIds = listOf(other)))
        assertFalse(other in t2.all())
    }

    @Test
    fun `baselineInstalled stamps installs but never masks a real removal`() {
        val p = FakeTombstonePersistence()
        var now = 1_000_000.0
        val t = store(p) { now }

        val a = "https://a.example/manifest.json"
        val b = "https://b.example/manifest.json"
        t.tombstone(b) // a genuine post-epoch removal at 1,000,000

        now = 2_000_000.0
        t.baselineInstalled(listOf(a, b))
        // `a` was untracked -> baselined present. `b` had a real removal -> baseline must not resurrect it.
        assertFalse(a in t.all())
        assertTrue(b in t.all())
    }

    @Test
    fun `dual-write keeps the legacy array as the effective removed set`() {
        val p = FakeTombstonePersistence()
        val t = store(p) { 1_000.0 }
        t.tombstone(url)
        val legacy = p.store["stremiox.addons.deleted.account.test-account"]
        assertTrue(legacy != null && legacy.contains("example.com"))
    }

    @Test
    fun `timestampsForSync carries both stamps`() {
        val p = FakeTombstonePersistence()
        var now = 1_000.0
        val t = store(p) { now }
        t.tombstone(url)
        now = 2_000.0
        t.forget(url)
        val entry = t.timestampsForSync()[AddonTombstones.normalize(url)]
        assertEquals(1_000.0, entry?.get("removedAt"))
        assertEquals(2_000.0, entry?.get("addedAt"))
    }

    @Test
    fun `signed out removals persist locally, support reinstall, and never expose sync stamps`() {
        val p = FakeTombstonePersistence().apply {
            store["stremiox.addons.deleted"] = "[\"$url\"]"
        }
        val t = store(p) { 1_000.0 }
        AddonTombstones.activateAccount(null)

        assertTrue(url in t.all())
        assertTrue(t.timestampsForSync().isEmpty())
        assertFalse(t.tombstone(url))
        assertTrue(t.forget(url))
        assertTrue(t.tombstone(url))
        assertFalse(t.merge(legacyIds = listOf(url), stamps = emptyMap()))
        t.baselineInstalled(listOf(url))

        // Engine reset creates a fresh store instance. The removal must still suppress the re-seeded add-on.
        val afterEngineReset = store(p) { 2_000.0 }
        assertTrue(url in afterEngineReset.all())
        assertTrue(url in t.all())
        assertTrue(p.writes.all { !it.contains(".account.") })
        assertTrue(p.store["stremiox.addons.deleted"]?.contains(url) == true)
    }

    @Test
    fun `legacy unscoped removals survive upgrade but remain quarantined from every account`() {
        val p = FakeTombstonePersistence().apply {
            store["stremiox.addons.deleted"] = "[\"$url\"]"
            store["stremiox.addons.removedAt"] = "{\"$url\":1000}"
        }
        val t = store(p) { 2_000.0 }

        AddonTombstones.activateAccount(null)
        assertTrue(url in t.all())
        assertTrue(t.timestampsForSync().isEmpty())

        p.reads.clear()
        p.writes.clear()
        AddonTombstones.activateAccount("test-account")
        assertTrue(t.all().isEmpty())
        assertTrue(t.timestampsForSync().isEmpty())
        assertTrue(t.tombstone(url))

        assertEquals("[\"$url\"]", p.store["stremiox.addons.deleted"])
        assertEquals("{\"$url\":1000}", p.store["stremiox.addons.removedAt"])
        assertTrue(p.reads.none { it == "stremiox.addons.deleted" || it == "stremiox.addons.removedAt" })
        assertTrue(p.writes.all { it.contains(".account.test-account") })
    }

    @Test
    fun `account scopes isolate removals and restore their own state after sign out`() {
        val p = FakeTombstonePersistence()
        var now = 1_000.0
        val t = store(p) { now }
        val a = "https://a.example/manifest.json"
        val b = "https://b.example/manifest.json"

        AddonTombstones.activateAccount("account-a")
        assertTrue(t.tombstone(a))
        AddonTombstones.activateAccount("account-b")
        assertTrue(t.all().isEmpty())
        assertTrue(t.tombstone(b))

        AddonTombstones.activateAccount(null)
        assertTrue(t.all().isEmpty())
        assertTrue(t.tombstone(url))
        assertTrue(t.timestampsForSync().isEmpty())

        AddonTombstones.activateAccount("account-a")
        assertEquals(setOf(a), t.all())
        AddonTombstones.activateAccount("account-b")
        assertEquals(setOf(b), t.all())
        AddonTombstones.activateAccount(null)
        assertEquals(setOf(url), t.all())
    }
}
