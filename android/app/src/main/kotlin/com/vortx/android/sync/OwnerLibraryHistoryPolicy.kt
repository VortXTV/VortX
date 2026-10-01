package com.vortx.android.sync

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/** Account history policy shared by document merging and the native boundary. No wall-clock reads. */
internal object OwnerLibraryHistoryPolicy {
    fun unsignedInteger(value: Any?): Long? = (value as? Number)?.let {
        val double = it.toDouble()
        if (double.isFinite() && double >= 0 && double < Long.MAX_VALUE.toDouble() && double == it.toLong().toDouble()) it.toLong() else null
    }

    fun watchClock(item: VortXSyncDoc.OwnerLibraryItem): Long? = item.lastWatched?.let {
        runCatching { Instant.parse(it).toEpochMilli() }.getOrNull()?.takeIf { value -> value > 0 }
    }

    fun clock(item: VortXSyncDoc.OwnerLibraryItem): Long? = item.eventEpochMs ?: watchClock(item)

    fun preserveUndeclaredWatchFields(incoming: VortXSyncDoc.OwnerLibraryItem, owned: VortXSyncDoc.OwnerLibraryItem?): VortXSyncDoc.OwnerLibraryItem {
        val fields = incoming.declaredWatchFields ?: return incoming
        if (owned == null) return incoming
        return incoming.copy(
            watched = if ("watched" in fields) incoming.watched else owned.watched,
            timesWatched = if ("timesWatched" in fields) incoming.timesWatched else owned.timesWatched,
            wholeTitleWatched = if ("wholeTitleWatched" in fields) incoming.wholeTitleWatched else owned.wholeTitleWatched,
            currentVideoWatched = if ("currentVideoWatched" in fields || incoming.videoId != owned.videoId) incoming.currentVideoWatched else owned.currentVideoWatched,
        )
    }

    fun newerIncoming(
        incoming: List<VortXSyncDoc.OwnerLibraryItem>,
        local: List<VortXSyncDoc.OwnerLibraryItem>,
    ): List<VortXSyncDoc.OwnerLibraryItem> {
        val present = local.associateBy { it.identity }
        return incoming.groupBy { it.identity }.values.map { rows -> rows.maxBy { clock(it) ?: 0 } }.filter { item ->
            val previous = present[item.identity]
            val event = clock(item)
            when {
                event != null -> event > maxOf(previous?.nativeEventEpochMs ?: 0, previous?.let(::clock) ?: 0)
                item.lastWatched != null || item.removed -> false
                else -> previous == null
            }
        }
    }

    fun merge(existing: JSONArray?, local: List<VortXSyncDoc.OwnerLibraryItem>, removed: Set<String>,
        decode: (JSONObject) -> VortXSyncDoc.OwnerLibraryItem? = VortXSyncDoc::ownerLibraryItem): JSONArray {
        val rows = mutableListOf<Any>()
        val indexes = mutableMapOf<String, Int>()
        if (existing != null) for (index in 0 until existing.length()) {
            val raw = existing.get(index)
            val row = raw as? JSONObject
            val item = row?.let(decode)
            if (item != null && LibraryTombstones.normalize(item.metaId) in removed) continue
            val identity = item?.identity ?: row?.let { rawRow ->
                val id = rawRow.opt("id") as? String
                val type = rawRow.opt("type") as? String
                if (id != null && type != null) "$type:$id" else null
            }
            if (identity != null) indexes.putIfAbsent(identity, rows.size)
            rows.add(raw)
        }
        for (item in local) {
            if (LibraryTombstones.normalize(item.metaId) in removed) continue
            val index = indexes[item.identity]
            val clock = clock(item)
            if (index != null) {
                val prior = rows[index] as JSONObject
                val previous = decode(prior) ?: continue
                // A malformed peer event is opaque; an unclocked local read cannot repair it.
                if (clock == null || (previous.lastWatched != null && clock(previous) == null)) continue
                if (clock <= (clock(previous) ?: 0)) continue
                rows[index] = encode(item, JSONObject(prior.toString()))
            } else {
                if (item.lastWatched != null && clock == null) continue
                indexes[item.identity] = rows.size
                rows.add(encode(item, JSONObject()))
            }
        }
        return JSONArray(rows)
    }

    internal fun encode(item: VortXSyncDoc.OwnerLibraryItem, row: JSONObject): JSONObject = row.apply {
        put("id", item.metaId); put("type", item.type); put("name", item.name); put("poster", item.poster ?: "")
        if (clock(item) != null) {
            put("v", item.videoId ?: ""); put("t", item.timeOffsetMs / 1000.0); put("d", item.durationMs / 1000.0)
            put("lastWatched", item.lastWatched ?: JSONObject.NULL)
            item.eventEpochMs?.let { put("eventEpochMs", it) }
            val watchFields = mapOf("watched" to item.watched, "currentVideoWatched" to item.currentVideoWatched,
                "timesWatched" to item.timesWatched, "wholeTitleWatched" to if (item.type == "movie") item.wholeTitleWatched else null)
            for ((field, value) in watchFields) {
                if (item.declaredWatchFields == null || field in item.declaredWatchFields)
                    put(field, value ?: JSONObject.NULL)
            }
            if (item.historyOnly) remove("removed") else put("removed", item.removed)
        }
    }

    /** Native library removal is membership intent, not a web Continue Watching dismissal. */
    fun canonicalLibraryTombstones(parsed: VortXSyncDoc.Parsed): Map<String, Map<String, Double>> {
        val stamps = parsed.deletedLibraryTs.mapValues { it.value.toMutableMap() }.toMutableMap()
        for (item in parsed.ownerLibrary.orEmpty()) {
            if (!item.removed || item.historyOnly) continue
            val epoch = clock(item)?.toDouble() ?: continue
            val entry = stamps.getOrPut(LibraryTombstones.normalize(item.metaId)) { mutableMapOf() }
            entry["removedAt"] = maxOf(entry["removedAt"] ?: 0.0, epoch)
        }
        return stamps
    }
}
