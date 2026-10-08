package com.vortx.android.engine

import com.vortx.android.stats.WatchRecord
import com.vortx.android.stats.WatchStats
import java.time.Instant
import org.json.JSONObject

internal data class NativeWatchStatsSnapshot(
    val owner: VortxNativeOwner,
    val records: List<WatchRecord>,
    val genres: Map<String, List<String>>,
)

/** Reads only the kernel's active-profile projections. Time is estimated from retained durations,
 * not presented as a complete accumulated playback-time ledger. No legacy disk or JNI reads.
 */
internal object NativeWatchStatsProjection {
    fun records(library: JSONObject): List<WatchRecord> {
        val items = library.getJSONArray("items").let { a -> (0 until a.length()).map(a::getJSONObject) }
        val history = library.getJSONArray("history").let { a -> (0 until a.length()).map(a::getJSONObject) }
        val contexts = library.optJSONObject("watchContexts") ?: JSONObject()
        val resumes = library.getJSONObject("resume")
        val ids = history.map { it.getString("id") }.toMutableSet()
        resumes.keys().forEach { unit -> contexts.optJSONObject(unit)?.let { ids += it.getString("metaId") } }
        return ids.sorted().mapNotNull { id ->
            if (WatchStats.isInternalID(id)) return@mapNotNull null
            val saved = items.filter { it.getString("kind") == "standard" && it.getString("id") == id }
            check(saved.size <= 1) { "Ambiguous native watch media identity" }
            val finished = history.filter { it.getString("id") == id }.distinctBy { it.optString("videoId", id) }
            val known = contexts.keys().asSequence().map { it to contexts.getJSONObject(it) }.filter { it.second.getString("metaId") == id }.toList()
            val type = saved.singleOrNull()?.getString("type") ?: if (known.any { it.second.optString("videoId", id) != id }) "series" else "movie"
            if (!WatchStats.isVODType(type)) return@mapNotNull null
            val completedUnits = finished.map { it.optString("videoId", id) }.toSet()
            val completedSeconds = finished.sumOf { entry -> contexts.optJSONObject(entry.optString("videoId", id))?.optLong("durationMs")?.div(1000.0) ?: 0.0 }
            val partial = known.filter { it.first !in completedUnits }.mapNotNull { (unit, _) -> resumes.optJSONObject(unit) }
            val seconds = completedSeconds + partial.sumOf { it.getLong("offsetSecs").toDouble() }
            if (seconds == 0.0 && finished.isEmpty()) return@mapNotNull null
            val timestamp = (finished.map { it.getLong("watchedAt") } + partial.map { it.getLong("updatedAt") }).maxOrNull() ?: 0
            val latest = known.maxByOrNull { it.second.getLong("updatedAt") }?.second
            WatchRecord(id, type, saved.singleOrNull()?.getString("name") ?: latest?.optString("name", id) ?: id,
                saved.singleOrNull()?.let { if (it.has("poster") && !it.isNull("poster")) it.getString("poster") else null },
                WatchStats.clampSeconds(seconds), WatchStats.clampPlayCount(finished.size),
                if (timestamp > 0) Instant.ofEpochSecond(timestamp) else null)
        }
    }
}
