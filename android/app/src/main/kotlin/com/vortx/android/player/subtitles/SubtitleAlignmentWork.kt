package com.vortx.android.player.subtitles

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.UUID

/** One bounded CPU query at a time across both Android engines. No owner monitor crosses this work. */
internal object SubtitleAlignmentWork {
    private val queryLane = Mutex()

    suspend fun align(bytes: ByteArray, reference: List<SubtitleReferenceQuery.Timing>): SubtitleReferenceQuery.Aligned? =
        withContext(Dispatchers.Default) {
            queryLane.withLock {
                currentCoroutineContext().ensureActive()
                val prepared = SubtitleReferenceQuery.align(bytes, reference, UUID.randomUUID().toString())
                currentCoroutineContext().ensureActive()
                prepared
            }
        }
}

/**
 * Immutable owned copy used by the raw fallback and the alignment query. Reading an arbitrary cache
 * path again after I/O would not bind the native visible primary to the bytes that were scored.
 * The host retains this exact file through the player lifetime and deletes only its own files.
 */
internal class SubtitleAlignmentFile private constructor(val file: File, bytes: ByteArray) {
    private val ownedBytes = bytes.copyOf()
    val bytes: ByteArray get() = ownedBytes.copyOf()
    companion object {
        const val MAX_BYTES = 1024 * 1024

        fun freeze(input: InputStream, cacheDirectory: File): SubtitleAlignmentFile? {
            val bytes = readBounded(input) ?: return null
            if (bytes.isEmpty()) return null
            val target = File.createTempFile("vortx-sub-align-", ".srt", cacheDirectory)
            var complete = false
            try {
                FileOutputStream(target).use { output -> output.write(bytes) }
                if (!target.setReadOnly()) return null
                complete = true
                return SubtitleAlignmentFile(target, bytes)
            } finally {
                if (!complete) target.delete()
            }
        }

        /** Read at most MAX_BYTES+1. Never trust a remote/file length as a body-size certificate. */
        fun readBounded(input: InputStream): ByteArray? {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var remaining = MAX_BYTES + 1
            while (remaining > 0) {
                val count = input.read(buffer, 0, minOf(buffer.size, remaining))
                if (count < 0) break
                if (count == 0) return null
                output.write(buffer, 0, count)
                remaining -= count
            }
            return output.toByteArray().takeIf { it.size <= MAX_BYTES }
        }
    }
}
