package com.vortx.android.downloads

import com.vortx.android.data.DownloadSourceResolver

/** Accessed under the manager's lifecycle lock. The producer is owned by the download, never the UI. */
internal class DownloadSourceLeases {
    class Entry(var lease: AutoCloseable?, val renewal: DownloadSourceResolver?)
    private val entries = mutableMapOf<String, Entry>()

    fun adopt(id: String, lease: AutoCloseable?, renewal: DownloadSourceResolver?) {
        remove(id)
        entries[id] = Entry(lease, renewal)
    }

    fun entry(id: String): Entry? = entries[id]
    fun isCurrent(id: String): Boolean = entries[id]?.let {
        (it.lease != null || it.renewal != null) && (it.renewal?.isCurrent() != false)
    } == true

    /** Pause/terminal stops this producer but retains its exact source renewal for an explicit retry. */
    fun retire(id: String) {
        val entry = entries[id] ?: return
        val owned = entry.lease
        entry.lease = null
        runCatching { owned?.close() }
        if (entry.renewal == null) entries.remove(id)
    }

    fun remove(id: String) {
        val owned = entries.remove(id)?.lease
        runCatching { owned?.close() }
    }
}
