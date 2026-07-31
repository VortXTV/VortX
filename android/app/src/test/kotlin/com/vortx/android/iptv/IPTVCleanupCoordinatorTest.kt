package com.vortx.android.iptv

import com.vortx.android.model.InstalledAddon
import com.vortx.android.security.ConditionalCredentialWrite
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IPTVCleanupCoordinatorTest {
    private val registration = IPTVRegistration(
        slug = "slug1",
        manifestUrl = "https://iptv.vortx.tv/c/slug1/manifest.json",
    )
    private val playlist = IPTVPlaylist(
        id = registration.slug,
        name = "IPTV",
        kind = IPTVKind.M3U,
        transportUrl = registration.manifestUrl,
        createdAtMillis = 1_000L,
    )
    private val credentials = IPTVCredentials(m3uUrl = "https://provider.example/list.m3u")
    private val addon = InstalledAddon(
        transportUrl = registration.manifestUrl,
        name = "IPTV",
        rawDescriptorJson = "{}",
    )

    @Test
    fun `journal rejection prevents install and reports an unconfirmed failed revoke`() = runBlocking {
        val persistence = FakePersistence().apply { rejectCleanupWrites = true }
        var installCalls = 0
        var revokeCalls = 0
        val outcome = IPTVAddCoordinator(
            store = IPTVPlaylistStore(persistence),
            installAddon = {
                installCalls += 1
                Result.success(Unit)
            },
            cleanupActions = actions(
                revoke = {
                    revokeCalls += 1
                    false
                },
            ),
        ).complete(registration, playlist, credentials)

        assertEquals(0, installCalls)
        assertEquals(1, revokeCalls)
        assertEquals(
            IPTVCleanupFailureState.UNCONFIRMED,
            (outcome as IPTVAddOutcome.Failed).cleanupState,
        )
        assertTrue(IPTVPlaylistStore(persistence).playlists().isEmpty())
    }

    @Test
    fun `journal rejection prevents install and reports a confirmed revoke truthfully`() = runBlocking {
        val persistence = FakePersistence().apply { rejectCleanupWrites = true }
        var installCalls = 0
        val outcome = IPTVAddCoordinator(
            store = IPTVPlaylistStore(persistence),
            installAddon = {
                installCalls += 1
                Result.success(Unit)
            },
            cleanupActions = actions(revoke = { true }),
        ).complete(registration, playlist, credentials)

        assertEquals(0, installCalls)
        assertEquals(
            IPTVCleanupFailureState.NONE,
            (outcome as IPTVAddOutcome.Failed).cleanupState,
        )
    }

    @Test
    fun `cancellation after registration leaves durable rollback for restart`() = runBlocking {
        val persistence = FakePersistence()
        val store = IPTVPlaylistStore(persistence)
        val coordinator = IPTVAddCoordinator(
            store = store,
            installAddon = { throw CancellationException("left screen") },
            cleanupActions = actions(),
        )

        try {
            coordinator.complete(registration, playlist, credentials)
            throw AssertionError("Expected cancellation")
        } catch (_: CancellationException) {
            Unit
        }

        assertEquals(
            listOf(
                IPTVPendingCleanup(
                    slug = registration.slug,
                    transportUrl = registration.manifestUrl,
                    origin = IPTVCleanupOrigin.ADD_ROLLBACK,
                ),
            ),
            (IPTVPlaylistStore(persistence).pendingCleanupState() as IPTVPendingCleanupRead.Available).cleanups,
        )
    }

    @Test
    fun `remove cleanup restart resumes after the last confirmed stage`() = runBlocking {
        val persistence = FakePersistence()
        val firstStore = IPTVPlaylistStore(persistence)
        assertTrue(firstStore.add(playlist, credentials))
        assertTrue(
            firstStore.beginCleanup(
                IPTVPendingCleanup(
                    slug = playlist.id,
                    transportUrl = playlist.transportUrl,
                    origin = IPTVCleanupOrigin.REMOVE,
                ),
            ),
        )
        var removeFails = true
        var removeCalls = 0
        var revokeCalls = 0
        val first = IPTVCleanupCoordinator(
            firstStore,
            actions(
                removeAddon = {
                    removeCalls += 1
                    if (removeFails) Result.failure(IllegalStateException("engine busy")) else Result.success(Unit)
                },
                revoke = {
                    revokeCalls += 1
                    true
                },
            ),
        )

        assertFalse(first.resume(playlist.id))
        val staged =
            (IPTVPlaylistStore(persistence).pendingCleanupState() as IPTVPendingCleanupRead.Available).cleanups.single()
        assertTrue(staged.localRemoved)
        assertFalse(staged.addonRemoved)
        assertFalse(staged.workerRevoked)
        assertTrue(IPTVPlaylistStore(persistence).playlists().isEmpty())

        removeFails = false
        val restarted = IPTVCleanupCoordinator(
            IPTVPlaylistStore(persistence),
            actions(
                removeAddon = {
                    removeCalls += 1
                    Result.success(Unit)
                },
                revoke = {
                    revokeCalls += 1
                    true
                },
            ),
        )
        assertTrue(restarted.resume(playlist.id))
        assertEquals(2, removeCalls)
        assertEquals(1, revokeCalls)
        assertEquals(IPTVPendingCleanupRead.Absent, IPTVPlaylistStore(persistence).pendingCleanupState())
    }

    @Test
    fun `restart after failed revoke does not repeat confirmed local or addon removal`() = runBlocking {
        val persistence = FakePersistence()
        val store = IPTVPlaylistStore(persistence)
        assertTrue(store.add(playlist, credentials))
        assertTrue(
            store.beginCleanup(
                IPTVPendingCleanup(
                    slug = playlist.id,
                    transportUrl = playlist.transportUrl,
                    origin = IPTVCleanupOrigin.REMOVE,
                ),
            ),
        )
        var removeCalls = 0
        var revokeCalls = 0
        val first = IPTVCleanupCoordinator(
            store,
            actions(
                removeAddon = {
                    removeCalls += 1
                    Result.success(Unit)
                },
                revoke = {
                    revokeCalls += 1
                    false
                },
            ),
        )

        assertFalse(first.resume(playlist.id))
        val staged =
            (IPTVPlaylistStore(persistence).pendingCleanupState() as IPTVPendingCleanupRead.Available).cleanups.single()
        assertTrue(staged.localRemoved)
        assertTrue(staged.addonRemoved)
        assertFalse(staged.workerRevoked)

        assertTrue(
            IPTVCleanupCoordinator(
                IPTVPlaylistStore(persistence),
                actions(
                    removeAddon = {
                        removeCalls += 1
                        Result.success(Unit)
                    },
                    revoke = {
                        revokeCalls += 1
                        true
                    },
                ),
            ).resume(playlist.id),
        )
        assertEquals(1, removeCalls)
        assertEquals(2, revokeCalls)
    }

    @Test
    fun `committed add journal never rolls back after restart`() = runBlocking {
        val persistence = FakePersistence().apply { rejectCleanupDelete = true }
        var removeCalls = 0
        var revokeCalls = 0
        val outcome = IPTVAddCoordinator(
            store = IPTVPlaylistStore(persistence),
            installAddon = { Result.success(Unit) },
            cleanupActions = actions(
                removeAddon = {
                    removeCalls += 1
                    Result.success(Unit)
                },
                revoke = {
                    revokeCalls += 1
                    true
                },
            ),
        ).complete(registration, playlist, credentials)

        assertTrue((outcome as IPTVAddOutcome.Added).cleanupJournalPending)
        assertEquals(
            IPTVCleanupDisposition.COMMITTED,
            (IPTVPlaylistStore(persistence).pendingCleanupState() as IPTVPendingCleanupRead.Available)
                .cleanups
                .single()
                .disposition,
        )

        persistence.rejectCleanupDelete = false
        assertTrue(
            IPTVCleanupCoordinator(
                IPTVPlaylistStore(persistence),
                actions(
                    removeAddon = {
                        removeCalls += 1
                        Result.success(Unit)
                    },
                    revoke = {
                        revokeCalls += 1
                        true
                    },
                ),
            ).resume(registration.slug),
        )
        assertEquals(0, removeCalls)
        assertEquals(0, revokeCalls)
        assertEquals(listOf(playlist), IPTVPlaylistStore(persistence).playlists())
    }

    @Test
    fun `ambiguous committed write cannot erase durable rollback and fresh process replays it`() = runBlocking {
        val seed = FakePersistence()
        val seedStore = IPTVPlaylistStore(seed)
        assertTrue(seedStore.add(playlist, credentials))
        assertTrue(
            seedStore.beginCleanup(
                IPTVPendingCleanup(
                    slug = playlist.id,
                    transportUrl = playlist.transportUrl,
                    origin = IPTVCleanupOrigin.ADD_ROLLBACK,
                ),
            ),
        )
        val prior = IPTVMetadataSnapshot(
            playlistsJson = seed.playlistsJson,
            removedJson = seed.removedJson,
            pendingCleanupJson = seed.cleanupJson,
        )
        var preferenceCache = prior
        var durableDisk = prior
        var writeCalls = 0
        val credentialDisk = seed.credentials.toMutableMap()
        val processBoundary = ConfirmedIPTVMetadata(
            readPersisted = { IPTVMetadataRead.Available(preferenceCache) },
            writePersisted = { next ->
                writeCalls += 1
                preferenceCache = next
                false
            },
        )
        val processStore = IPTVPlaylistStore(
            ConfirmedPersistence(processBoundary, credentialDisk),
        )

        assertFalse(processStore.markCleanupCommitted(playlist.id))
        assertTrue(preferenceCache.pendingCleanupJson.orEmpty().contains("\"disposition\":\"committed\""))
        assertEquals(prior, (processBoundary.read() as IPTVMetadataRead.Available).snapshot)

        var sameProcessAddonRemovals = 0
        var sameProcessRevokes = 0
        assertFalse(
            IPTVCleanupCoordinator(
                processStore,
                actions(
                    removeAddon = {
                        sameProcessAddonRemovals += 1
                        Result.success(Unit)
                    },
                    revoke = {
                        sameProcessRevokes += 1
                        true
                    },
                ),
            ).resume(playlist.id),
        )
        assertEquals(1, writeCalls)
        assertEquals(0, sameProcessAddonRemovals)
        assertEquals(0, sameProcessRevokes)
        assertEquals(prior, durableDisk)

        val freshBoundary = ConfirmedIPTVMetadata(
            readPersisted = { IPTVMetadataRead.Available(durableDisk) },
            writePersisted = { next ->
                durableDisk = next
                true
            },
        )
        val freshStore = IPTVPlaylistStore(
            ConfirmedPersistence(freshBoundary, credentialDisk),
        )
        assertEquals(
            IPTVCleanupDisposition.ROLLBACK,
            (freshStore.pendingCleanupState() as IPTVPendingCleanupRead.Available)
                .cleanups
                .single()
                .disposition,
        )

        var freshAddonRemovals = 0
        var freshRevokes = 0
        assertTrue(
            IPTVCleanupCoordinator(
                freshStore,
                actions(
                    removeAddon = {
                        freshAddonRemovals += 1
                        Result.success(Unit)
                    },
                    revoke = {
                        freshRevokes += 1
                        true
                    },
                ),
            ).resume(playlist.id),
        )
        assertEquals(1, freshAddonRemovals)
        assertEquals(1, freshRevokes)
        assertEquals(IPTVPendingCleanupRead.Absent, freshStore.pendingCleanupState())
        assertTrue(freshStore.playlists().isEmpty())
        assertTrue(credentialDisk.isEmpty())
    }

    @Test
    fun `corrupt journal blocks overwrite cleanup and add installation after restart`() = runBlocking {
        val persistence = FakePersistence().apply { cleanupJson = """[{"slug":"missing-fields"}]""" }
        val store = IPTVPlaylistStore(persistence)
        var installCalls = 0
        var revokeCalls = 0

        assertEquals(IPTVPendingCleanupRead.UnavailableOrCorrupt, store.pendingCleanupState())
        assertFalse(
            store.beginCleanup(
                IPTVPendingCleanup(
                    slug = "other",
                    transportUrl = "https://iptv.vortx.tv/c/other/manifest.json",
                    origin = IPTVCleanupOrigin.REMOVE,
                ),
            ),
        )
        val outcome = IPTVAddCoordinator(
            store = store,
            installAddon = {
                installCalls += 1
                Result.success(Unit)
            },
            cleanupActions = actions(
                revoke = {
                    revokeCalls += 1
                    true
                },
            ),
        ).complete(registration, playlist, credentials)

        assertTrue(outcome is IPTVAddOutcome.Failed)
        assertEquals(0, installCalls)
        assertEquals(1, revokeCalls)
        assertEquals("""[{"slug":"missing-fields"}]""", persistence.cleanupJson)
    }

    @Test
    fun `duplicate slug never installs or removes the prior valid playlist`() = runBlocking {
        val persistence = FakePersistence()
        val store = IPTVPlaylistStore(persistence)
        assertTrue(store.add(playlist, credentials))
        var installCalls = 0
        var revokeCalls = 0

        val outcome = IPTVAddCoordinator(
            store = store,
            installAddon = {
                installCalls += 1
                Result.success(Unit)
            },
            cleanupActions = actions(
                revoke = {
                    revokeCalls += 1
                    true
                },
            ),
        ).complete(
            registration,
            playlist.copy(name = "Replacement", createdAtMillis = 2_000L),
            IPTVCredentials(m3uUrl = "https://other.example/list.m3u"),
        )

        assertTrue(outcome is IPTVAddOutcome.Failed)
        assertEquals(0, installCalls)
        assertEquals(0, revokeCalls)
        assertEquals(listOf(playlist), IPTVPlaylistStore(persistence).playlists())
        assertEquals(credentials, IPTVPlaylistStore(persistence).credentials(playlist.id))
    }

    @Test
    fun `duplicate credential-only slug never installs revokes or overwrites the prior key`() = runBlocking {
        val priorCredential = """{"m3uURL":"https://prior.example/list.m3u"}"""
        val persistence = FakePersistence().apply {
            credentials[registration.slug] = priorCredential
        }
        var installCalls = 0
        var revokeCalls = 0

        val outcome = IPTVAddCoordinator(
            store = IPTVPlaylistStore(persistence),
            installAddon = {
                installCalls += 1
                Result.success(Unit)
            },
            cleanupActions = actions(
                revoke = {
                    revokeCalls += 1
                    true
                },
            ),
        ).complete(registration, playlist, credentials)

        assertTrue(outcome is IPTVAddOutcome.Failed)
        assertEquals(0, installCalls)
        assertEquals(0, revokeCalls)
        assertEquals(priorCredential, persistence.credentials[registration.slug])
        assertTrue(IPTVPlaylistStore(persistence).playlists().isEmpty())
    }

    @Test
    fun `metadata failure remains journaled and rollback converges after restart`() = runBlocking {
        val persistence = FakePersistence().apply { rejectMetadataWrites = true }
        var removeCalls = 0
        var revokeCalls = 0
        val firstStore = IPTVPlaylistStore(persistence)
        val outcome = IPTVAddCoordinator(
            store = firstStore,
            installAddon = { Result.success(Unit) },
            cleanupActions = actions(
                removeAddon = {
                    removeCalls += 1
                    Result.success(Unit)
                },
                revoke = {
                    revokeCalls += 1
                    true
                },
            ),
        ).complete(registration, playlist, credentials)

        assertEquals(
            IPTVCleanupFailureState.JOURNALED,
            (outcome as IPTVAddOutcome.Failed).cleanupState,
        )
        assertTrue(firstStore.playlists().isEmpty())
        assertTrue(firstStore.pendingCleanupState() is IPTVPendingCleanupRead.Available)

        persistence.rejectMetadataWrites = false
        assertTrue(
            IPTVCleanupCoordinator(
                IPTVPlaylistStore(persistence),
                actions(
                    removeAddon = {
                        removeCalls += 1
                        Result.success(Unit)
                    },
                    revoke = {
                        revokeCalls += 1
                        true
                    },
                ),
            ).resume(registration.slug),
        )
        assertEquals(1, removeCalls)
        assertEquals(1, revokeCalls)
        assertTrue(persistence.credentials.isEmpty())
        assertEquals(IPTVPendingCleanupRead.Absent, IPTVPlaylistStore(persistence).pendingCleanupState())
    }

    private fun actions(
        removeAddon: suspend (InstalledAddon) -> Result<Unit> = { Result.success(Unit) },
        revoke: suspend (String) -> Boolean = { true },
    ) = IPTVCleanupActions(
        installedAddons = { Result.success(listOf(addon)) },
        removeAddon = removeAddon,
        revoke = revoke,
    )

    private class FakePersistence : IPTVPersistence {
        var playlistsJson: String? = null
        var removedJson: String? = null
        var cleanupJson: String? = null
        val credentials = mutableMapOf<String, String>()
        var rejectCleanupWrites = false
        var rejectCleanupDelete = false
        var rejectMetadataWrites = false

        override fun readMetadata(): IPTVMetadataRead =
            IPTVMetadataRead.Available(
                IPTVMetadataSnapshot(
                    playlistsJson = playlistsJson,
                    removedJson = removedJson,
                    pendingCleanupJson = cleanupJson,
                ),
            )

        override fun writeMetadata(playlistsJson: String, removedJson: String): Boolean {
            if (rejectMetadataWrites) return false
            this.playlistsJson = playlistsJson
            this.removedJson = removedJson
            return true
        }

        override fun readCredential(slug: String): IPTVCredentialRead =
            credentials[slug]?.let { IPTVCredentialRead.Present(it) } ?: IPTVCredentialRead.Absent

        override fun writeCredential(slug: String, json: String?): Boolean {
            if (json == null) credentials.remove(slug) else credentials[slug] = json
            return true
        }

        override fun writeCredentialIfConfirmedAbsent(
            slug: String,
            json: String,
        ): ConditionalCredentialWrite {
            if (credentials.containsKey(slug)) return ConditionalCredentialWrite.ALREADY_PRESENT
            credentials[slug] = json
            return ConditionalCredentialWrite.WRITTEN
        }

        override fun writePendingCleanupJson(json: String?): Boolean {
            if (rejectCleanupWrites || (rejectCleanupDelete && json == null)) return false
            cleanupJson = json
            return true
        }
    }

    private class ConfirmedPersistence(
        private val metadata: ConfirmedIPTVMetadata,
        private val credentials: MutableMap<String, String>,
    ) : IPTVPersistence {
        private fun snapshot(): IPTVMetadataSnapshot? =
            (metadata.read() as? IPTVMetadataRead.Available)?.snapshot

        override fun readMetadata(): IPTVMetadataRead = metadata.read()

        override fun writeMetadata(playlistsJson: String, removedJson: String): Boolean {
            val current = snapshot() ?: return false
            return metadata.publish(
                current.copy(
                    playlistsJson = playlistsJson,
                    removedJson = removedJson,
                ),
            )
        }

        override fun readCredential(slug: String): IPTVCredentialRead =
            credentials[slug]?.let(IPTVCredentialRead::Present) ?: IPTVCredentialRead.Absent

        override fun writeCredential(slug: String, json: String?): Boolean {
            if (json == null) credentials.remove(slug) else credentials[slug] = json
            return true
        }

        override fun writeCredentialIfConfirmedAbsent(
            slug: String,
            json: String,
        ): ConditionalCredentialWrite {
            if (credentials.containsKey(slug)) return ConditionalCredentialWrite.ALREADY_PRESENT
            credentials[slug] = json
            return ConditionalCredentialWrite.WRITTEN
        }

        override fun writePendingCleanupJson(json: String?): Boolean {
            val current = snapshot() ?: return false
            return metadata.publish(current.copy(pendingCleanupJson = json))
        }
    }
}
