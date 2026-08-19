package com.vortx.android.player

import android.app.ActivityManager
import android.content.Context
import java.io.File

/**
 * Maps this device's PHYSICAL RAM to a safe forward-buffer budget (in MB), so both engines can size the
 * player's read-ahead to the hardware instead of a single one-size cap. A phone with 2 GB and a TV box
 * with 8 GB should not carry the same buffer: the small device needs a tight budget to stay clear of
 * jetsam, and the large device can hold a big buffer so a variable-bitrate 4K peak never starves.
 *
 * The ladder (total RAM to safe buffer MB) is:
 *   <= 1 GB   -> 150
 *   <= 1.5 GB -> 200
 *   <= 2 GB   -> 250
 *   <= 3 GB   -> 500
 *   <= 4 GB   -> 1000
 *   <= 6 GB   -> 1600
 *   else      -> 2000
 *
 * Boundaries are round GB values compared with `<=`, which is deliberate: [ActivityManager.MemoryInfo
 * .totalMem] reports slightly LESS than the nominal amount (the kernel reserves some), so a nominally
 * 2 GB device reports about 1.9 GB and still lands on the 2 GB rung, a 4 GB device about 3.7 GB on the
 * 4 GB rung, and so on.
 *
 * FAIL-SOFT: total RAM is read once from [ActivityManager.MemoryInfo.totalMem], falling back to
 * `/proc/meminfo` and finally to a conservative 2 GB tier (250 MB) when neither can be read. The result
 * is cached because physical RAM never changes at runtime, so the read happens at most once per process.
 *
 * PURE: this object depends only on the device's RAM. It knows nothing about the disk cache or any
 * Settings toggle; a caller that also wants a free-disk clamp composes it at the call site (see the mpv
 * player's remote read-ahead), keeping the RAM tier a single, testable source of truth.
 */
object DeviceMemoryTier {

    private const val BYTES_PER_GB: Long = 1024L * 1024 * 1024

    /** The buffer budget used when RAM cannot be read at all (the 2 GB tier). */
    const val FALLBACK_BUFFER_MB: Int = 250

    /** The total-RAM value assumed when neither source can be read (2 GB, so the ladder returns 250 MB). */
    private const val FALLBACK_TOTAL_BYTES: Long = 2L * BYTES_PER_GB

    /**
     * The warning ceiling is 1.5x the safe budget: the safe budget is the target the player buffers to,
     * and a live buffer that climbs past this ceiling is eating into headroom the OS needs, so a caller
     * that tracks real buffer size can log or degrade at this line. Kept as a multiple of the safe budget
     * so the ceiling scales with the RAM tier automatically.
     */
    private const val WARNING_CEILING_NUMERATOR: Int = 3
    private const val WARNING_CEILING_DENOMINATOR: Int = 2

    @Volatile
    private var cachedTotalBytes: Long = 0L

    /** Safe forward-buffer budget in MB for this device's RAM tier. Computed once, then cached. */
    fun safeBufferMb(context: Context): Int = bufferMbForTotalBytes(totalRamBytes(context))

    /** The buffer size (MB) above which a live buffer is into OS headroom. See [WARNING_CEILING_NUMERATOR]. */
    fun warningCeilingMb(context: Context): Int = warningCeilingForBufferMb(safeBufferMb(context))

    /** Total physical RAM in bytes, read from the platform once and cached (0 means "not read yet"). */
    private fun totalRamBytes(context: Context): Long {
        val cached = cachedTotalBytes
        if (cached > 0L) return cached
        val resolved = readTotalRamBytes(context).takeIf { it > 0L } ?: FALLBACK_TOTAL_BYTES
        cachedTotalBytes = resolved
        return resolved
    }

    /** Primary source: [ActivityManager.MemoryInfo.totalMem]; fallback: `/proc/meminfo`. Never throws. */
    private fun readTotalRamBytes(context: Context): Long {
        val fromActivityManager = runCatching {
            val am = context.applicationContext
                .getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return@runCatching 0L
            val info = ActivityManager.MemoryInfo()
            am.getMemoryInfo(info)
            info.totalMem
        }.getOrDefault(0L)
        if (fromActivityManager > 0L) return fromActivityManager
        return readProcMemInfoBytes()
    }

    /** Parse `MemTotal` (kB) out of `/proc/meminfo` and return it in bytes, or 0 if unreadable. */
    private fun readProcMemInfoBytes(): Long = runCatching {
        File("/proc/meminfo").useLines { lines ->
            for (line in lines) {
                if (line.startsWith("MemTotal:")) {
                    val kb = line.filter { it.isDigit() }.toLongOrNull() ?: return@useLines 0L
                    return@runCatching kb * 1024L
                }
            }
            0L
        }
    }.getOrDefault(0L)

    /**
     * The pure ladder: total physical RAM (bytes) to a safe forward-buffer budget (MB). Internal so the
     * ladder can be unit-tested without an Android [Context]. A non-positive input returns the fallback.
     */
    internal fun bufferMbForTotalBytes(totalBytes: Long): Int = when {
        totalBytes <= 0L -> FALLBACK_BUFFER_MB
        totalBytes <= 1L * BYTES_PER_GB -> 150
        totalBytes <= 3L * BYTES_PER_GB / 2 -> 200 // 1.5 GB
        totalBytes <= 2L * BYTES_PER_GB -> 250
        totalBytes <= 3L * BYTES_PER_GB -> 500
        totalBytes <= 4L * BYTES_PER_GB -> 1000
        totalBytes <= 6L * BYTES_PER_GB -> 1600
        else -> 2000
    }

    /** The pure warning-ceiling derivation, internal so it can be unit-tested directly. */
    internal fun warningCeilingForBufferMb(bufferMb: Int): Int =
        bufferMb * WARNING_CEILING_NUMERATOR / WARNING_CEILING_DENOMINATOR
}
