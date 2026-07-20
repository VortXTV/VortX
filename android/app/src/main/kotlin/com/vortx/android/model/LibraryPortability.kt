package com.vortx.android.model

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/**
 * Portable export / import of a single profile's library + watch history, so a viewer can carry their saved
 * titles and progress to another device or another profile without the account in the loop. The Android port
 * of Apple `app/SourcesShared/LibraryPortability.swift`. Pure serialization only, no persistence dependency.
 *
 * WIRE FORMAT: matches the Apple `Codable` envelope field-for-field so a file exported on ONE platform
 * imports on the OTHER (`format` = "vortx-library", `schema` = 1). Field names, envelope shape, ISO8601 date
 * encoding, and omitted-null optionals (`poster`/`videoId`) are identical. The encoder emits sorted keys +
 * 2-space pretty print (mirroring Apple's `[.prettyPrinted, .sortedKeys]`); the decoder is whitespace- and
 * key-order-tolerant, so the cross-platform backup round-trip holds in both directions.
 *
 * `org.json` is used (the codebase's established JSON mechanism, same as the sibling `SearchHistoryStore`
 * port) rather than a new serialization framework, to keep this a self-contained new-file port with no
 * shared build-file changes.
 */
object LibraryPortability {
    const val SCHEMA = 1
    const val FORMAT_TAG = "vortx-library"

    /**
     * One saved title with its watch state. `watchedVideoIds` is populated for overlay profiles (the engine
     * owns per-episode ticks for the owner, so it stays empty there); a zero offset is a saved-but-unwatched
     * title. `lastWatched` is an ISO timestamp that orders the rail and drives last-writer-wins merges.
     */
    data class Item(
        val metaId: String,
        val type: String,
        val name: String,
        val poster: String? = null,
        val videoId: String? = null,
        val timeOffsetMs: Int = 0,
        val durationMs: Int = 0,
        val lastWatched: String,
        val watchedVideoIds: List<String> = emptyList(),
    )

    /** The on-disk envelope. Mirrors Apple `LibraryPortability.Envelope`. */
    data class Envelope(
        val format: String,
        val schema: Int,
        val app: String,
        val profile: String,
        val createdAt: String, // ISO8601
        val count: Int,
        val items: List<Item>,
    )

    /** Thrown by [decode] when the payload is not a VortX library export. Mirrors Apple `RestoreError.notALibrary`. */
    class NotALibraryException : Exception("This file is not a VortX library export.")

    // MARK: Pure serialization (no persistence dependency)

    /**
     * Encode [items] into the portable JSON envelope. Keys are inserted in alphabetical order and the output
     * is 2-space pretty printed to mirror Apple's `[.prettyPrinted, .sortedKeys]`; `createdAt` is ISO8601 with
     * second precision (Apple's `.iso8601` default) and null `poster`/`videoId` are omitted (Swift's
     * `encodeIfPresent` for optionals).
     */
    fun encode(items: List<Item>, profile: String, app: String = "VortX", now: Instant = Instant.now()): String {
        val createdAt = ISO_INSTANT_SECONDS.format(now.truncatedTo(ChronoUnit.SECONDS))
        val itemsArray = JSONArray()
        items.forEach { itemsArray.put(itemJson(it)) }
        // Keys inserted in sorted order (org.json preserves insertion order): app, count, createdAt, format, items, profile, schema.
        val env = JSONObject()
        env.put("app", app)
        env.put("count", items.size)
        env.put("createdAt", createdAt)
        env.put("format", FORMAT_TAG)
        env.put("items", itemsArray)
        env.put("profile", profile)
        env.put("schema", SCHEMA)
        return env.toString(2)
    }

    /** Decode the portable envelope. Validates the format tag, then returns its items. Mirrors Apple `decode(from:)`. */
    fun decode(json: String): List<Item> {
        val root = runCatching { JSONObject(json) }.getOrNull() ?: throw NotALibraryException()
        if (root.optString("format") != FORMAT_TAG) throw NotALibraryException()
        val arr = root.optJSONArray("items") ?: JSONArray()
        val out = ArrayList<Item>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(
                Item(
                    metaId = o.optString("metaId"),
                    type = o.optString("type"),
                    name = o.optString("name"),
                    poster = o.optStringOrNull("poster"),
                    videoId = o.optStringOrNull("videoId"),
                    timeOffsetMs = o.optInt("timeOffsetMs", 0),
                    durationMs = o.optInt("durationMs", 0),
                    lastWatched = o.optString("lastWatched"),
                    watchedVideoIds = o.optJSONArray("watchedVideoIds")?.toStringList() ?: emptyList(),
                ),
            )
        }
        return out
    }

    /** Suggested exporter filename (the `.json` extension is appended by the caller). Mirrors Apple `defaultFilename`. */
    fun defaultFilename(profile: String): String {
        val stamp = FILENAME_STAMP.format(Instant.now())
        val safe = profile.filter { it.isLetterOrDigit() }
        val tag = safe.ifEmpty { "Library" }
        return "VortX-Library-$tag-$stamp"
    }

    private fun itemJson(it: Item): JSONObject {
        // Keys inserted in sorted order: durationMs, lastWatched, metaId, name, poster?, timeOffsetMs, type, videoId?, watchedVideoIds.
        val o = JSONObject()
        o.put("durationMs", it.durationMs)
        o.put("lastWatched", it.lastWatched)
        o.put("metaId", it.metaId)
        o.put("name", it.name)
        if (it.poster != null) o.put("poster", it.poster)
        o.put("timeOffsetMs", it.timeOffsetMs)
        o.put("type", it.type)
        if (it.videoId != null) o.put("videoId", it.videoId)
        o.put("watchedVideoIds", JSONArray(it.watchedVideoIds))
        return o
    }

    private fun JSONObject.optStringOrNull(key: String): String? =
        if (has(key) && !isNull(key)) optString(key) else null

    private fun JSONArray.toStringList(): List<String> = (0 until length()).map { optString(it) }

    private val ISO_INSTANT_SECONDS: DateTimeFormatter = DateTimeFormatter.ISO_INSTANT
    private val FILENAME_STAMP: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd-HHmm").withZone(ZoneId.systemDefault())
}
