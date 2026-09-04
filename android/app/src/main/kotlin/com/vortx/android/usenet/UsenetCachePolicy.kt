package com.vortx.android.usenet

import java.io.File

/** Process-wide atomic cache ledger. In-flight outputs reserve declared bytes and are never evicted. */
internal object UsenetCachePolicy {
    const val MAX_CACHE_BYTES = 20L * 1024 * 1024 * 1024
    private val active = linkedMapOf<String, Long>()

    data class Allocation(val file: File) {
        fun complete() = synchronized(UsenetCachePolicy) { active.remove(file.absolutePath) }
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
        if (used + incomingBytes > maxBytes) null else Allocation(target).also { active[target.absolutePath] = incomingBytes }
    }
}
