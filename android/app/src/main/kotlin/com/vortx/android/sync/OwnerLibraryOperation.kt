package com.vortx.android.sync

import org.json.JSONObject
import java.time.Instant

/** An operation witness is deliberately separate from a resident row's synthetic viewing clock. */
internal data class OwnerLibraryOperation(
    val kind: Kind,
    val video: String? = null,
    val position: Long = 0,
    val duration: Long = 0,
    val name: String? = null,
    val poster: String? = null,
    val manualWatched: Boolean? = null,
    val manualWhole: Boolean = false,
    val manualDirect: Boolean = false,
    val manualInventory: List<String> = emptyList(),
    val manualVideos: Set<String> = emptySet(),
    val manualInitial: Boolean = false,
    val progressInitial: Boolean = false,
) {
    enum class Kind { MEMBERSHIP, PROGRESS, MANUAL, REMOVE }

    fun projection(before: VortXSyncDoc.OwnerLibraryItem?, owned: VortXSyncDoc.OwnerLibraryItem?, after: VortXSyncDoc.OwnerLibraryItem): VortXSyncDoc.OwnerLibraryItem? {
        if (before != null && owned == null) return null
        return when (kind) {
            Kind.REMOVE -> {
                if (before == null || owned == null || !LocalLibraryPublicationPolicy.removed(before, after)) return null
                owned.copy(removed = true, historyOnly = true)
            }
            Kind.MEMBERSHIP -> {
                if (name == null || after.name != name || after.poster != poster) return null
                val membershipState = if (before == null) after else after.copy(name = before.name, poster = before.poster)
                if (!LocalLibraryPublicationPolicy.membershipAdded(before, membershipState)) return null
                if (owned != null) owned.copy(name = after.name, poster = after.poster, removed = false, historyOnly = false)
                else after.copy(videoId = null, timeOffsetMs = 0, durationMs = 0, lastWatched = null,
                    watched = null, currentVideoWatched = null, timesWatched = null, wholeTitleWatched = null,
                    eventEpochMs = null, nativeEventEpochMs = null, removed = false, historyOnly = false, declaredWatchFields = emptySet())
            }
            Kind.PROGRESS -> {
                if (after.videoId != video || after.timeOffsetMs != position || after.durationMs != duration ||
                    OwnerLibraryHistoryPolicy.watchClock(after) == null) return null
                // Disk absence need not mean model absence: another account may have a memory-ahead
                // row. Only this observed tick's progress is authorized until prior full ownership exists.
                val scope = if (progressInitial) null else owned?.declaredWatchFields ?: if (owned == null) emptySet() else null
                after.copy(historyOnly = owned?.historyOnly ?: true, removed = owned?.removed ?: true,
                    watched = if (scope == null || "watched" in scope) after.watched else owned?.watched,
                    timesWatched = if (scope == null || "timesWatched" in scope) after.timesWatched else owned?.timesWatched,
                    wholeTitleWatched = if (scope == null || "wholeTitleWatched" in scope) after.wholeTitleWatched else owned?.wholeTitleWatched,
                    currentVideoWatched = if (scope == null || "currentVideoWatched" in scope) after.currentVideoWatched else owned?.currentVideoWatched?.takeIf { owned.videoId == after.videoId },
                    declaredWatchFields = scope)
            }
            Kind.MANUAL -> if (owned != null && before != null) {
                val expectedCount = if (manualWhole && manualWatched != null) {
                    if (manualWatched) (before.timesWatched ?: 0) + 1 else 0L
                } else before.timesWatched
                if (after.name != before.name || after.poster != before.poster || after.videoId != before.videoId ||
                    after.timeOffsetMs != before.timeOffsetMs || after.durationMs != before.durationMs ||
                    after.removed != before.removed || after.timesWatched != expectedCount) return null
                owned
            } else run {
                // This baseline carries no manual meaning: ownerWatched owns that independently.
                if (!manualInitial || manualWatched == null || name == null || after.name != name || after.poster != poster ||
                    !after.removed || after.videoId != null || after.timeOffsetMs != 0L || after.durationMs != 0L ||
                    after.currentVideoWatched == true || after.timesWatched != (if (manualWhole && manualWatched) 1L else 0L) ||
                    (manualDirect && after.watched != null)) return null
                after.copy(videoId = null, timeOffsetMs = 0, durationMs = 0, lastWatched = null, watched = null,
                    currentVideoWatched = null, timesWatched = null, wholeTitleWatched = null,
                    eventEpochMs = null, nativeEventEpochMs = null, historyOnly = true,
                    declaredWatchFields = if (manualDirect) emptySet() else null)
            }
        }
    }

    fun admitsInitialManual(model: JSONObject?, identity: String): Boolean {
        if (manualWatched == null || name == null) return false
        if (manualDirect) return true // Explicit Ctx preview action creates only an aggregate mark from absence.
        val source = model?.optJSONObject("libraryItem") ?: return false
        val raw = modelCandidate(source) ?: return false
        if (!pristineCounters(source)) return false
        if (raw.identity != identity || raw.name != name || raw.poster != poster || !raw.removed || raw.videoId != null ||
            raw.timeOffsetMs != 0L || raw.durationMs != 0L || raw.watched != null || raw.timesWatched != 0L || raw.currentVideoWatched == true) return false
        return raw.type == "movie" || (validInventory() && manualInventory.all { it.startsWith(raw.metaId + ":") } && watchedIds(model) == emptySet<String>())
    }

    fun admitsInitialProgress(model: JSONObject?, identity: String): Boolean {
        val source = model?.optJSONObject("libraryItem") ?: return false
        val raw = modelCandidate(source) ?: return false
        return name != null && raw.identity == identity && raw.name == name && raw.poster == poster &&
            raw.videoId == null && raw.timeOffsetMs == 0L && raw.durationMs == 0L && raw.watched == null &&
            raw.timesWatched == 0L && raw.currentVideoWatched != true && pristineCounters(source)
    }

    fun acceptsManualModel(model: JSONObject, row: VortXSyncDoc.OwnerLibraryItem): Boolean =
        !manualInitial || manualDirect || row.type == "movie" ||
            (validInventory() && watchedIds(model) == if (manualWatched == true) manualVideos else emptySet<String>())

    private fun validInventory() = manualInventory.isNotEmpty() && manualInventory.distinct().size == manualInventory.size &&
        manualVideos.isNotEmpty() && manualVideos.all { it in manualInventory }

    companion object {
        private fun pristineCounters(raw: JSONObject): Boolean {
            val state = raw.optJSONObject("state") ?: return false
            return listOf("timeWatched", "overallTimeWatched", "flaggedWatched").all { OwnerLibraryHistoryPolicy.unsignedInteger(state.opt(it)) == 0L }
        }
        internal fun watchedIds(model: JSONObject): Set<String>? {
            val rows = model.optJSONArray("watchedVideoIds") ?: return null
            val values = (0 until rows.length()).map { rows.opt(it) as? String ?: return null }
            return values.takeIf { it.distinct().size == it.size }?.toSet()
        }
        /** Raw model candidate is NOT a durable receipt. It must match the later disk projection exactly. */
        fun modelCandidate(raw: JSONObject): VortXSyncDoc.OwnerLibraryItem? {
            val id = raw.opt("_id") as? String ?: return null
            val type = raw.opt("type") as? String ?: return null
            if (!VortXSyncDoc.isTypedCatalogIdentity(id) || type !in setOf("movie", "series")) return null
            fun epoch(value: Any?): Long? = (value as? String)?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
            val event = epoch(raw.opt("_mtime"))?.takeIf { it > 0 } ?: return null
            val state = raw.optJSONObject("state") ?: return null
            if (!state.has("lastWatched") || !state.has("watched") || !state.has("video_id")) return null
            val watch = if (state.isNull("lastWatched")) null else epoch(state.opt("lastWatched")) ?: return null
            val video = if (state.isNull("video_id")) null else state.opt("video_id") as? String ?: return null
            val watched = if (state.isNull("watched")) null else state.opt("watched") as? String ?: return null
            val offset = OwnerLibraryHistoryPolicy.unsignedInteger(state.opt("timeOffset")) ?: return null
            val duration = OwnerLibraryHistoryPolicy.unsignedInteger(state.opt("duration")) ?: return null
            val count = OwnerLibraryHistoryPolicy.unsignedInteger(state.opt("timesWatched")) ?: return null
            val flagged = OwnerLibraryHistoryPolicy.unsignedInteger(state.opt("flaggedWatched")) ?: return null
            val removed = raw.opt("removed") as? Boolean ?: return null
            return VortXSyncDoc.OwnerLibraryItem(id, type, raw.opt("name") as? String ?: return null,
                raw.opt("poster") as? String, video, offset, duration, watch?.let { Instant.ofEpochMilli(it).toString() },
                watched, if (video != null && flagged > 0) true else null, count, removed,
                if (type == "movie") count > 0 else null, event, event)
        }
    }
}
