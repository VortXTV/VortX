package com.vortx.android.iptv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Round-trip + merge tests for [IPTVPlaylistStore] over an in-memory [IPTVPersistence] fake, so the store's
/// add / remove / credential / tombstone / sync-blob logic is exercised without a device or Robolectric.
/// (The store serializes with `org.json`, so this file needs `org.json` on the test classpath; the request
/// -shape tests in [IPTVConverterClientTest] need only JUnit.)
class IPTVPlaylistStoreTest {

    /// In-memory [IPTVPersistence]: the non-secret metadata as two nullable JSON strings, the credentials as a
    /// map. Mirrors the production split (SharedPreferences + SecureTokenStore) without Android.
    private class FakeIPTVPersistence : IPTVPersistence {
        var playlistsJson: String? = null
        var removedJson: String? = null
        val creds = HashMap<String, String>()

        override fun readPlaylistsJson(): String? = playlistsJson
        override fun writePlaylistsJson(json: String) { playlistsJson = json }
        override fun readRemovedJson(): String? = removedJson
        override fun writeRemovedJson(json: String) { removedJson = json }
        override fun readCredential(slug: String): String? = creds[slug]
        override fun writeCredential(slug: String, json: String?) {
            if (json == null) creds.remove(slug) else creds[slug] = json
        }
    }

    private fun playlist(
        id: String = "slug1",
        name: String = "My IPTV",
        kind: IPTVKind = IPTVKind.M3U,
        transportUrl: String = "https://iptv.vortx.tv/c/slug1/manifest.json",
        createdAt: Long = 1_000L,
    ) = IPTVPlaylist(id, name, kind, transportUrl, createdAt)

    private val m3uCreds = IPTVCredentials(m3uUrl = "https://p.example/pl.m3u", xmltvUrl = "https://p.example/xmltv.php")
    private val xtreamCreds = IPTVCredentials(xtreamHost = "http://h:8080", xtreamUser = "u", xtreamPass = "p")

    // ---- add / read ----

    @Test
    fun `add records the playlist and its credentials`() {
        val store = IPTVPlaylistStore(FakeIPTVPersistence())
        store.add(playlist(), m3uCreds)

        assertEquals(listOf(playlist()), store.playlists())
        assertEquals(m3uCreds, store.credentials("slug1"))
        assertTrue(store.contains("https://iptv.vortx.tv/c/slug1/manifest.json"))
        assertFalse(store.contains("https://elsewhere/manifest.json"))
    }

    @Test
    fun `add prepends newest-first and is idempotent by slug`() {
        val store = IPTVPlaylistStore(FakeIPTVPersistence())
        store.add(playlist(id = "a", transportUrl = "https://iptv.vortx.tv/c/a/manifest.json", createdAt = 1L), m3uCreds)
        store.add(playlist(id = "b", transportUrl = "https://iptv.vortx.tv/c/b/manifest.json", createdAt = 2L), xtreamCreds)
        assertEquals(listOf("b", "a"), store.playlists().map { it.id })

        // Re-adding slug "a" replaces (not duplicates) and moves it to the front.
        store.add(playlist(id = "a", name = "Renamed", transportUrl = "https://iptv.vortx.tv/c/a/manifest.json", createdAt = 3L), m3uCreds)
        assertEquals(listOf("a", "b"), store.playlists().map { it.id })
        assertEquals("Renamed", store.playlists().first { it.id == "a" }.name)
    }

    @Test
    fun `add survives a reload from the same persistence`() {
        val persistence = FakeIPTVPersistence()
        IPTVPlaylistStore(persistence).add(playlist(kind = IPTVKind.XTREAM), xtreamCreds)

        // A fresh store over the SAME backing store must read the record + credentials back through JSON.
        val reopened = IPTVPlaylistStore(persistence)
        assertEquals(1, reopened.playlists().size)
        assertEquals(playlist(kind = IPTVKind.XTREAM), reopened.playlists()[0])
        assertEquals(xtreamCreds, reopened.credentials("slug1"))
    }

    // ---- remove ----

    @Test
    fun `remove drops the record and credentials and stamps a tombstone`() {
        val persistence = FakeIPTVPersistence()
        val store = IPTVPlaylistStore(persistence)
        store.add(playlist(), m3uCreds)

        store.remove("slug1")
        assertTrue(store.playlists().isEmpty())
        assertNull(store.credentials("slug1"))
        assertFalse(store.contains("https://iptv.vortx.tv/c/slug1/manifest.json"))
        assertNotNull("a removal tombstone must be persisted", persistence.removedJson)
        assertTrue(persistence.removedJson!!.contains("slug1"))
    }

    @Test
    fun `removing one leaves the others`() {
        val store = IPTVPlaylistStore(FakeIPTVPersistence())
        store.add(playlist(id = "a", transportUrl = "https://iptv.vortx.tv/c/a/manifest.json", createdAt = 1L), m3uCreds)
        store.add(playlist(id = "b", transportUrl = "https://iptv.vortx.tv/c/b/manifest.json", createdAt = 2L), xtreamCreds)
        store.remove("a")
        assertEquals(listOf("b"), store.playlists().map { it.id })
    }

    // ---- sync blob ----

    @Test
    fun `sync blob is null when there is nothing to sync`() {
        assertNull(IPTVPlaylistStore(FakeIPTVPersistence()).syncBlob())
    }

    @Test
    fun `sync blob round-trips one store into a fresh peer`() {
        val source = IPTVPlaylistStore(FakeIPTVPersistence())
        source.add(playlist(), m3uCreds)
        val blob = source.syncBlob()
        assertNotNull(blob)

        val peer = IPTVPlaylistStore(FakeIPTVPersistence())
        peer.applySyncBlob(blob!!)
        assertEquals(listOf(playlist()), peer.playlists())
        // Credential adopted into the empty local slot (the leg that revives a reinstalled device).
        assertEquals(m3uCreds, peer.credentials("slug1"))
    }

    @Test
    fun `apply sync blob never deletes a locally-added playlist the remote lacks`() {
        val source = IPTVPlaylistStore(FakeIPTVPersistence())
        source.add(playlist(id = "remote", transportUrl = "https://iptv.vortx.tv/c/remote/manifest.json", createdAt = 5L), m3uCreds)
        val remoteBlob = source.syncBlob()!!

        val local = IPTVPlaylistStore(FakeIPTVPersistence())
        local.add(playlist(id = "local", transportUrl = "https://iptv.vortx.tv/c/local/manifest.json", createdAt = 9L), xtreamCreds)
        local.applySyncBlob(remoteBlob)

        val ids = local.playlists().map { it.id }.toSet()
        assertEquals(setOf("local", "remote"), ids)
    }

    @Test
    fun `apply sync blob honors a newer local tombstone and does not resurrect`() {
        // Peer still holds a playlist (createdAt in the distant past) that the user removed locally just now.
        val source = IPTVPlaylistStore(FakeIPTVPersistence())
        source.add(playlist(createdAt = 1_000L), m3uCreds)
        val staleBlob = source.syncBlob()!!

        val local = IPTVPlaylistStore(FakeIPTVPersistence())
        local.add(playlist(createdAt = 1_000L), m3uCreds)
        local.remove("slug1") // tombstone stamped at "now", far newer than createdAt 1000

        local.applySyncBlob(staleBlob)
        assertTrue("a removed playlist must not be resurrected by a stale peer", local.playlists().isEmpty())
    }

    @Test
    fun `apply sync blob keeps the local credential when the slot is already filled`() {
        val source = IPTVPlaylistStore(FakeIPTVPersistence())
        source.add(playlist(), IPTVCredentials(m3uUrl = "https://remote/pl.m3u"))
        val remoteBlob = source.syncBlob()!!

        val local = IPTVPlaylistStore(FakeIPTVPersistence())
        local.add(playlist(), m3uCreds) // local already has a credential
        local.applySyncBlob(remoteBlob)

        // The encrypted store stays authoritative: the local credential is not overwritten by the peer's.
        assertEquals(m3uCreds, local.credentials("slug1"))
    }
}
