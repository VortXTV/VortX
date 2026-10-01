package com.vortx.android.usenet

import java.io.File

/** Process-wide atomic cache ledger. In-flight outputs reserve declared bytes and are never evicted. */
internal object UsenetCachePolicy {
    const val MAX_CACHE_BYTES = 20L * 1024 * 1024 * 1024
    private val active = linkedMapOf<String, Long>()

    class Allocation internal constructor(
        val file: File,
        internal val home: File,
        internal val maxBytes: Long,
    ) {
        /** Upgrade the NZB estimate to the first yEnc part's authoritative total before any bytes commit. */
        fun resize(authoritativeBytes: Long): Boolean = UsenetCachePolicy.resize(this, authoritativeBytes)
        fun complete() = Unit // still leased by the active loopback/player session
        fun abandon() = synchronized(UsenetCachePolicy) { active.remove(file.absolutePath) }
    }

    fun allocate(home: File, filename: String, incomingBytes: Long, maxBytes: Long = MAX_CACHE_BYTES): Allocation? = synchronized(this) {
        if (incomingBytes !in 1..maxBytes || (!home.exists() && !home.mkdirs())) return null
        val target = File(home, filename)
        var used = (home.listFiles() ?: emptyArray())
            .filter { it.isFile && it.absolutePath !in active }.sumOf(File::length) +
            active.filterKeys { it.startsWith(home.absolutePath + File.separator) }.values.sum()
        (home.listFiles() ?: emptyArray()).filter { it.isFile && it.absolutePath !in active }
            .sortedBy(File::lastModified).forEach { stale ->
                if (used + incomingBytes > maxBytes) {
                    val bytes = stale.length()
                    if (stale.delete()) used -= bytes
                }
            }
        if (used + incomingBytes > maxBytes) null else Allocation(target, home, maxBytes).also { active[target.absolutePath] = incomingBytes }
    }

    private fun resize(allocation: Allocation, incomingBytes: Long): Boolean = synchronized(this) {
        if (incomingBytes !in 1..allocation.maxBytes) return@synchronized false
        val current = active[allocation.file.absolutePath] ?: return@synchronized false
        var used = (allocation.home.listFiles() ?: emptyArray())
            .filter { it.isFile && it.absolutePath !in active }.sumOf(File::length) + active.values.sum()
        (allocation.home.listFiles() ?: emptyArray()).filter { it.isFile && it.absolutePath !in active }
            .sortedBy(File::lastModified).forEach { stale ->
                if (used - current + incomingBytes > allocation.maxBytes) {
                    val bytes = stale.length()
                    if (stale.delete()) used -= bytes
                }
            }
        if (used - current + incomingBytes > allocation.maxBytes) false else {
            active[allocation.file.absolutePath] = incomingBytes
            true
        }
    }
}
