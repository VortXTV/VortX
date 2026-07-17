package com.vortx.android.library

import android.util.Log
import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.LibraryPortability
import com.vortx.android.model.MediaType
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.WatchOverlayStore

/**
 * The read/write half of library import/export: turns the ACTIVE profile's saved titles into portable
 * [LibraryPortability] items and merges an imported file back in. [LibraryPortability] itself is pure
 * serialization with no persistence dependency, so this is the piece that binds it to real data, and
 * `LibraryTransferScreen` is the piece that binds it to a file.
 *
 * Android port of the `extension ProfileStore` in `app/SourcesShared/Profiles.swift:1314-1380`
 * (`exportActiveLibraryItems` / `importLibraryItems`). Apple can hang these off ProfileStore as a Swift
 * extension; Kotlin has no such thing, so they live here and take the store as a parameter. That is also
 * deliberate ownership hygiene: this file adds the behavior WITHOUT editing `profile/`, which another
 * department owns.
 *
 * PER-PROFILE INVARIANT (Apple's, honored on both sides): the owner profile's library lives in the
 * engine/account, every other profile reads and writes its own private `watch` overlay. [ProfileStore.
 * activeUsesEngineHistory] is the switch, exactly as on Apple.
 */
object LibraryTransfer {

    private const val TAG = "libtransfer"

    /**
     * The outcome of an [importLibraryItems] call, so the UI can tell the viewer what actually happened
     * instead of implying a silent success. Mirrors Apple's `(applied: Int, skipped: Int)` tuple, plus
     * [overlayUnsupported] for the one branch Android cannot do yet (see [importLibraryItems]).
     */
    data class ImportResult(
        val applied: Int,
        val skipped: Int,
        val overlayUnsupported: Boolean = false,
    )

    /**
     * The active profile's saved library + watch history as portable items. Pure read, mutates nothing.
     * Mirrors Apple `exportActiveLibraryItems`.
     *
     * Owner (engine-backed): the account library is the source of truth, read through
     * [CatalogRepository.libraryPortableItems] (which keeps each entry's resume state and drops the
     * engine's `removed`/`temp` bookkeeping entries). Apple additionally folds its separate Continue
     * Watching list in by id; Android does not need that step because the engine's library entry already
     * carries the same `state` the CW rail is derived from, so the offset is present without the merge.
     *
     * Overlay profile: the private watch overlay already carries everything (progress + watched episodes)
     * at full fidelity, so it maps straight across.
     */
    suspend fun exportActiveLibraryItems(
        repo: CatalogRepository,
        profiles: ProfileStore?,
    ): List<LibraryPortability.Item> {
        val now = WatchOverlayStore.isoNow()
        // No ProfileStore yet = a single-profile install, which is the owner/engine case. Same default as
        // [ProfileStore.activeUsesEngineHistory] itself (`active?.usesEngineHistory ?: true`).
        val usesEngine = profiles?.activeUsesEngineHistory ?: true
        if (usesEngine) {
            return repo.libraryPortableItems(now)
                .onFailure { Log.w(TAG, "library export read failed", it) }
                .getOrDefault(emptyList())
        }
        return profiles?.watch.orEmpty().map { (metaId, entry) ->
            LibraryPortability.Item(
                metaId = metaId,
                type = entry.type,
                name = entry.name,
                poster = entry.poster,
                videoId = entry.videoId,
                timeOffsetMs = entry.timeOffsetMs,
                durationMs = entry.durationMs,
                lastWatched = entry.lastWatched,
                watchedVideoIds = entry.watchedVideoIds,
            )
        }
    }

    /**
     * Merge imported items into the ACTIVE profile. Mirrors Apple `importLibraryItems`.
     *
     * Owner (engine-backed): each real catalog title is added through the engine's OWN AddToLibrary
     * dispatch, which re-resolves the canonical meta -- never an app-side libraryItem write, which would
     * poison official-client account sync (the same hard invariant [LibraryAutoAdd] and
     * [PlayedLinkLibrary] hold). Only `tt…` / `tmdb…` ids are engine-safe; anything else (a `kitsu:` or
     * other add-on-specific id) is SKIPPED AND REPORTED, never silently dropped, exactly as Apple does.
     *
     * Overlay profile: NOT YET SUPPORTED, and reported as such rather than silently doing nothing. Apple
     * merges into the private overlay with a loss-free rule (`mergedWatch`: union the watched episodes,
     * and for the in-progress episode keep whichever resume point is FURTHER ALONG, so an import can never
     * roll back local progress). Android's overlay exposes no such merge write: the one public merge,
     * [WatchOverlayStore.applyRemoteOverlay], is the sync layer's cloud-to-device path and takes the newer
     * side wholesale WITHOUT that never-reduce-the-resume-point rule, so reusing it here would quietly
     * roll back a viewer's progress. The faithful merge belongs in `profile/`, which another department
     * owns and is mid-flight in. Unreachable in practice today (Android surfaces no profile picker, so the
     * active profile is always the owner), which is why this is a report rather than a blocker.
     */
    suspend fun importLibraryItems(
        repo: CatalogRepository,
        profiles: ProfileStore?,
        items: List<LibraryPortability.Item>,
    ): ImportResult {
        if (items.isEmpty()) return ImportResult(applied = 0, skipped = 0)
        val usesEngine = profiles?.activeUsesEngineHistory ?: true
        if (!usesEngine) return ImportResult(applied = 0, skipped = items.size, overlayUnsupported = true)

        val accepted = items.filter { it.metaId.startsWith("tt") || it.metaId.startsWith("tmdb") }
        var applied = 0
        for (item in accepted) {
            // The engine's AddToLibrary reducer only needs id/type/name/poster and re-derives the rest, so
            // this is the minimal shape (identical to [LibraryAutoAdd]'s add). A single failed add must not
            // abort the whole import, and must not be counted as applied.
            val result = repo.addToLibrary(
                type = MediaType.fromId(item.type),
                id = item.metaId,
                name = item.name,
                poster = item.poster,
            )
            if (result.isSuccess) applied++ else Log.w(TAG, "import: add failed for ${item.metaId}")
        }
        // A partly-failed import reports what actually landed: the failures fall into `skipped` rather than
        // being counted as applied, so the message can never overstate the result.
        return ImportResult(applied = applied, skipped = items.size - applied)
    }
}
