package com.vortx.android.downloads

import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import com.vortx.android.model.PlaybackContext
import java.io.File
import java.nio.file.Files
import java.util.ArrayDeque
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadWatchedReclaimTest {

    @Test
    fun `selector requires one completed row and every immutable media field`() {
        val expected = record(id = ID_A)
        val adjacentEpisode = expected.copy(id = ID_B, videoId = "tt123:1:2", episode = 2)
        val duplicate = expected.copy(id = ID_B)
        val request = requestFor(expected)

        assertEquals(
            expected,
            DownloadWatchedReclaimPolicy.matchingCompletedRecord(
                enabled = true,
                request = request,
                records = listOf(expected, adjacentEpisode),
                hasMatchingManagedFile = { it.id == ID_A },
            ),
        )
        assertNull(
            DownloadWatchedReclaimPolicy.matchingCompletedRecord(
                enabled = true,
                request = request,
                records = listOf(expected.copy(name = "Different title")),
                hasMatchingManagedFile = { true },
            ),
        )
        assertNull(
            DownloadWatchedReclaimPolicy.matchingCompletedRecord(
                enabled = true,
                request = request,
                records = listOf(expected, duplicate),
                hasMatchingManagedFile = { true },
            ),
        )
        assertNull(
            DownloadWatchedReclaimPolicy.matchingCompletedRecord(
                enabled = false,
                request = request,
                records = listOf(expected),
                hasMatchingManagedFile = { true },
            ),
        )
    }

    @Test
    fun `late reclaim must retain the exact captured completed row`() {
        val captured = record(id = ID_A)

        assertTrue(DownloadWatchedReclaimPolicy.matchesCapturedCompletedRecord(captured, captured))
        assertFalse(
            DownloadWatchedReclaimPolicy.matchesCapturedCompletedRecord(
                captured,
                captured.copy(localFilename = "$ID_A.mp4"),
            ),
        )
        assertFalse(
            DownloadWatchedReclaimPolicy.matchesCapturedCompletedRecord(
                captured,
                captured.copy(state = DownloadState.PAUSED),
            ),
        )
    }

    @Test
    fun `rename failure preserves media and never writes the index`() = withFiles { media, tombstone, part ->
        val files = FakeFileOps(media, part, renameResults = listOf(false))
        var writes = 0

        val result = DownloadReclaimTransaction(files).reclaim(media, tombstone, part) { writes++; true }

        assertEquals(DownloadReclaimTransaction.Result.FILE_RENAME_FAILED, result)
        assertTrue(files.exists(media))
        assertFalse(files.exists(tombstone))
        assertEquals(0, writes)
    }

    @Test
    fun `index write failure rolls media back and retains index row`() = withFiles { media, tombstone, part ->
        val files = FakeFileOps(media, part, renameResults = listOf(true, true))
        var writes = 0

        val result = DownloadReclaimTransaction(files).reclaim(media, tombstone, part) { writes++; false }

        assertEquals(DownloadReclaimTransaction.Result.INDEX_WRITE_FAILED_ROLLED_BACK, result)
        assertEquals(1, writes)
        assertTrue(files.exists(media))
        assertFalse(files.exists(tombstone))
        assertTrue(files.exists(part))
    }

    @Test
    fun `failed rollback survives crash as tombstone and restart restores live index row`() = withFiles { media, tombstone, part ->
        val files = FakeFileOps(media, part, renameResults = listOf(true, false, true))
        val transaction = DownloadReclaimTransaction(files)

        val result = transaction.reclaim(media, tombstone, part) { false }

        assertEquals(DownloadReclaimTransaction.Result.INDEX_WRITE_FAILED_RECOVERY_REQUIRED, result)
        assertFalse(files.exists(media))
        assertTrue(files.exists(tombstone))
        assertTrue(transaction.recoverTombstone(media, tombstone, indexStillHasRecord = true))
        assertTrue(files.exists(media))
        assertFalse(files.exists(tombstone))
        assertTrue(files.exists(part))
    }

    @Test
    fun `committed removal leaves only bounded tombstone and part cleanup`() = withFiles { media, tombstone, part ->
        val unrelated = File(media.parentFile, "outside-user-file.mkv")
        val files = FakeFileOps(media, part, unrelated, renameResults = listOf(true))

        val result = DownloadReclaimTransaction(files).reclaim(media, tombstone, part) { true }

        assertEquals(DownloadReclaimTransaction.Result.RECLAIMED, result)
        assertFalse(files.exists(media))
        assertFalse(files.exists(tombstone))
        assertFalse(files.exists(part))
        assertTrue("the reclaim transaction may never touch an unrelated path", files.exists(unrelated))
    }

    @Test
    fun `restart after committed index removal deletes tombstone instead of restoring a row`() = withFiles { media, tombstone, part ->
        val files = FakeFileOps(tombstone)
        val transaction = DownloadReclaimTransaction(files)

        assertTrue(transaction.recoverTombstone(media, tombstone, indexStillHasRecord = false))
        assertFalse(files.exists(tombstone))
        assertFalse(files.exists(media))
    }

    private fun record(
        id: String,
        videoId: String = "tt123:1:1",
        episode: Int? = 1,
    ) = DownloadRecord(
        id = id,
        contentId = "tt123",
        videoId = videoId,
        type = "series",
        name = "Show",
        season = 1,
        episode = episode,
        localFilename = "$id.mkv",
        remoteURL = "https://example.invalid/media.mkv",
        state = DownloadState.COMPLETED,
    )

    private fun requestFor(record: DownloadRecord) = WatchedDownloadReclaimRequest(
        owner = PlaybackContext.Owner(profileId = "profile-a", usesEngineHistory = false),
        contentId = record.contentId,
        videoId = record.videoId,
        type = record.type,
        title = record.name,
        season = record.season,
        episode = record.episode,
        localFileUri = "file:/managed/${record.localFilename}",
    )

    private fun withFiles(block: (media: File, tombstone: File, part: File) -> Unit) {
        val directory = Files.createTempDirectory("vortx-download-reclaim").toFile()
        val media = File(directory, "$ID_A.mkv")
        val tombstone = File(directory, "$ID_A.mkv.reclaiming")
        val part = File(directory, "$ID_A.mkv.part")
        block(media, tombstone, part)
    }

    private class FakeFileOps(
        vararg initial: File,
        renameResults: List<Boolean> = emptyList(),
    ) : DownloadReclaimTransaction.FileOps {
        private val existing = initial.mapTo(mutableSetOf()) { it.absoluteFile }
        private val plannedRenameResults = ArrayDeque(renameResults)

        override fun exists(file: File): Boolean = file.absoluteFile in existing
        override fun isFile(file: File): Boolean = exists(file)
        override fun rename(source: File, destination: File): Boolean {
            val allowed = if (plannedRenameResults.isEmpty()) true else plannedRenameResults.removeFirst()
            if (!allowed || !exists(source) || exists(destination)) return false
            existing.remove(source.absoluteFile)
            existing.add(destination.absoluteFile)
            return true
        }

        override fun delete(file: File): Boolean = existing.remove(file.absoluteFile)
    }

    private companion object {
        const val ID_A = "11111111-1111-1111-1111-111111111111"
        const val ID_B = "22222222-2222-2222-2222-222222222222"
    }
}
