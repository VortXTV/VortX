package com.vortx.android.mediaserver

import com.vortx.android.ui.screens.MediaServerRetryIdentities
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaServerPersistenceBehaviorTest {

    @Test
    fun `remove publishes pending id before clearing token and then removes the journal`() {
        val events = mutableListOf<String>()

        val result = completeMediaServerRemoval(
            publishRemoval = {
                events += "pending"
                true
            },
            clearCredential = {
                events += "clear"
                true
            },
            finishCleanup = {
                events += "finish"
                true
            },
        )

        assertEquals(MediaServerRemovalResult.REMOVED, result)
        assertEquals(listOf("pending", "clear", "finish"), events)
    }

    @Test
    fun `remove reports unchanged when pending id cannot commit and does not clear token`() {
        val events = mutableListOf<String>()

        val result = completeMediaServerRemoval(
            publishRemoval = {
                events += "pending"
                false
            },
            clearCredential = {
                events += "clear"
                true
            },
            finishCleanup = {
                events += "finish"
                true
            },
        )

        assertEquals(MediaServerRemovalResult.UNCHANGED, result)
        assertEquals(listOf("pending"), events)
    }

    @Test
    fun `remove reports cleanup pending after metadata removal when token clear fails`() {
        val events = mutableListOf<String>()

        val result = completeMediaServerRemoval(
            publishRemoval = {
                events += "pending"
                true
            },
            clearCredential = {
                events += "clear"
                false
            },
            finishCleanup = {
                events += "finish"
                true
            },
        )

        assertEquals(MediaServerRemovalResult.CLEANUP_PENDING, result)
        assertEquals(listOf("pending", "clear"), events)
    }

    @Test
    fun `restart retries pending token clears and retains every unconfirmed id`() {
        val first = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val second = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val stillActive = UUID.fromString("00000000-0000-0000-0000-000000000003")
        val events = mutableListOf<String>()

        val remaining = resumeMediaServerRemovals(
            pendingIds = linkedSetOf(first, second, stillActive),
            activeIds = setOf(stillActive),
            clearCredential = { id ->
                events += "clear:$id"
                id != second
            },
            publishPending = { ids ->
                events += "publish:${ids.joinToString()}"
                true
            },
        )

        assertEquals(setOf(second, stillActive), remaining)
        assertEquals(
            listOf(
                "clear:$first",
                "publish:${listOf(second, stillActive).joinToString()}",
                "clear:$second",
            ),
            events,
        )
    }

    @Test
    fun `restart retains pending id when journal cleanup cannot commit after token clear`() {
        val id = UUID.fromString("00000000-0000-0000-0000-000000000001")
        var clearCalls = 0

        val remaining = resumeMediaServerRemovals(
            pendingIds = setOf(id),
            activeIds = emptySet(),
            clearCredential = {
                clearCalls += 1
                true
            },
            publishPending = { false },
        )

        assertEquals(setOf(id), remaining)
        assertEquals(1, clearCalls)
    }

    @Test
    fun `provider generation fence rejects stale results and filters inactive ids`() {
        val active = UUID.fromString("00000000-0000-0000-0000-000000000001")
        val removed = UUID.fromString("00000000-0000-0000-0000-000000000002")
        val hits = listOf(hit(active), hit(removed))

        assertEquals(
            listOf(hit(active)),
            fenceMediaServerHits(
                startGeneration = 4L,
                currentGeneration = 4L,
                activeIds = setOf(active),
                hits = hits,
            ),
        )
        assertTrue(
            fenceMediaServerHits(
                startGeneration = 4L,
                currentGeneration = 5L,
                activeIds = setOf(active),
                hits = hits,
            ).isEmpty(),
        )
    }

    @Test
    fun `retry identity is stable until a successful add forgets it`() {
        var generated = 0L
        val identities = MediaServerRetryIdentities {
            generated += 1L
            UUID(0L, generated)
        }

        val first = identities.idFor("jellyfin|server|user")
        assertEquals(first, identities.idFor("jellyfin|server|user"))
        assertEquals(UUID(0L, 2L), identities.idFor("emby|server|user"))

        identities.forget("jellyfin|server|user")
        assertEquals(UUID(0L, 3L), identities.idFor("jellyfin|server|user"))
    }

    @Test
    fun `commit false poisons cached metadata and reinit keeps prior confirmed records`() {
        val prior = metadata(recordName = "Prior")
        val mutated = metadata(recordName = "Mutated")
        var preferenceCache = prior
        val durableDisk = prior
        var writeCalls = 0
        val processState = ConfirmedMediaServerMetadata(
            readPersisted = { MediaServerMetadataRead.Available(preferenceCache) },
            writePersisted = { next ->
                writeCalls += 1
                // Mirrors SharedPreferences: its process cache mutates before commit reports disk failure.
                preferenceCache = next
                false
            },
        )

        assertEquals(prior, (processState.read() as MediaServerMetadataRead.Available).snapshot)
        assertFalse(processState.publish(mutated))
        assertEquals(mutated, preferenceCache)
        assertEquals(prior, (processState.read() as MediaServerMetadataRead.Available).snapshot)

        // A defensive Repository.init in the same process reads the confirmed image, and another mutation is
        // rejected without touching the poisoned SharedPreferences cache again.
        assertEquals(prior, (processState.read() as MediaServerMetadataRead.Available).snapshot)
        assertFalse(processState.publish(metadata(recordName = "Later")))
        assertEquals(1, writeCalls)

        // A fresh process owns a fresh confirmation boundary and reloads what actually survived on disk.
        val freshProcess = ConfirmedMediaServerMetadata(
            readPersisted = { MediaServerMetadataRead.Available(durableDisk) },
            writePersisted = { true },
        )
        assertEquals(prior, (freshProcess.read() as MediaServerMetadataRead.Available).snapshot)
    }

    private fun metadata(recordName: String): MediaServerMetadataSnapshot =
        MediaServerMetadataSnapshot(
            records = listOf(
                MediaServerRecord(
                    id = UUID.fromString("00000000-0000-0000-0000-000000000010"),
                    name = recordName,
                    kind = MediaServerKind.JELLYFIN,
                    urls = listOf("https://server.example"),
                    userId = "user",
                    machineId = "machine",
                    addedAtMillis = 1L,
                    needsReauth = false,
                ),
            ),
            pendingRemovals = emptySet(),
            pendingAdds = emptyList(),
        )

    private fun hit(serverId: UUID): MediaServerHit =
        MediaServerHit(
            kind = MediaServerKind.JELLYFIN,
            itemId = "item",
            name = "Movie",
            type = "movie",
            container = "mkv",
            resolution = 1080,
            streamUrl = "https://server.example/video",
            serverId = serverId,
            serverName = "Server",
            sizeBytes = null,
            fileName = null,
        )
}
