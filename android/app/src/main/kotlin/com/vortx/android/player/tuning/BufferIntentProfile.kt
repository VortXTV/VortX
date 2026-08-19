package com.vortx.android.player.tuning

import android.content.Context

/**
 * The viewer's playback-buffering INTENT: how aggressively the player should trade start latency and RAM
 * for stall resistance. This is the user-facing half of the adaptive tuning (Nuvio Phase 2): the device
 * RAM tier and the measured link speed decide the ceiling, and this profile decides where inside that
 * ceiling to sit.
 *
 *   - [FAST]     short buffer target: lowest start latency and RAM, least stall headroom. For a fast,
 *                stable link where a deep buffer just wastes memory.
 *   - [BALANCED] medium target: the shipping default and, with no link measurement, byte-for-byte the
 *                merged RAM-tier behavior (so turning adaptive tuning on changes nothing until the viewer
 *                picks another profile or a link sweep lands).
 *   - [STALL]    long target: the deepest buffer the RAM budget allows, for a flaky link where riding out
 *                a throughput dip matters more than start latency.
 *
 * Stored in the shared `vortx_settings` file under a `vortx.*` key, so it rides the same cross-device
 * settings blob as the other player keys. Defaults to [BALANCED].
 */
enum class BufferIntentProfile(val storageValue: String, val label: String) {
    FAST("fast", "Fast start"),
    BALANCED("balanced", "Balanced"),
    STALL("stall", "Fewer stalls");

    companion object {
        const val KEY = "vortx.player.bufferIntent"

        /** BALANCED == the merged RAM-tier baseline, so an unset/unknown value never changes behavior. */
        val DEFAULT = BALANCED

        private const val SETTINGS_FILE = "vortx_settings"

        private fun prefs(context: Context) =
            context.applicationContext.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)

        fun fromStorage(raw: String?): BufferIntentProfile =
            entries.firstOrNull { it.storageValue == raw } ?: DEFAULT

        /** The persisted intent, read fresh per play so a change applies to the next title. */
        fun current(context: Context): BufferIntentProfile =
            fromStorage(prefs(context).getString(KEY, null))

        /** Persist the viewer's choice. The write side of [current]. */
        fun setCurrent(context: Context, profile: BufferIntentProfile) {
            prefs(context).edit().putString(KEY, profile.storageValue).apply()
        }
    }
}
