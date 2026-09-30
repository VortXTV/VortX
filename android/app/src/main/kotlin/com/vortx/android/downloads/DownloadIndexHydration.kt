package com.vortx.android.downloads

import java.io.File
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream

/**
 * Carries whether an index was actually decoded. Empty records are trustworthy only after [Loaded]; an absent,
 * unreadable, or malformed index must never authorize cleanup of recoverable media artifacts.
 */
internal object DownloadIndexHydration {
    private const val MAX_INDEX_BYTES = 4 * 1024 * 1024

    sealed class Receipt<out T> {
        data object Missing : Receipt<Nothing>()
        data object Unreadable : Receipt<Nothing>()
        data class Loaded<T>(val value: T) : Receipt<T>()
    }

    fun <T> read(indexFile: File, readAndDecode: (File) -> T): Receipt<T> {
        if (!indexFile.exists()) return Receipt.Missing
        if (!indexFile.isFile) return Receipt.Unreadable
        return runCatching { Receipt.Loaded(readAndDecode(indexFile)) }
            .getOrElse { Receipt.Unreadable }
    }

    /**
     * Reads through an [android.util.AtomicFile] opener. A legacy `.bak` is part of the durable index state: its
     * presence is not "missing", and [android.util.AtomicFile.openRead] restores it before decoding the last good
     * bytes. A leftover `.new` is intentionally not accepted as a commit.
     */
    fun <T> readAtomically(
        indexFile: File,
        openRead: () -> InputStream,
        decode: (String) -> T,
    ): Receipt<T> {
        val backup = File(indexFile.parentFile, "${indexFile.name}.bak")
        if (!indexFile.exists() && !backup.exists()) return Receipt.Missing
        return try {
            openRead().use { input -> Receipt.Loaded(decode(readUtf8Bounded(input))) }
        } catch (_: FileNotFoundException) {
            // The existence check raced a removal or AtomicFile could not restore its backup. Never mistake that
            // ambiguous condition for a successfully loaded empty index.
            Receipt.Unreadable
        } catch (_: IOException) {
            Receipt.Unreadable
        } catch (_: RuntimeException) {
            Receipt.Unreadable
        }
    }

    private fun readUtf8Bounded(input: InputStream): String {
        val bytes = ByteArrayOutputStream()
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (bytes.size() + count > MAX_INDEX_BYTES) {
                throw IOException("Download index exceeds $MAX_INDEX_BYTES bytes")
            }
            bytes.write(buffer, 0, count)
        }
        return bytes.toByteArray().toString(Charsets.UTF_8)
    }
}
