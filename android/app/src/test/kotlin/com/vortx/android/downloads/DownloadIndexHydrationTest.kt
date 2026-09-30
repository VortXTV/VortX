package com.vortx.android.downloads

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import org.json.JSONArray
import org.junit.Assert.assertEquals
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

    private fun inTemporaryDirectory(block: (File) -> Unit) {
        val directory = Files.createTempDirectory("vortx-download-index").toFile()
        block(directory)
    }
}
