package com.vortx.android.trickplay

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.floor
import kotlin.math.max

/**
 * A per-device local trickplay cache: this device serves scrub previews from ITS OWN captured frames when the
 * shared community pool has nothing yet (the first contributor for a title, or offline). The Android port of
 * Apple `ScrubThumbnails.LocalTrickplayFrameCache`, and the second layer [TrickplaySession] documented as a
 * separate piece of work: the session shipped the community layer only, so a first-contributor got no previews
 * of their own until now.
 *
 * Two layers, exactly like Apple:
 *   - an in-memory [LruCache] of decoded thumbnails ([previewAt] reads it synchronously, so the scrubber can
 *     call it per drag frame without ever touching disk), and
 *   - an on-disk JPEG store keyed by content-key + 2s time bucket, so this device's frames survive the memory
 *     cache being evicted AND an app restart. [warm] repopulates memory from disk when a title is re-opened.
 *
 * Bounded and self-pruning: files past [TTL_MS] are dropped, and the whole store is capped at [MAX_DISK_BYTES]
 * (oldest-first eviction), so it can never grow without limit. Fail-soft throughout: any decode/IO miss simply
 * yields no preview and never breaks playback.
 */
class LocalTrickplayFrameCache(context: Context) {

    private val cacheDir: File = File(context.applicationContext.cacheDir, "trickplay-local")

    /** Bounded resident thumbnails. Sized by count; anything evicted stays on disk and re-decodes on [warm]. */
    private val memory = object : LruCache<String, Bitmap>(MEMORY_ENTRIES) {
        override fun sizeOf(key: String, value: Bitmap): Int = 1
    }

    private fun bucketFor(timeSeconds: Double): Int = max(0.0, floor(timeSeconds / BUCKET_SECONDS)).toInt()

    private fun memKey(key: String, bucket: Int): String = "$key#$bucket"

    /** Filesystem-safe base for a content key (the key is a sha1 hex today; sanitise defensively anyway). */
    private fun safeKey(key: String): String = key.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("")

    private fun diskFile(key: String, bucket: Int): File = File(cacheDir, "${safeKey(key)}_$bucket.jpg")

    /**
     * Store one captured frame for [key] at [timeSeconds]: decode it into the memory layer and write the raw
     * JPEG to disk. Runs on the caller's thread (already an IO/Default coroutine in [TrickplaySession]). A
     * decode failure stores nothing (never throws).
     */
    fun store(key: String, timeSeconds: Double, jpeg: ByteArray) {
        val bucket = bucketFor(timeSeconds)
        val bitmap = runCatching { BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) }.getOrNull() ?: return
        memory.put(memKey(key, bucket), bitmap)
        runCatching {
            if (cacheDir.exists() || cacheDir.mkdirs()) diskFile(key, bucket).writeBytes(jpeg)
        }
    }

    /**
     * The nearest AT-OR-BEFORE thumbnail for [timeSeconds] from the MEMORY layer only, or null. Synchronous
     * and allocation-light by contract (the scrubber calls it per drag frame): it never suspends or touches
     * disk. Looks back up to [MAX_LOOKBACK_BUCKETS] buckets, so a scrub between two captures still shows the
     * most recent frame. Mirrors Apple's synchronous `preview(for:time:)` fast path.
     */
    fun previewAt(key: String, timeSeconds: Double): Bitmap? {
        val target = bucketFor(timeSeconds)
        val minBucket = max(0, target - MAX_LOOKBACK_BUCKETS)
        for (bucket in target downTo minBucket) {
            memory.get(memKey(key, bucket))?.let { return it }
        }
        return null
    }

    /**
     * Repopulate the memory layer for [key] from disk, so re-opening a title the viewer has watched before
     * serves their own previews immediately (before any fresh capture). Prunes expired / over-cap files first.
     * Off the main thread; bounded to [MEMORY_ENTRIES] most-recent buckets so a long title cannot flood memory.
     */
    suspend fun warm(key: String) = withContext(Dispatchers.IO) {
        prune()
        val prefix = "${safeKey(key)}_"
        val files = cacheDir.listFiles { f -> f.name.startsWith(prefix) && f.name.endsWith(".jpg") }
            ?.sortedByDescending { bucketOf(it.name, prefix) }
            ?.take(MEMORY_ENTRIES)
            ?: return@withContext
        for (file in files) {
            val bucket = bucketOf(file.name, prefix) ?: continue
            if (memory.get(memKey(key, bucket)) != null) continue
            val bytes = runCatching { file.readBytes() }.getOrNull() ?: continue
            val bitmap = runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull() ?: continue
            memory.put(memKey(key, bucket), bitmap)
        }
    }

    /** The bucket index encoded in a `<safeKey>_<bucket>.jpg` file name, or null when it does not parse. */
    private fun bucketOf(fileName: String, prefix: String): Int? =
        fileName.removePrefix(prefix).removeSuffix(".jpg").toIntOrNull()

    /**
     * Drop expired files, then enforce the total-bytes cap by deleting oldest-first. Best-effort: any IO
     * failure leaves the store as-is rather than throwing. Mirrors Apple's disk-store TTL + size eviction.
     */
    private fun prune() {
        val files = cacheDir.listFiles()?.toList() ?: return
        val now = System.currentTimeMillis()
        val survivors = files.filter { file ->
            val expired = now - file.lastModified() > TTL_MS
            if (expired) runCatching { file.delete() }
            !expired
        }
        var total = survivors.sumOf { it.length() }
        if (total <= MAX_DISK_BYTES) return
        survivors.sortedBy { it.lastModified() }.forEach { file ->
            if (total <= MAX_DISK_BYTES) return
            total -= file.length()
            runCatching { file.delete() }
        }
    }

    companion object {
        /** Time bucket width; the same 2s granularity Apple uses so a scrub always lands a nearby frame. */
        private const val BUCKET_SECONDS = 2.0

        /** How far back [previewAt] looks for the nearest earlier frame. ~6 min at 2s/bucket (Apple's 180). */
        private const val MAX_LOOKBACK_BUCKETS = 180

        /** Resident thumbnail count. Kept modest so the cache never adds to jetsam pressure. */
        private const val MEMORY_ENTRIES = 128

        /** Files older than this are dropped on [warm]. Apple's 48h. */
        private const val TTL_MS = 48L * 3600 * 1000

        /** Whole-store byte cap; oldest files are evicted past it. */
        private const val MAX_DISK_BYTES = 256L * 1024 * 1024
    }
}
