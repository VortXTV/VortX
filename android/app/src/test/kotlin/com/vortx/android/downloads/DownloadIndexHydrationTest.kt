package com.vortx.android.downloads

import java.io.File
import java.io.IOException
import java.nio.file.Files
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
    fun `malformed index is unreadable and cannot authorize artifact cleanup`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json").apply { writeText("not-json") }

        assertEquals(
            DownloadIndexHydration.Receipt.Unreadable,
            DownloadIndexHydration.read(index) { JSONArray(it.readText()).length() },
        )
    }

    @Test
    fun `index io failure is unreadable and cannot authorize artifact cleanup`() = inTemporaryDirectory { directory ->
        val index = File(directory, "index.json").apply { writeText("[]") }

        assertEquals(
            DownloadIndexHydration.Receipt.Unreadable,
            DownloadIndexHydration.read(index) { throw IOException("injected read failure") },
        )
    }

    private fun inTemporaryDirectory(block: (File) -> Unit) {
        val directory = Files.createTempDirectory("vortx-download-index").toFile()
        block(directory)
    }
}
