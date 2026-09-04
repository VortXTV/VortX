package com.vortx.android.usenet

import java.io.File

/** Bounded local-title cache. Completed titles are least-recently-used eviction candidates on the next play. */
internal object UsenetCachePolicy {
    const val MAX_CACHE_BYTES = 20L * 1024 * 1024 * 1024

    fun reserve(home: File, incomingBytes: Long, maxBytes: Long = MAX_CACHE_BYTES): Boolean {
        if (incomingBytes !in 1..maxBytes) return false
        if (!home.exists() && !home.mkdirs()) return false
        var used = home.listFiles()?.filter(File::isFile)?.sumOf(File::length) ?: 0L
        home.listFiles()?.filter(File::isFile)?.sortedBy(File::lastModified)?.forEach { stale ->
            if (used + incomingBytes <= maxBytes) return@forEach
            val staleBytes = stale.length()
            if (stale.delete()) used -= staleBytes
        }
        return used + incomingBytes <= maxBytes
    }
}
