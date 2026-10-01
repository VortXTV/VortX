package com.vortx.android.engine

import com.vortx.android.sync.OwnerLibraryHistoryPolicy
import com.vortx.android.sync.OwnerLibraryPublicationProofs
import com.vortx.android.sync.VortXSyncDoc
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/** Injectable JNI adapter. The caller holds HistoryOwnerFence; admission holds the VortX session lock. */
internal class NativeOwnerLibraryGateway(
    private val read: (String) -> String,
    private val restore: (String) -> String,
    private val add: (VortXSyncDoc.OwnerLibraryItem) -> Unit,
) {
    fun snapshot(uid: String?, admit: ((() -> Boolean) -> Boolean)): List<VortXSyncDoc.OwnerLibraryItem>? {
        var result: List<VortXSyncDoc.OwnerLibraryItem>? = null
        if (!admit { result = parseProjection(read(uid?.let(JSONObject::quote) ?: "null"), uid); result != null }) return null
        return if (admit { true }) result else null
    }

    /** Re-read and select strictly newer events inside the same admitted native critical section. */
    fun apply(uid: String?, incoming: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean), onRestored: (List<VortXSyncDoc.OwnerLibraryItem>) -> Unit = {}): Boolean {
        return admit {
            val local = parseProjection(read(uid?.let(JSONObject::quote) ?: "null"), uid) ?: return@admit false
            if (!admit { true }) return@admit false
            val candidates = OwnerLibraryHistoryPolicy.newerIncoming(incoming, local)
            val events = candidates.filter { OwnerLibraryHistoryPolicy.clock(it) != null }
            if (events.isNotEmpty()) {
                val request = JSONObject().put("ownerUid", uid ?: JSONObject.NULL)
                    .put("events", JSONArray(events.map(::restoreEvent)))
                if (!admit { receiptMatches(restore(request.toString()), uid, events) }) return@admit false
            }
            for (item in candidates.filter { OwnerLibraryHistoryPolicy.clock(it) == null }) {
                if (!admit { add(item); true }) return@admit false
            }
            if (events.isNotEmpty()) {
                val post = parseProjection(read(uid?.let(JSONObject::quote) ?: "null"), uid)
                val exact = post.orEmpty().filter { actual -> events.any { OwnerLibraryPublicationProofs.matchesRestored(it, actual) } }
                if (!admit { onRestored(exact); true }) return@admit false
            }
            // A rejected native batch or expired lease never receives an acknowledgement.
            admit { true }
        }
    }

    private fun restoreEvent(item: VortXSyncDoc.OwnerLibraryItem): JSONObject = JSONObject().apply {
        put("meta", JSONObject().put("id", item.metaId).put("type", item.type).put("name", item.name)
            .put("poster", item.poster ?: JSONObject.NULL))
        put("currentVideoId", item.videoId ?: JSONObject.NULL)
        put("timeOffsetMs", item.timeOffsetMs); put("durationMs", item.durationMs)
        val epoch = requireNotNull(OwnerLibraryHistoryPolicy.clock(item))
        put("genuineEventEpochMs", epoch)
        put("lastWatchedEpochMs", OwnerLibraryHistoryPolicy.watchClock(item) ?: JSONObject.NULL)
        put("wholeTitleWatched", if (item.type == "movie") item.wholeTitleWatched ?: JSONObject.NULL else JSONObject.NULL)
        put("watched", item.watched ?: JSONObject.NULL)
        put("currentVideoWatched", item.currentVideoWatched ?: JSONObject.NULL)
        put("timesWatched", item.timesWatched ?: JSONObject.NULL)
        put("removed", item.removed)
    }

    internal fun receiptMatches(raw: String, uid: String?, requested: List<VortXSyncDoc.OwnerLibraryItem>): Boolean {
        val root = runCatching { JSONObject(raw) }.getOrNull() ?: return false
        if (!uidMatches(root, uid)) return false
        val rows = root.optJSONArray("events") ?: return false
        if (rows.length() != requested.size || requested.map { it.identity }.toSet().size != requested.size) return false
        val remaining = requested.associateBy { it.identity }.toMutableMap()
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: return false
            val type = row.opt("type") as? String ?: return false
            val id = row.opt("id") as? String ?: return false
            val item = remaining.remove("$type:$id") ?: return false
            if (!row.has("currentVideoId") || (row.opt("currentVideoId") != JSONObject.NULL && row.opt("currentVideoId") !is String)) return false
            if ((row.opt("currentVideoId") as? String) != item.videoId ||
                OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("eventEpochMs")) != OwnerLibraryHistoryPolicy.clock(item)) return false
        }
        return remaining.isEmpty()
    }

    internal fun parseProjection(raw: String, uid: String?): List<VortXSyncDoc.OwnerLibraryItem>? {
        val root = runCatching { JSONObject(raw) }.getOrNull() ?: return null
        if (!uidMatches(root, uid)) return null
        val events = root.optJSONArray("events") ?: return null
        val seen = hashSetOf<String>()
        return buildList {
            for (index in 0 until events.length()) {
                val row = events.optJSONObject(index) ?: return null
                val meta = row.optJSONObject("meta") ?: row
                val id = meta.opt("id") as? String ?: return null
                val type = meta.opt("type") as? String ?: return null
                if (!VortXSyncDoc.isTypedCatalogIdentity(id) || type !in setOf("movie", "series")) continue
                if (!seen.add("$type:$id")) return null
                val epoch = OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("eventEpochMs")) ?: return null
                val lastWatched = if (row.has("lastWatchedEpochMs") && row.isNull("lastWatchedEpochMs")) null
                    else OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("lastWatchedEpochMs")) ?: return null
                val time = OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("timeOffsetMs")) ?: return null
                val duration = OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("durationMs")) ?: return null
                val times = OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("timesWatched"))?.takeIf { it <= 0xffff_ffffL } ?: return null
                if (!row.has("currentVideoId") || (row.opt("currentVideoId") != JSONObject.NULL && row.opt("currentVideoId") !is String)) return null
                if (!row.has("watched") || (row.opt("watched") != JSONObject.NULL && row.opt("watched") !is String)) return null
                for (key in listOf("currentVideoWatched", "wholeTitleWatched")) {
                    if (row.has(key) && !row.isNull(key) && row.opt(key) !is Boolean) return null
                }
                val removed = row.opt("removed") as? Boolean ?: return null
                val watched = row.opt("watched") as? String
                val currentWatched = row.opt("currentVideoWatched") as? Boolean
                val hasHistory = lastWatched != null || watched != null || times > 0 || currentWatched == true || removed
                add(VortXSyncDoc.OwnerLibraryItem(id, type, (meta.opt("name") as? String).orEmpty(), meta.opt("poster") as? String,
                    row.opt("currentVideoId") as? String, time, duration,
                    lastWatched?.let { Instant.ofEpochMilli(it).toString() }, watched, currentWatched, times, removed,
                    if (type == "movie") row.opt("wholeTitleWatched") as? Boolean else null,
                    eventEpochMs = epoch.takeIf { hasHistory && it > 0 }, nativeEventEpochMs = epoch))
            }
        }
    }

    private fun uidMatches(root: JSONObject, uid: String?): Boolean = root.has("uid") &&
        if (uid == null) root.opt("uid") == JSONObject.NULL else root.opt("uid") is String && root.opt("uid") == uid
}
