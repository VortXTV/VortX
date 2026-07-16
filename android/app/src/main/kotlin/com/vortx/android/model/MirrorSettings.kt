package com.vortx.android.model

import android.content.Context

/**
 * Per-category control of whether VortX mirrors a live Stremio account. The Android port of Apple
 * `MirrorSettings` (in `CoreModels.swift`).
 *
 * DEFAULT OFF for every category = the FLOOR: VortX owns the category. Snapshot-on-import seeds it once,
 * hydrate-from-doc keeps it alive, and a Stremio removal NEVER removes it from VortX.
 *
 * ON = EXACT MIRROR for that category: on a SUCCESSFUL Stremio reconcile the VortX-owned set for the category
 * is replaced to match the live Stremio set (adds AND removes tracked).
 *
 * The never-zero guard is INDEPENDENT of these toggles: a failed/absent/empty Stremio pull is ignored and
 * never zeroes a category, and hydrate-from-doc is not gated by the toggles either. The toggles only control
 * the snapshot/mirror DIRECTION (Stremio -> VortX) and whether Stremio removals propagate. That guard lives in
 * the sync layer (a later round), not in this value type -- Apple's `MirrorSettings` is likewise only the flags.
 *
 * Stored in [android.content.SharedPreferences] under the same keys Apple uses on `UserDefaults`, so the flags
 * ride the same settings-backup blob (`doc.settings`) and sync across devices once `SettingsBackup` is ported.
 */
class MirrorSettings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /** Mirror add-ons from Stremio (default OFF = VortX keeps its own add-on set). */
    var mirrorAddons: Boolean
        get() = prefs.getBoolean(KEY_ADDONS, false)
        set(value) = prefs.edit().putBoolean(KEY_ADDONS, value).apply()

    /** Mirror library from Stremio (default OFF = VortX keeps its own library). */
    var mirrorLibrary: Boolean
        get() = prefs.getBoolean(KEY_LIBRARY, false)
        set(value) = prefs.edit().putBoolean(KEY_LIBRARY, value).apply()

    /** Mirror Continue Watching from Stremio (default OFF = VortX keeps its own CW). */
    var mirrorContinueWatching: Boolean
        get() = prefs.getBoolean(KEY_CW, false)
        set(value) = prefs.edit().putBoolean(KEY_CW, value).apply()

    companion object {
        const val PREFS_FILE = "vortx_settings"
        const val KEY_ADDONS = "stremiox.sync.mirror.addons"
        const val KEY_LIBRARY = "stremiox.sync.mirror.library"
        const val KEY_CW = "stremiox.sync.mirror.cw"
    }
}
