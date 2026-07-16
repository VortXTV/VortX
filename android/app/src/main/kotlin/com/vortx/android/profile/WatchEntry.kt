package com.vortx.android.profile

import org.json.JSONArray
import org.json.JSONObject

/**
 * One title's watch state inside a profile's PRIVATE overlay: enough to render Continue Watching,
 * resume, and watched markers without touching the account's shared library. The Android port of
 * Apple `ProfileSync.swift` `WatchEntry`.
 *
 * WIRE FORMAT (byte-for-byte with Apple): this is the payload the sync wave writes into the SAME
 * account datastore document the Apple app writes, so [encode]/[decode] use Apple's exact `Codable`
 * field names and presence rules:
 *   - `videoId` and `poster` are optional and OMITTED when null (Apple's `encodeIfPresent`).
 *   - `timeOffsetMs` / `durationMs` are integers; `lastWatched` / `name` / `type` are strings; all
 *     are always present.
 *   - `watchedVideoIds` is a non-optional array and is ALWAYS emitted (default `[]`).
 * There are no floating-point fields, so the encoding is fully deterministic. A doc written by either
 * platform therefore decodes losslessly on the other and re-encodes to the same shape.
 *
 * INVARIANT (CLAUDE.md): the overlay is the profile's private store. It must NEVER be written into a
 * `libraryItem` or any account/engine-parsed schema field — an early build corrupted official-app
 * library sync that way. This type is serialized only into the app-owned overlay caches + the app-owned
 * datastore collection, never the library.
 */
data class WatchEntry(
    /** Movie id, or `imdbId:season:episode` for the episode in progress. */
    val videoId: String? = null,
    val timeOffsetMs: Int = 0,
    val durationMs: Int = 0,
    /** ISO timestamp, orders the rail. */
    val lastWatched: String = "",
    val name: String = "",
    val type: String = "",
    val poster: String? = null,
    val watchedVideoIds: List<String> = emptyList(),
) {
    /** Fractional progress 0..1, or 0 when the duration is unknown. Mirrors Apple `WatchEntry.progress`. */
    val progress: Double
        get() {
            if (durationMs <= 0) return 0.0
            return (timeOffsetMs.toDouble() / durationMs.toDouble()).coerceIn(0.0, 1.0)
        }

    fun encode(): JSONObject = JSONObject().apply {
        videoId?.let { put("videoId", it) }        // encodeIfPresent
        put("timeOffsetMs", timeOffsetMs)
        put("durationMs", durationMs)
        put("lastWatched", lastWatched)
        put("name", name)
        put("type", type)
        poster?.let { put("poster", it) }          // encodeIfPresent
        put("watchedVideoIds", JSONArray(watchedVideoIds))   // non-optional, always emitted
    }

    companion object {
        /** Tolerant decode: `watchedVideoIds` defaults to empty, optionals to null. */
        fun decode(o: JSONObject): WatchEntry = WatchEntry(
            videoId = o.optStringOrNull("videoId"),
            timeOffsetMs = o.optInt("timeOffsetMs", 0),
            durationMs = o.optInt("durationMs", 0),
            lastWatched = o.optString("lastWatched", ""),
            name = o.optString("name", ""),
            type = o.optString("type", ""),
            poster = o.optStringOrNull("poster"),
            watchedVideoIds = o.optJSONArray("watchedVideoIds")?.toStringList() ?: emptyList(),
        )

        /** Encode a whole overlay map (`metaId -> WatchEntry`) exactly like Apple's `[String: WatchEntry]`. */
        fun encodeMap(map: Map<String, WatchEntry>): String {
            val obj = JSONObject()
            for ((metaId, entry) in map) obj.put(metaId, entry.encode())
            return obj.toString()
        }

        fun decodeMap(json: String): Map<String, WatchEntry>? = runCatching {
            val obj = JSONObject(json)
            val out = LinkedHashMap<String, WatchEntry>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val metaId = keys.next()
                obj.optJSONObject(metaId)?.let { out[metaId] = decode(it) }
            }
            out
        }.getOrNull()
    }
}
