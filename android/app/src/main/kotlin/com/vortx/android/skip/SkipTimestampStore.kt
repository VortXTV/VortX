package com.vortx.android.skip

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/// One raw remote span, stored unclamped (ms + nullable bounds) so a different rip's duration re-derives
/// the clamped segment on read instead of baking one file's runtime into the cache. Mirrors Apple
/// `StoredSpan`.
data class StoredSpan(val kind: String, val startMs: Int?, val endMs: Int?)

/// Tiny disk cache for crowd skip timestamps: hits live 14 days, misses 1 day (the databases grow, so a
/// missing title is worth re-asking tomorrow but not every single play). The Android analogue of the Apple
/// `actor SkipTimestampStore`, with the actor replaced by a [Mutex] (the parity map's "actor -> Mutex")
/// and the caches-dir file replaced by a JSON file in the app cache dir. All disk I/O runs off the main
/// thread on [Dispatchers.IO].
class SkipTimestampStore(private val file: File) {

    data class Entry(
        val fetchedAt: Long,          // epoch millis (Apple uses a `Date`; ms keeps the TTL math trivial)
        val spans: List<StoredSpan>,
        val introEstimateMs: Int? = null,
    ) {
        companion object {
            fun miss(): Entry = Entry(System.currentTimeMillis(), emptyList(), null)
        }
    }

    private val mutex = Mutex()
    private var entries: MutableMap<String, Entry>? = null

    suspend fun entry(key: String): Entry? = mutex.withLock {
        loadIfNeeded()
        val e = entries?.get(key) ?: return@withLock null
        if (System.currentTimeMillis() - e.fetchedAt >= ttl(e)) return@withLock null
        e
    }

    suspend fun store(entry: Entry, key: String) = mutex.withLock {
        loadIfNeeded()
        entries?.put(key, entry)
        persist()
    }

    suspend fun introEstimate(key: String): Int? = mutex.withLock {
        loadIfNeeded()
        entries?.get(key)?.introEstimateMs
    }

    suspend fun invalidate(key: String) = mutex.withLock {
        loadIfNeeded()
        entries?.remove(key)
        persist()
    }

    /// Hits live 14 days; misses (empty spans) 1 day. Same policy as Apple `SkipTimestampStore.ttl(for:)`,
    /// in milliseconds (Apple's are seconds).
    private fun ttl(entry: Entry): Long = if (entry.spans.isEmpty()) MISS_TTL_MS else HIT_TTL_MS

    private suspend fun loadIfNeeded() {
        if (entries != null) return
        val decoded = withContext(Dispatchers.IO) {
            runCatching {
                if (!file.exists()) return@runCatching null
                val root = JSONObject(file.readText(Charsets.UTF_8))
                val map = HashMap<String, Entry>()
                for (key in root.keys()) {
                    val obj = root.optJSONObject(key) ?: continue
                    map[key] = obj.toEntry()
                }
                map
            }.getOrNull()
        }
        // Prune rows already past their TTL on this first load, so the map (and every whole-map re-encode
        // in persist()) stops carrying expired entries forever. Mirrors Apple `loadIfNeeded`.
        val now = System.currentTimeMillis()
        entries = (decoded ?: HashMap()).filterTo(HashMap()) { now - it.value.fetchedAt < ttl(it.value) }
    }

    private suspend fun persist() {
        val snapshot = entries ?: return
        // Copy under the lock, write off the main thread.
        val root = JSONObject()
        for ((key, entry) in snapshot) root.put(key, entry.toJson())
        val text = root.toString()
        withContext(Dispatchers.IO) {
            runCatching {
                file.parentFile?.mkdirs()
                // ATOMIC write (Apple writes with `.atomic`): a plain writeText can be torn by a
                // process kill mid-write, and the next load would then discard the ENTIRE cache as
                // unparseable. Write a sibling temp file, then rename it over the target on the same
                // filesystem (atomic replace). Fall back to a direct write only if atomic move is
                // unsupported on this device's cache filesystem.
                val tmp = File(file.parentFile, "${file.name}.tmp")
                tmp.writeText(text, Charsets.UTF_8)
                runCatching {
                    Files.move(
                        tmp.toPath(),
                        file.toPath(),
                        StandardCopyOption.REPLACE_EXISTING,
                        StandardCopyOption.ATOMIC_MOVE,
                    )
                }.onFailure {
                    file.writeText(text, Charsets.UTF_8)
                    tmp.delete()
                }
            }
        }
    }

    private fun Entry.toJson(): JSONObject {
        val obj = JSONObject()
        obj.put("fetchedAt", fetchedAt)
        val arr = JSONArray()
        for (span in spans) {
            val s = JSONObject()
            s.put("kind", span.kind)
            if (span.startMs != null) s.put("startMs", span.startMs) else s.put("startMs", JSONObject.NULL)
            if (span.endMs != null) s.put("endMs", span.endMs) else s.put("endMs", JSONObject.NULL)
            arr.put(s)
        }
        obj.put("spans", arr)
        if (introEstimateMs != null) obj.put("introEstimateMs", introEstimateMs)
        return obj
    }

    private fun JSONObject.toEntry(): Entry {
        val fetchedAt = optLong("fetchedAt", 0L)
        val spansArr = optJSONArray("spans")
        val spans = mutableListOf<StoredSpan>()
        if (spansArr != null) {
            for (i in 0 until spansArr.length()) {
                val s = spansArr.optJSONObject(i) ?: continue
                spans.add(StoredSpan(kind = s.optString("kind"), startMs = s.optIntOrNull("startMs"), endMs = s.optIntOrNull("endMs")))
            }
        }
        return Entry(fetchedAt = fetchedAt, spans = spans, introEstimateMs = optIntOrNull("introEstimateMs"))
    }

    companion object {
        private const val HIT_TTL_MS = 14L * 86_400_000L
        private const val MISS_TTL_MS = 86_400_000L
    }
}

/// Like `optInt` but null (not 0) for a missing or JSON-null value, so the nullable ms bounds survive a
/// round-trip through the disk cache.
internal fun JSONObject.optIntOrNull(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    return optInt(key)
}
