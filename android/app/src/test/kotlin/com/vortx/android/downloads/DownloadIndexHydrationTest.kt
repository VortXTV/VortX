package com.vortx.android.downloads

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadIndexHydrationTest {

    @Test
    fun `missing index is distinct from successfully loaded empty index`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json")

        assertEquals(
            DownloadIndexHydration.Receipt.Missing,
            DownloadIndexHydration.read(index) { it.readText() },
        )

        index.writeText("[]")
        val loaded = DownloadIndexHydration.read(index) { JSONArray(it.readText()).length() }
        assertTrue(loaded is DownloadIndexHydration.Receipt.Loaded && loaded.value == 0)
    }

    @Test
    fun `malformed atomic index is unreadable and cannot authorize artifact cleanup`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json").apply { writeText("not-json") }

        assertEquals(
            DownloadIndexHydration.Receipt.Unreadable,
            DownloadIndexHydration.readAtomically(
                indexFile = index,
                openRead = { index.inputStream() },
                decode = { JSONArray(it).length() },
            ),
        )
    }

    @Test
    fun `atomic index io failure is unreadable and cannot authorize artifact cleanup`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json").apply { writeText("[]") }

        assertEquals(
            DownloadIndexHydration.Receipt.Unreadable,
            DownloadIndexHydration.readAtomically(
                indexFile = index,
                openRead = { throw IOException("injected AtomicFile.openRead failure") },
                decode = { JSONArray(it).length() },
            ),
        )
    }

    @Test
    fun `atomic read restores a backup index instead of treating an interrupted base as empty`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json").apply { writeText("not-json") }
        val backup = File(directory, "index.json.bak").apply { writeText("[1,2]") }

        val loaded = DownloadIndexHydration.readAtomically(
            indexFile = index,
            // Mirrors AtomicFile.openRead's legacy-backup recovery without executing Android framework stubs in
            // this plain JVM test.
            openRead = {
                if (backup.exists()) Files.move(backup.toPath(), index.toPath(), StandardCopyOption.REPLACE_EXISTING)
                index.inputStream()
            },
            decode = { JSONArray(it).length() },
        )

        assertTrue(loaded is DownloadIndexHydration.Receipt.Loaded && loaded.value == 2)
        assertEquals("[1,2]", index.readText())
    }

    @Test
    fun `atomic read with no base or backup remains missing`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json")

        assertEquals(
            DownloadIndexHydration.Receipt.Missing,
            DownloadIndexHydration.readAtomically(index, openRead = { index.inputStream() }) { it },
        )
    }

    @Test
    fun `oversized atomic index is unreadable and cannot authorize artifact cleanup`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json").apply { writeBytes(ByteArray(4 * 1024 * 1024 + 1)) }

        assertEquals(
            DownloadIndexHydration.Receipt.Unreadable,
            DownloadIndexHydration.readAtomically(index, openRead = { index.inputStream() }) { it },
        )
    }

    @Test
    fun `valid JSON with an undecodable row is unreadable rather than silently shrunk`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json").apply {
            writeText(JSONArray().put(validRow()).put(JSONObject().put("id", "   ")).toString())
        }

        assertEquals(
            DownloadIndexHydration.Receipt.Unreadable,
            readAtomicRecords(index),
        )
    }

    @Test
    fun `valid JSON with duplicate record ids is unreadable rather than silently coalesced`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json").apply {
            writeText(JSONArray().put(validRow()).put(validRow()).toString())
        }

        assertEquals(
            DownloadIndexHydration.Receipt.Unreadable,
            readAtomicRecords(index),
        )
    }

    @Test
    fun `complete legacy schema row remains decodable with absent newer fields`() {
        val legacy = DownloadStore.decodeIndexRecords(JSONArray().put(validRow()).toString()).single()

        assertEquals(ID_A, legacy.id)
        assertNull(legacy.isDolbyVision)
        assertNull(legacy.isAtmos)
        assertNull(legacy.transferGeneration)
    }

    @Test
    fun `missing or invalid canonical fields make index unreadable and preserve reclaim artifact`() {
        val badRows = listOf<(JSONObject) -> Unit>(
            { it.remove("localFilename") },
            { it.put("localFilename", "$ID_B.mkv") },
            { it.put("localFilename", "$ID_A.txt") },
            { it.remove("state") },
            { it.put("state", "finished") },
            { it.remove("contentId") },
            { it.remove("videoId") },
            { it.remove("name") },
            { it.remove("remoteURL") },
            { it.put("type", "other") },
        )

        badRows.forEach { corrupt -> inTemporaryDirectory { directory ->
            val index = File(directory, "index.json")
            val tombstone = File(directory, "$ID_A.mkv.reclaiming").apply { writeText("recoverable bytes") }
            val row = validRow().also(corrupt)
            index.writeText(JSONArray().put(row).toString())

            val receipt = readAtomicRecords(index)

            assertEquals(DownloadIndexHydration.Receipt.Unreadable, receipt)
            assertFalse(DownloadIndexHydration.authorizesArtifactRecovery(receipt))
            assertTrue("an unreadable index must retain the only recoverable media copy", tombstone.isFile)
        } }
    }

    private fun readAtomicRecords(index: File): DownloadIndexHydration.Receipt<List<com.vortx.android.model.DownloadRecord>> =
        DownloadIndexHydration.readAtomically(
            indexFile = index,
            openRead = { index.inputStream() },
            decode = DownloadStore::decodeIndexRecords,
        )

    private fun validRow(id: String = ID_A): JSONObject = JSONObject().apply {
        put("id", id)
        put("contentId", "content-$id")
        put("videoId", "video-$id")
        put("type", "movie")
        put("name", "Title $id")
        put("remoteURL", "https://example.invalid/$id.mp4")
        put("localFilename", "$id.mp4")
        put("state", "completed")
    }

    private fun inTemporaryDirectory(block: (File) -> Unit) {
        val directory = Files.createTempDirectory("vortx-download-index").toFile()
        block(directory)
    }

    private companion object {
        const val ID_A = "11111111-1111-1111-1111-111111111111"
        const val ID_B = "22222222-2222-2222-2222-222222222222"
    }
}
