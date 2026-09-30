package com.vortx.android.downloads

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class DownloadDirectoryPolicyTest {

    @Test
    fun `direct Downloads child is anchored under canonical app files directory`() = inTemporaryDirectory { filesDir ->
        val downloads = File(filesDir, "Downloads").apply { mkdir() }

        assertEquals(downloads.canonicalFile, DownloadDirectoryPolicy.trustedDownloadsDirectory(filesDir))
    }

    @Test
    fun `Downloads root symlink is rejected instead of authorizing its descendants`() = inTemporaryDirectory { filesDir ->
        inTemporaryDirectory { outside ->
            Files.createSymbolicLink(File(filesDir, "Downloads").toPath(), outside.toPath())

            try {
                DownloadDirectoryPolicy.trustedDownloadsDirectory(filesDir)
                fail("A redirected Downloads root must fail closed")
            } catch (_: java.io.IOException) {
                // Expected: the media/index root itself is an alias, before any child is considered.
            }
        }
    }

    @Test
    fun `Downloads root file is rejected`() = inTemporaryDirectory { filesDir ->
        File(filesDir, "Downloads").writeText("not a directory")

        try {
            DownloadDirectoryPolicy.trustedDownloadsDirectory(filesDir)
            fail("A file must never become the managed downloads root")
        } catch (_: java.io.IOException) {
            // Expected.
        }
    }

    private fun inTemporaryDirectory(block: (File) -> Unit) {
        block(Files.createTempDirectory("vortx-downloads-root").toFile())
    }
}
