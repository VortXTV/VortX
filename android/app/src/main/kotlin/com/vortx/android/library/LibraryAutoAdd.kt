package com.vortx.android.library

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.MediaType
import com.vortx.android.profile.ProfileStore
import org.json.JSONArray

/**
 * Auto-add-to-Library at ~60s of playback (D8): once the user has genuinely committed to a title (crossed
 * the ~60s watch tick that also marks progress), add it to the Library automatically so it is one tap away
 * later. Android port of `app/SourcesShared/LibraryAutoAdd.swift`.
 *
 * Invariants (CLAUDE.md "Never write app data into libraryItem"):
 *   - Adds go through the ENGINE's AddToLibrary dispatch ONLY ([CatalogRepository.addToLibrary]), which
 *     syncs to the account exactly like the manual Library button. NEVER an app-side libraryItem write; the
 *     idempotency ledger below lives in its OWN SharedPreferences file, not any engine/library schema.
 *   - Only real catalog ids (`tt…` / `tmdb…`) are ever added; a synthetic magnet / paste-a-link id is
 *     rejected up front (it would poison official-client account sync).
 *
 * Idempotency + honoring a manual removal: this records a per-profile set of ids it has ALREADY auto-added
 * (SharedPreferences). It auto-adds a given id AT MOST ONCE, so if the user later manually removes the
 * title it is NOT force-re-added on the next play (the whole point of D8's "remember a manual removal").
 * The engine's AddToLibrary is itself idempotent, but the local marker is what makes a manual removal stick.
 *
 * Per-profile note: Apple keys the ledger by the active profile id (overlay profiles never touch the
 * account library). Now that [ProfileStore] has landed, [activeProfileId] defaults to
 * [ProfileStore.activeProfileId], so the ledger is keyed per profile (the owner keys by the fixed owner
 * id) and one profile's auto-adds can never mark another's. Falls back to the shared key before
 * [ProfileStore] is initialized, exactly what a single-profile Apple install does.
 *
 * Fully fail-soft: a failed add simply is not remembered, so it retries on the next play rather than being
 * silently pinned as "already added".
 */
class LibraryAutoAdd(
    context: Context,
    private val activeProfileId: () -> String? = { ProfileStore.sharedOrNull()?.activeProfileId },
) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /** The per-profile storage key. Falls back to the shared key when there is no active profile id. */
    private fun storageKey(profileId: String? = activeProfileId()): String =
        if (profileId != null) "$KEY_PREFIX.$profileId" else KEY_PREFIX

    /**
     * Whether this id has already been auto-added once. Public so the caller can cheaply short-circuit the
     * ~60s tick without building any meta. Mirrors Apple `hasAutoAdded`.
     */
    fun hasAutoAdded(id: String): Boolean = loadIds().contains(id)

    private fun loadIds(): List<String> {
        val raw = prefs.getString(storageKey(), null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).map { array.getString(it) }
        }.getOrDefault(emptyList())
    }

    private fun rememberAutoAdded(id: String) {
        val ids = loadIds()
        if (ids.contains(id)) return
        val updated = (ids + id).let { if (it.size > CAP) it.subList(it.size - CAP, it.size) else it }
        val array = JSONArray()
        updated.forEach { array.put(it) }
        prefs.edit().putString(storageKey(), array.toString()).apply()
    }

    /**
     * Auto-add the currently-playing title to the Library once, respecting the invariants above. Idempotent:
     * after the first successful auto-add for this id, a no-op, so a manual removal afterwards is honored.
     * Mirrors Apple `addIfNeeded`.
     *
     * @param repo the engine seam (the account-syncing AddToLibrary path).
     * @param id the playing title's catalog id (`libraryId`); [type]/[name]/[poster] its meta.
     * @param enabled the "Auto-add watched to Library" setting (default ON); a `false` skips entirely.
     */
    suspend fun addIfNeeded(
        repo: CatalogRepository,
        id: String,
        type: MediaType,
        name: String,
        poster: String?,
        enabled: Boolean,
    ) {
        if (!enabled) return
        // Only real catalog ids belong in the account library. A synthetic magnet / ad-hoc paste-a-link id
        // must never be written (it poisons official-client account sync). tt… and tmdb… are the safe shapes.
        if (!id.startsWith("tt") && !id.startsWith("tmdb")) return
        if (hasAutoAdded(id)) return   // already auto-added once -> respect a later manual removal

        // Go through the engine's own AddToLibrary dispatch (account-syncing, minimal MetaItemPreview shape;
        // the engine re-derives the rest from the id). Only remember once the add actually succeeds; a
        // failed add must retry on the next play, not be silently pinned as "already added".
        val result = repo.addToLibrary(type, id, name, poster)
        if (result.isSuccess) {
            rememberAutoAdded(id)
            Log.i(TAG, "auto-added $id to account library (engine)")
        }
    }

    private companion object {
        const val TAG = "autolib"
        const val PREFS_FILE = "vortx_auto_added_library"
        const val KEY_PREFIX = "vortx.autoAddedLibrary"
        const val CAP = 2000   // bound the remembered-ids set so it can't grow without limit
    }
}
