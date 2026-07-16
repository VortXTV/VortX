package com.vortx.android.profile

import android.content.SharedPreferences
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt

/**
 * A non-owner profile's PRIVATE watch overlay: its own Continue Watching, resume points, watched
 * markers, and saved library, kept in an app-owned cache and (once the sync wave lands) mirrored
 * through the account. The Android port of the watch-overlay half of Apple `ProfileStore`
 * (`Profiles.swift`, the "Watch overlay" section).
 *
 * HARD INVARIANT (CLAUDE.md): this is the profile's private store. It writes ONLY into the app-owned
 * per-profile cache key `stremiox.profiles.watch.<id>` (Apple's `watchCacheKey`) and never into a
 * `libraryItem` or any account/engine-parsed schema — that is what keeps official-app library sync from
 * being corrupted (the documented incident). The OWNER profile uses the engine/account library instead
 * and is never routed here (its live overlay stays empty).
 *
 * [ProfileStore] owns one instance and drives [activate] on load / switch. Writes are debounced (3s,
 * mirroring Apple `schedulePushWatch`) into [onRequestSync] + [onPushWatch] seams the sync wave wires;
 * both default to no-ops so the overlay is fully functional on-device before sync exists.
 */
class WatchOverlayStore(
    private val prefs: SharedPreferences,
    /** Published whenever the live overlay changes, so an observer (CW rail / library) can refresh. */
    private val onOverlayChanged: (Map<String, WatchEntry>) -> Unit = {},
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    /** Sync seams (default no-op until the sync wave wires them). Mirror Apple's `schedulePushWatch`. */
    var onRequestSync: () -> Unit = {}
    var onPushWatch: (profileId: String, snapshot: Map<String, WatchEntry>) -> Unit = { _, _ -> }

    private var activeProfileId: String? = null
    private var activeUsesEngine: Boolean = true
    private var pushJob: Job? = null

    /** The ACTIVE overlay profile's live watch state, keyed by meta id. Empty for the owner profile. */
    var watch: Map<String, WatchEntry> = emptyMap()
        private set

    /**
     * Point the live overlay at [profileId]. When [usesEngineHistory] the profile reads the account
     * library (the owner path), so the overlay is cleared and every write below becomes a no-op — the
     * account library is never touched from here. Mirrors Apple `loadWatchCache`.
     */
    fun activate(profileId: String?, usesEngineHistory: Boolean) {
        activeProfileId = profileId?.let { UserProfile.normalizeId(it) }
        activeUsesEngine = usesEngineHistory
        watch = if (profileId == null || usesEngineHistory) emptyMap() else load(activeProfileId!!)
        onOverlayChanged(watch)
    }

    // ---- Continue Watching / Library derivation ----

    /**
     * Continue Watching for the active overlay profile, newest first, capped at 30. Mirrors the account
     * rail's rules and Apple `cwItems`: a finished MOVIE leaves (its own id marked watched OR a near-end
     * offset), a series rolls forward (its keep-signal is EPISODE ids, never the series metaId).
     */
    fun continueWatching(): List<MetaItem> {
        val dated = ArrayList<Pair<String, MetaItem>>()
        for ((metaId, entry) in watch) {
            if (entry.type == "movie" &&
                (entry.watchedVideoIds.contains(metaId) ||
                    (entry.durationMs > 0 && entry.timeOffsetMs.toDouble() >= entry.durationMs.toDouble() * 0.95))
            ) continue
            if (!(entry.timeOffsetMs > 0 || entry.watchedVideoIds.isNotEmpty())) continue
            dated += entry.lastWatched to metaItem(metaId, entry)
        }
        return dated.sortedByDescending { it.first }.take(30).map { it.second }
    }

    /**
     * The active overlay profile's full Library: EVERY title it has watched, newest first — keeps
     * finished movies and not-yet-played saves, so it reads as a "saved titles" library rather than a
     * Continue Watching rail. Mirrors Apple `libraryItems`.
     */
    fun libraryItems(): List<MetaItem> =
        watch.map { (metaId, entry) -> entry.lastWatched to metaItem(metaId, entry) }
            .sortedByDescending { it.first }
            .map { it.second }

    private fun metaItem(metaId: String, entry: WatchEntry): MetaItem = MetaItem(
        id = metaId,
        type = MediaType.fromId(entry.type),
        name = entry.name,
        poster = entry.poster,
        progress = if (entry.durationMs > 0) entry.progress.toFloat() else null,
        resumeSeconds = if (entry.timeOffsetMs > 0) entry.timeOffsetMs / 1000.0 else null,
    )

    // ---- Player / detail writes (overlay-active only) ----

    /**
     * Player progress for the active overlay profile. Mirrors Apple `recordProgress`. Guarded: a no-op
     * when the active profile is engine-backed, so the account library is never written from here.
     */
    fun recordProgress(
        metaId: String,
        videoId: String,
        positionSeconds: Double,
        durationSeconds: Double,
        name: String,
        type: String,
        poster: String?,
    ) {
        if (!overlayActive() || durationSeconds <= 0) return
        val prev = watch[metaId] ?: WatchEntry(videoId = videoId, name = name, type = type, poster = poster)
        val entry = prev.copy(
            videoId = videoId,
            timeOffsetMs = (positionSeconds * 1000).roundToInt(),   // rounded, matching Apple `recordProgress`
            durationMs = (durationSeconds * 1000).roundToInt(),
            lastWatched = isoNow(),
            name = name,
            poster = poster ?: prev.poster,
        )
        mutate(metaId, entry)
    }

    /** Saved resume position in seconds (0 = start fresh); series only resume the same episode. Apple `resumeOffset`. */
    fun resumeOffset(metaId: String, videoId: String, type: String): Double {
        val entry = watch[metaId] ?: return 0.0
        if (type == "series" && entry.videoId != null && entry.videoId != videoId) return 0.0
        return if (entry.timeOffsetMs > 0) entry.timeOffsetMs / 1000.0 else 0.0
    }

    /** Episode ids the active overlay profile has watched for a title. Mirrors Apple `watchedVideoIds(forMeta:)`. */
    fun watchedVideoIds(metaId: String): Set<String> = watch[metaId]?.watchedVideoIds?.toSet() ?: emptySet()

    /** Bulk watched toggle for the detail page menus on overlay profiles. Mirrors Apple `setWatched`. */
    fun setWatched(
        isWatched: Boolean,
        metaId: String,
        videoIds: List<String>,
        name: String,
        type: String,
        poster: String?,
    ) {
        if (!overlayActive() || videoIds.isEmpty()) return
        val prev = watch[metaId] ?: WatchEntry(lastWatched = isoNow(), name = name, type = type, poster = poster)
        val ids = prev.watchedVideoIds.toMutableList()
        if (isWatched) {
            for (id in videoIds) if (!ids.contains(id)) ids.add(id)
        } else {
            ids.removeAll(videoIds.toSet())
        }
        mutate(metaId, prev.copy(watchedVideoIds = ids))
    }

    /** Mark a single video watched. Mirrors Apple `markWatched`. */
    fun markWatched(metaId: String, videoId: String, name: String, type: String, poster: String?) {
        if (!overlayActive()) return
        val prev = watch[metaId] ?: WatchEntry(videoId = videoId, lastWatched = isoNow(), name = name, type = type, poster = poster)
        if (prev.watchedVideoIds.contains(videoId)) return
        mutate(metaId, prev.copy(watchedVideoIds = prev.watchedVideoIds + videoId))
    }

    /**
     * Save a title to the overlay library without marking it watched (the "Add to Library" button).
     * A no-op when already tracked, so an add never clobbers existing progress. Mirrors Apple
     * `addLibraryEntry`.
     */
    fun addLibraryEntry(metaId: String, name: String, type: String, poster: String?) {
        if (!overlayActive() || watch.containsKey(metaId)) return
        mutate(metaId, WatchEntry(lastWatched = isoNow(), name = name, type = type, poster = poster))
    }

    /** A title finished: zero the offset so it leaves the CW rail. Mirrors Apple `finishedWatching`. */
    fun finishedWatching(metaId: String) {
        if (!overlayActive()) return
        val entry = watch[metaId] ?: return
        mutate(metaId, entry.copy(timeOffsetMs = 0))
    }

    /** Continue-Watching "dismiss": drop the whole entry (zeroing the offset is not enough). Apple `removeWatchEntry`. */
    fun removeWatchEntry(metaId: String) {
        if (!overlayActive() || !watch.containsKey(metaId)) return
        watch = watch - metaId
        persistAndPush()
    }

    // ---- Any-profile reads / remote hydration ----

    /** The stored overlay for ANY profile, read straight from its cache. Mirrors Apple `watchEntries(for:)`. */
    fun entries(profileId: String): Map<String, WatchEntry> = load(UserProfile.normalizeId(profileId))

    /**
     * Hydrate an OVERLAY profile's cache from a synced payload (cloud -> device). Merges per item
     * last-writer-wins by `lastWatched` and UNIONs `watchedVideoIds` so neither side's progress or
     * watched-episodes are lost. Never writes an engine-backed profile's cache. Mirrors Apple
     * `applyRemoteOverlay`. [isEngineBacked] lets the caller pass the target profile's history mode.
     */
    fun applyRemoteOverlay(profileId: String, incoming: Map<String, WatchEntry>, isEngineBacked: Boolean) {
        if (incoming.isEmpty() || isEngineBacked) return
        val id = UserProfile.normalizeId(profileId)
        val current = load(id).toMutableMap()
        var changed = false
        for ((metaId, inc) in incoming) {
            val existing = current[metaId]
            if (existing == null) {
                current[metaId] = inc; changed = true; continue
            }
            val union = (existing.watchedVideoIds.toSet() + inc.watchedVideoIds.toSet()).toList()
            if (inc.lastWatched > existing.lastWatched) {
                current[metaId] = inc.copy(watchedVideoIds = union); changed = true
            } else if (union.size != existing.watchedVideoIds.size) {
                current[metaId] = existing.copy(watchedVideoIds = union); changed = true
            }
        }
        if (!changed) return
        save(id, current)
        if (activeProfileId == id) {
            watch = current
            onOverlayChanged(watch)
        }
    }

    // ---- Internals ----

    private fun overlayActive(): Boolean = activeProfileId != null && !activeUsesEngine

    private fun mutate(metaId: String, entry: WatchEntry) {
        watch = watch + (metaId to entry)
        persistAndPush()
    }

    private fun persistAndPush() {
        val id = activeProfileId ?: return
        save(id, watch)
        onOverlayChanged(watch)
        schedulePush(id)
    }

    /** DEBOUNCED (3s): coalesce a burst of seeks/menu writes into ONE sync. Mirrors Apple `schedulePushWatch`. */
    private fun schedulePush(profileId: String) {
        pushJob?.cancel()
        val snapshot = watch
        pushJob = scope.launch {
            delay(PUSH_DEBOUNCE_MS)
            if (!isActive) return@launch
            onRequestSync()
            onPushWatch(profileId, snapshot)
        }
    }

    private fun load(profileId: String): Map<String, WatchEntry> {
        val raw = prefs.getString(cacheKey(profileId), null) ?: return emptyMap()
        return WatchEntry.decodeMap(raw) ?: emptyMap()
    }

    private fun save(profileId: String, map: Map<String, WatchEntry>) {
        prefs.edit().putString(cacheKey(profileId), WatchEntry.encodeMap(map)).apply()
    }

    /** Drop a removed profile's cache. Called by [ProfileStore.remove]. */
    fun clearCache(profileId: String) {
        prefs.edit().remove(cacheKey(UserProfile.normalizeId(profileId))).apply()
    }

    companion object {
        private const val PUSH_DEBOUNCE_MS = 3_000L

        /** Apple's per-profile overlay key: `stremiox.profiles.watch.<id>`. */
        fun cacheKey(profileId: String): String = "stremiox.profiles.watch.$profileId"

        /** ISO-8601 with fractional milliseconds + 'Z', matching Apple's `ISO8601DateFormatter` (`isoNow`). */
        private val ISO: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

        fun isoNow(): String = ISO.format(Instant.now())
    }
}
