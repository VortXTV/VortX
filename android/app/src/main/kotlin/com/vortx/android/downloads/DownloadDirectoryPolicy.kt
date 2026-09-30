package com.vortx.android.downloads

import java.io.File
import java.io.IOException

/**
 * Resolves the one directory the download store is allowed to own. Canonicalising only its children is
 * insufficient: a `Downloads` symlink would otherwise make a valid child filename resolve outside app storage.
 */
internal object DownloadDirectoryPolicy {
    private const val DIRECTORY_NAME = "Downloads"

    /**
     * Returns the exact direct child of canonical [filesDir], or fails closed when the configured child is an alias,
     * symlink, file, or otherwise redirected path. [filesDir] itself may be a platform-provided alias; the policy
     * deliberately anchors the managed child below its canonical location.
     */
    @Throws(IOException::class)
    fun trustedDownloadsDirectory(filesDir: File): File {
        val canonicalFilesDir = filesDir.canonicalFile
        if (!canonicalFilesDir.isDirectory) {
            throw IOException("App files directory is not a directory: ${canonicalFilesDir.absolutePath}")
        }
        val expected = File(canonicalFilesDir, DIRECTORY_NAME)
        val configured = File(filesDir, DIRECTORY_NAME)
        val configuredCanonical = configured.canonicalFile
        if (configuredCanonical != expected || configuredCanonical.parentFile != canonicalFilesDir) {
            throw IOException("Downloads directory is redirected outside app files storage")
        }
        if (expected.exists() && !expected.isDirectory) {
            throw IOException("Downloads path is not a directory: ${expected.absolutePath}")
        }
        return expected
    }
}
