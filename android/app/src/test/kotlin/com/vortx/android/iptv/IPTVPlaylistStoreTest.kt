package com.vortx.android.iptv

import com.vortx.android.security.ConditionalCredentialWrite
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
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
        var pendingCleanupJson: String? = null
        val creds = HashMap<String, String>()
        val events = mutableListOf<String>()
        var rejectCredentialWrites = false
        var rejectMetadataWrites = false
        var credentialBackendAvailable = true
        var rejectPendingCleanupWrites = false
        var throwOnPendingCleanupRead = false
        var journalDelayMillis = 0L
        val maxConcurrentJournalOperations = AtomicInteger()
        private val activeJournalOperations = AtomicInteger()

        override fun readMetadata(): IPTVMetadataRead = trackJournalOperation {
            if (throwOnPendingCleanupRead) error("metadata unavailable")
            IPTVMetadataRead.Available(
                IPTVMetadataSnapshot(
                    playlistsJson = playlistsJson,
                    removedJson = removedJson,
                    pendingCleanupJson = pendingCleanupJson,
                ),
            )
        }

        override fun writeMetadata(playlistsJson: String, removedJson: String): Boolean {
            events += "metadata"
            if (rejectMetadataWrites) return false
            this.playlistsJson = playlistsJson
            this.removedJson = removedJson
            return true
        }
        override fun readCredential(slug: String): IPTVCredentialRead {
            if (!credentialBackendAvailable) return IPTVCredentialRead.Unavailable
            return creds[slug]?.let { IPTVCredentialRead.Present(it) } ?: IPTVCredentialRead.Absent
        }
        override fun writeCredential(slug: String, json: String?): Boolean {
            events += if (json == null) "credential-clear:$slug" else "credential-set:$slug"
            if (rejectCredentialWrites) return false
            if (json == null) creds.remove(slug) else creds[slug] = json
            return true
        }
        override fun writeCredentialIfConfirmedAbsent(
            slug: String,
            json: String,
        ): ConditionalCredentialWrite {
            events += "credential-adopt:$slug"
            if (!credentialBackendAvailable) return ConditionalCredentialWrite.UNAVAILABLE
            if (creds.containsKey(slug)) return ConditionalCredentialWrite.ALREADY_PRESENT
            if (rejectCredentialWrites) return ConditionalCredentialWrite.REJECTED
            creds[slug] = json
            return ConditionalCredentialWrite.WRITTEN
        }
        override fun writePendingCleanupJson(json: String?): Boolean {
            return trackJournalOperation {
                events += "cleanup"
                if (rejectPendingCleanupWrites) return@trackJournalOperation false
                pendingCleanupJson = json
                true
            }
        }

        private fun <T> trackJournalOperation(block: () -> T): T {
            val active = activeJournalOperations.incrementAndGet()
            maxConcurrentJournalOperations.updateAndGet { previous -> maxOf(previous, active) }
            try {
                if (journalDelayMillis > 0L) Thread.sleep(journalDelayMillis)
                return block()
            } finally {
                activeJournalOperations.decrementAndGet()
            }
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
        val persistence = FakeIPTVPersistence()
        val store = IPTVPlaylistStore(persistence)
        assertTrue(store.add(playlist(), m3uCreds))

        assertEquals(listOf(playlist()), store.playlists())
        assertEquals(m3uCreds, store.credentials("slug1"))
        assertTrue(store.contains("https://iptv.vortx.tv/c/slug1/manifest.json"))
        assertFalse(store.contains("https://elsewhere/manifest.json"))
        assertEquals(listOf("credential-set:slug1", "metadata"), persistence.events)
    }

    @Test
    fun `credential reads distinguish present absent and unavailable`() {
        val persistence = FakeIPTVPersistence()

        assertEquals(IPTVCredentialRead.Absent, persistence.readCredential("slug1"))
        persistence.creds["slug1"] = "secret"
        assertEquals(IPTVCredentialRead.Present("secret"), persistence.readCredential("slug1"))
        persistence.credentialBackendAvailable = false
        assertEquals(IPTVCredentialRead.Unavailable, persistence.readCredential("slug1"))
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

    @Test
    fun `rejected add keeps the prior confirmed record and credential for retry`() {
        val persistence = FakeIPTVPersistence()
        val store = IPTVPlaylistStore(persistence)
        assertTrue(store.add(playlist(), m3uCreds))
        persistence.events.clear()
        persistence.rejectCredentialWrites = true

        assertFalse(
            store.add(
                playlist(name = "Replacement", createdAt = 2_000L),
                IPTVCredentials(m3uUrl = "https://replacement.example/list.m3u"),
            ),
        )

        assertEquals(listOf(playlist()), store.playlists())
        assertEquals(m3uCreds, store.credentials("slug1"))
        assertEquals(listOf("credential-set:slug1"), persistence.events)

        persistence.rejectCredentialWrites = false
        assertTrue(
            store.add(
                playlist(name = "Replacement", createdAt = 2_000L),
                IPTVCredentials(m3uUrl = "https://replacement.example/list.m3u"),
            ),
        )
        assertEquals("Replacement", store.playlists().single().name)
    }

    @Test
    fun `rejected add metadata commit restores credential and publishes nothing after restart`() {
        val persistence = FakeIPTVPersistence().apply { rejectMetadataWrites = true }
        val store = IPTVPlaylistStore(persistence)

        assertFalse(store.add(playlist(), m3uCreds))
        assertTrue(store.playlists().isEmpty())
        assertTrue(persistence.creds.isEmpty())
        assertTrue(IPTVPlaylistStore(persistence).playlists().isEmpty())
    }

    // ---- remove ----

    @Test
    fun `remove drops the record and credentials and stamps a tombstone`() {
        val persistence = FakeIPTVPersistence()
        val store = IPTVPlaylistStore(persistence)
        store.add(playlist(), m3uCreds)

        persistence.events.clear()
        assertTrue(store.remove("slug1"))
        assertTrue(store.playlists().isEmpty())
        assertNull(store.credentials("slug1"))
        assertFalse(store.contains("https://iptv.vortx.tv/c/slug1/manifest.json"))
        assertNotNull("a removal tombstone must be persisted", persistence.removedJson)
        assertTrue(persistence.removedJson!!.contains("slug1"))
        assertEquals(listOf("metadata", "credential-clear:slug1"), persistence.events)
    }

    @Test
    fun `rejected credential clear keeps durable removal state and succeeds on cleanup retry`() {
        val persistence = FakeIPTVPersistence()
        val store = IPTVPlaylistStore(persistence)
        assertTrue(store.add(playlist(), m3uCreds))
        persistence.events.clear()
        persistence.rejectCredentialWrites = true

        assertFalse(store.remove("slug1"))

        assertTrue(store.playlists().isEmpty())
        assertEquals(m3uCreds, store.credentials("slug1"))
        assertNotNull(persistence.removedJson)
        assertEquals(listOf("metadata", "credential-clear:slug1"), persistence.events)

        persistence.rejectCredentialWrites = false
        assertTrue(store.remove("slug1"))
        assertTrue(store.playlists().isEmpty())
        assertNull(store.credentials("slug1"))
    }

    @Test
    fun `rejected removal metadata commit leaves the restartable playlist and credential intact`() {
        val persistence = FakeIPTVPersistence()
        val store = IPTVPlaylistStore(persistence)
        assertTrue(store.add(playlist(), m3uCreds))
        persistence.rejectMetadataWrites = true

        assertFalse(store.remove("slug1"))

        val reopened = IPTVPlaylistStore(persistence)
        assertEquals(listOf(playlist()), reopened.playlists())
        assertEquals(m3uCreds, reopened.credentials("slug1"))
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
        assertTrue(peer.applySyncBlob(blob!!))
        assertEquals(listOf(playlist()), peer.playlists())
        // Credential adopted into the empty local slot (the leg that revives a reinstalled device).
        assertEquals(m3uCreds, peer.credentials("slug1"))
    }

    @Test
    fun `sync add waits for a confirmed credential and succeeds on retry`() {
        val source = IPTVPlaylistStore(FakeIPTVPersistence())
        source.add(playlist(), m3uCreds)
        val blob = source.syncBlob()!!

        val persistence = FakeIPTVPersistence().apply { rejectCredentialWrites = true }
        val peer = IPTVPlaylistStore(persistence)

        assertFalse(peer.applySyncBlob(blob))
        assertTrue(peer.playlists().isEmpty())
        assertNull(persistence.playlistsJson)
        assertNull(persistence.removedJson)

        persistence.rejectCredentialWrites = false
        assertTrue(peer.applySyncBlob(blob))
        assertEquals(listOf(playlist()), peer.playlists())
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
    fun `sync tombstone waits for a confirmed clear and succeeds on retry`() {
        val removedPeer = IPTVPlaylistStore(FakeIPTVPersistence())
        removedPeer.add(playlist(), m3uCreds)
        removedPeer.remove("slug1")
        val tombstoneBlob = removedPeer.syncBlob()!!

        val persistence = FakeIPTVPersistence()
        val local = IPTVPlaylistStore(persistence)
        local.add(playlist(), m3uCreds)
        val previousRemovedJson = persistence.removedJson
        persistence.events.clear()
        persistence.rejectCredentialWrites = true

        assertFalse(local.applySyncBlob(tombstoneBlob))
        assertEquals(listOf(playlist()), local.playlists())
        assertEquals(m3uCreds, local.credentials("slug1"))
        assertEquals(previousRemovedJson, persistence.removedJson)
        assertEquals(listOf("credential-clear:slug1"), persistence.events)

        persistence.rejectCredentialWrites = false
        assertTrue(local.applySyncBlob(tombstoneBlob))
        assertTrue(local.playlists().isEmpty())
        assertNull(local.credentials("slug1"))
        assertNotNull(persistence.removedJson)
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

    @Test
    fun `remote adoption waits through an unavailable backend and never overwrites recovered local credential`() {
        val source = IPTVPlaylistStore(FakeIPTVPersistence())
        source.add(playlist(), IPTVCredentials(m3uUrl = "https://remote/pl.m3u"))
        val remoteBlob = source.syncBlob()!!

        val persistence = FakeIPTVPersistence().apply {
            creds["slug1"] = """{"m3uURL":"https://local/pl.m3u"}"""
            credentialBackendAvailable = false
        }
        val local = IPTVPlaylistStore(persistence)

        assertFalse(local.applySyncBlob(remoteBlob))
        assertTrue(local.playlists().isEmpty())
        assertEquals("""{"m3uURL":"https://local/pl.m3u"}""", persistence.creds["slug1"])

        persistence.credentialBackendAvailable = true
        assertTrue(local.applySyncBlob(remoteBlob))
        assertEquals("https://local/pl.m3u", local.credentials("slug1")?.m3uUrl)
    }

    @Test
    fun `sync adoption metadata rejection restores the previously absent credential`() {
        val source = IPTVPlaylistStore(FakeIPTVPersistence())
        source.add(playlist(), m3uCreds)
        val remoteBlob = source.syncBlob()!!
        val persistence = FakeIPTVPersistence().apply { rejectMetadataWrites = true }
        val local = IPTVPlaylistStore(persistence)

        assertFalse(local.applySyncBlob(remoteBlob))
        assertTrue(persistence.creds.isEmpty())
        assertTrue(IPTVPlaylistStore(persistence).playlists().isEmpty())

        persistence.rejectMetadataWrites = false
        assertTrue(local.applySyncBlob(remoteBlob))
        assertEquals(m3uCreds, local.credentials("slug1"))
    }

    @Test
    fun `sync tombstone metadata rejection restores the prior credential and playlist`() {
        val removedPeer = IPTVPlaylistStore(FakeIPTVPersistence())
        removedPeer.add(playlist(), m3uCreds)
        removedPeer.remove("slug1")
        val tombstoneBlob = removedPeer.syncBlob()!!

        val persistence = FakeIPTVPersistence()
        val local = IPTVPlaylistStore(persistence)
        assertTrue(local.add(playlist(), m3uCreds))
        persistence.rejectMetadataWrites = true

        assertFalse(local.applySyncBlob(tombstoneBlob))
        assertEquals(m3uCreds, local.credentials("slug1"))
        assertEquals(listOf(playlist()), IPTVPlaylistStore(persistence).playlists())
    }

    @Test
    fun `pending cleanup journal survives a fresh store and advances only after confirmed writes`() {
        val persistence = FakeIPTVPersistence()
        val first = IPTVPlaylistStore(persistence)
        val pending = IPTVPendingCleanup(
            slug = "slug1",
            transportUrl = "https://iptv.vortx.tv/c/slug1/manifest.json",
            origin = IPTVCleanupOrigin.REMOVE,
        )

        assertTrue(first.beginCleanup(pending))
        val reopened = IPTVPlaylistStore(persistence)
        assertEquals(listOf(pending), (reopened.pendingCleanupState() as IPTVPendingCleanupRead.Available).cleanups)

        persistence.rejectPendingCleanupWrites = true
        assertFalse(reopened.markCleanupLocalRemoved("slug1"))
        assertFalse((reopened.pendingCleanupState() as IPTVPendingCleanupRead.Available).cleanups.single().localRemoved)

        persistence.rejectPendingCleanupWrites = false
        assertTrue(reopened.markCleanupLocalRemoved("slug1"))
        assertTrue(
            (IPTVPlaylistStore(persistence).pendingCleanupState() as IPTVPendingCleanupRead.Available)
                .cleanups
                .single()
                .localRemoved,
        )
    }

    @Test
    fun `unreadable cleanup journal is unavailable and cannot be overwritten`() {
        val persistence = FakeIPTVPersistence().apply {
            pendingCleanupJson = """[{"opaque":"preserve"}]"""
            throwOnPendingCleanupRead = true
        }
        val store = IPTVPlaylistStore(persistence)

        assertEquals(IPTVPendingCleanupRead.UnavailableOrCorrupt, store.pendingCleanupState())
        assertFalse(
            store.beginCleanup(
                IPTVPendingCleanup(
                    slug = "slug1",
                    transportUrl = "https://iptv.vortx.tv/c/slug1/manifest.json",
                    origin = IPTVCleanupOrigin.REMOVE,
                ),
            ),
        )
        assertEquals("""[{"opaque":"preserve"}]""", persistence.pendingCleanupJson)
    }

    @Test
    fun `duplicate cleanup slugs are corrupt and cannot be overwritten`() {
        val duplicate =
            """{"slug":"slug1","transportUrl":"https://iptv.vortx.tv/c/slug1/manifest.json",""" +
                """"origin":"remove","disposition":"rollback"}"""
        val persistence = FakeIPTVPersistence().apply {
            pendingCleanupJson = "[$duplicate,$duplicate]"
        }
        val store = IPTVPlaylistStore(persistence)

        assertEquals(IPTVPendingCleanupRead.UnavailableOrCorrupt, store.pendingCleanupState())
        assertFalse(
            store.beginCleanup(
                IPTVPendingCleanup(
                    slug = "slug2",
                    transportUrl = "https://iptv.vortx.tv/c/slug2/manifest.json",
                    origin = IPTVCleanupOrigin.REMOVE,
                ),
            ),
        )
        assertEquals("[$duplicate,$duplicate]", persistence.pendingCleanupJson)
    }

    @Test
    fun `concurrent cleanup journal additions serialize one compound read modify write`() {
        val persistence = FakeIPTVPersistence().apply { journalDelayMillis = 25L }
        val store = IPTVPlaylistStore(persistence)
        val start = CountDownLatch(1)
        val done = CountDownLatch(2)
        val results = Collections.synchronizedList(mutableListOf<Boolean>())

        listOf("slug1", "slug2").forEach { slug ->
            thread(name = "cleanup-$slug") {
                start.await()
                results += store.beginCleanup(
                    IPTVPendingCleanup(
                        slug = slug,
                        transportUrl = "https://iptv.vortx.tv/c/$slug/manifest.json",
                        origin = IPTVCleanupOrigin.REMOVE,
                    ),
                )
                done.countDown()
            }
        }
        start.countDown()

        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertEquals(listOf(true, true), results.sorted())
        assertEquals(1, persistence.maxConcurrentJournalOperations.get())
        assertEquals(
            setOf("slug1", "slug2"),
            (store.pendingCleanupState() as IPTVPendingCleanupRead.Available)
                .cleanups
                .mapTo(linkedSetOf()) { it.slug },
        )
    }
}
