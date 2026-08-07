package com.vortx.android.player

import android.content.Context
import com.vortx.android.model.MediaRef
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.round

/** Device-local memory of the viewer's manual subtitle timing for one title or episode. */
object SubtitleOffsetMemory {
    internal const val STORE_KEY = "vortx.subtitleOffsetMemory.v1"
    internal const val MAX_ENTRIES = 600
    internal const val MAX_ABS_SECONDS = 120.0

    private const val SETTINGS_FILE = "vortx_settings"
    private val lock = Any()

    fun savedOffset(context: Context, contentKey: String?): Double? {
        if (contentKey.isNullOrBlank()) return null
        return synchronized(lock) {
            val raw = context.applicationContext
                .getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)
                .getString(STORE_KEY, null)
            savedSubtitleOffset(raw, contentKey)
        }
    }

    fun save(context: Context, seconds: Double, contentKey: String?) {
        if (contentKey.isNullOrBlank()) return
        synchronized(lock) {
            val preferences = context.applicationContext
                .getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)
            val current = preferences.getString(STORE_KEY, null)
            val updated = mutateSubtitleOffsetJson(
                raw = current,
                contentKey = contentKey,
                seconds = seconds,
                updated = System.currentTimeMillis() / 1_000.0,
            )
            if (updated != current) preferences.edit().putString(STORE_KEY, updated).apply()
        }
    }
}

internal data class SubtitleOffsetEntry(
    val seconds: Double,
    val updated: Double,
)

/** Apple-compatible `imdb:tt...[:season:episode]` identity for subtitle timing memory. */
internal fun subtitleOffsetContentKey(ref: MediaRef?): String? {
    val raw = ref?.imdb?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
    if (raw.startsWith("tmdb:")) return null
    val imdb = Regex("tt\\d+").find(raw)?.value
        ?: Regex("\\d+").find(raw)?.value?.let { "tt$it" }
        ?: return null
    if (!ref.isSeries) return "imdb:$imdb"
    val season = ref.season ?: return null
    val episode = ref.episode ?: return null
    return "imdb:$imdb:$season:$episode"
}

internal fun savedSubtitleOffset(raw: String?, contentKey: String?): Double? {
    if (contentKey.isNullOrBlank()) return null
    val seconds = decodeSubtitleOffsets(raw)[contentKey]?.seconds ?: return null
    if (seconds == 0.0 || !seconds.isFinite() || abs(seconds) > SubtitleOffsetMemory.MAX_ABS_SECONDS) {
        return null
    }
    return round(seconds * 10.0) / 10.0
}

/** Pure read-modify-write helper used by the store and hostile JVM tests. */
internal fun mutateSubtitleOffsetJson(
    raw: String?,
    contentKey: String,
    seconds: Double,
    updated: Double,
): String {
    if (contentKey.isBlank() || !updated.isFinite()) return raw ?: "{}"
    val entries = decodeSubtitleOffsets(raw)
    val rounded = round(seconds * 10.0) / 10.0
    if (rounded == 0.0 || !rounded.isFinite() || abs(rounded) > SubtitleOffsetMemory.MAX_ABS_SECONDS) {
        entries.remove(contentKey)
    } else {
        entries[contentKey] = SubtitleOffsetEntry(seconds = rounded, updated = updated)
        val overflow = entries.size - SubtitleOffsetMemory.MAX_ENTRIES
        if (overflow > 0) {
            entries.entries
                .sortedWith(compareBy<Map.Entry<String, SubtitleOffsetEntry>> { it.value.updated }.thenBy { it.key })
                .take(overflow)
                .forEach { entries.remove(it.key) }
        }
    }
    return encodeSubtitleOffsets(entries)
}

private fun decodeSubtitleOffsets(raw: String?): MutableMap<String, SubtitleOffsetEntry> {
    if (raw.isNullOrBlank()) return linkedMapOf()
    val root = runCatching { JSONObject(raw) }.getOrNull() ?: return linkedMapOf()
    val entries = linkedMapOf<String, SubtitleOffsetEntry>()
    val keys = root.keys()
    while (keys.hasNext()) {
        val key = keys.next()
        if (key.isBlank()) continue
        val objectValue = root.optJSONObject(key) ?: continue
        val seconds = objectValue.optDouble("seconds", Double.NaN)
        val updated = objectValue.optDouble("updated", Double.NaN)
        if (!seconds.isFinite() || !updated.isFinite()) continue
        entries[key] = SubtitleOffsetEntry(seconds = seconds, updated = updated)
    }
    return entries
}

private fun encodeSubtitleOffsets(entries: Map<String, SubtitleOffsetEntry>): String {
    val root = JSONObject()
    entries.toSortedMap().forEach { (key, entry) ->
        root.put(
            key,
            JSONObject()
                .put("seconds", entry.seconds)
                .put("updated", entry.updated),
        )
    }
    return root.toString()
}
