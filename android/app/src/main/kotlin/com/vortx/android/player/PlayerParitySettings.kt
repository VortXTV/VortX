package com.vortx.android.player

import android.content.Context
import kotlin.math.roundToInt

/**
 * Player-behaviour settings ported from the Apple player, kept in ONE new file so the shared
 * [PlayerSettings] stays untouched while these new values reuse the SAME `vortx_settings`
 * SharedPreferences file (the direct analogue of Apple `UserDefaults`). Each object keeps Apple's
 * persistence KEY and default byte-for-byte, so a value rides the same cross-device settings-backup
 * blob and a choice made on Apple / web takes effect here with no UI involved.
 *
 * Sources of truth (Apple):
 *   - [SeekStepSetting]     -> `stremiox.seekStep`            (PlayerScreen.swift:273, iOSSettingsView.swift:176)
 *   - [PlayerVolumeSettings]-> `stremiox.playerVolume/Muted`  (PlayerScreen.swift:277-278, iOSSettingsView.swift:173)
 *   - [StillWatchingSettings]-> `vortx.stillWatching*`        (PlayerScreen.swift:345/349, iOSSettingsView.swift:166-167)
 */
private const val PARITY_SETTINGS_FILE = "vortx_settings"

private fun parityPrefs(context: Context) =
    context.applicationContext.getSharedPreferences(PARITY_SETTINGS_FILE, Context.MODE_PRIVATE)

// ---------------------------------------------------------------------------------------------------
// SeekStepSetting - Apple @AppStorage("stremiox.seekStep") = "10"
// ---------------------------------------------------------------------------------------------------

/**
 * The skip-button / double-tap / media FF-RW step in SECONDS, the Android port of Apple's
 * `stremiox.seekStep`. Stored as a STRING ("10"/"15"/"30") to match Apple's picker tags exactly, so a
 * synced value round-trips. Drives every discrete relative seek in the player (the transport +/- buttons,
 * the double-tap gesture, the TV remote FF/RW keys, and the hidden-chrome D-pad nudge). Read per play.
 */
object SeekStepSetting {
    const val KEY = "stremiox.seekStep"
    const val DEFAULT = "10"

    /** The choices Settings offers, in Apple's order (iOSSettingsView.swift:704). `id` persists. */
    val choices: List<Pair<String, String>> = listOf(
        "10" to "10s", "15" to "15s", "30" to "30s",
    )

    /** The persisted step id ("10"/"15"/"30"), defaulting to Apple's "10". */
    fun current(context: Context): String = parityPrefs(context).getString(KEY, DEFAULT) ?: DEFAULT

    /** Persist the chosen step id. */
    fun setCurrent(context: Context, id: String) {
        parityPrefs(context).edit().putString(KEY, id).apply()
    }

    /** The step in whole seconds (Apple `seekStepSeconds`: `Double(seekStep) ?? 10`). */
    fun stepSeconds(context: Context): Long = current(context).toLongOrNull() ?: 10L

    /** The step in milliseconds, the unit the engine seam ([PlayerEngine.seekBy]) takes. */
    fun stepMs(context: Context): Long = stepSeconds(context) * 1000L
}

// ---------------------------------------------------------------------------------------------------
// PlayerVolumeSettings - Apple @AppStorage("stremiox.playerVolume")=100 / ("stremiox.playerMuted")=false
// ---------------------------------------------------------------------------------------------------

/**
 * The default APP (engine) volume and mute state, the Android port of Apple's `stremiox.playerVolume`
 * (a 0..100 Double, default 100) and `stremiox.playerMuted` (Bool, default false). Applied at load
 * through the already-implemented engine `setVolume` / `setMuted` seam, and written by the in-player
 * volume slider / mute button and the Settings "Default volume" picker (so the picker also reflects the
 * last in-player level, exactly as Apple's shared @AppStorage does).
 *
 * DEVICE-scoped, never per-profile: it describes how loud THIS device plays, like Apple's @AppStorage.
 */
object PlayerVolumeSettings {
    const val VOLUME_KEY = "stremiox.playerVolume"
    const val MUTED_KEY = "stremiox.playerMuted"
    const val DEFAULT_VOLUME = 100.0

    /** The coarse picker steps (Apple `playerVolumeSteps`), plus the exact current level when off-step. */
    fun pickerSteps(context: Context): List<Int> {
        val base = listOf(0, 25, 50, 75, 100)
        val current = volume(context).roundToInt()
        return if (base.contains(current)) base else (base + current).sorted()
    }

    /** The persisted default volume 0..100, defaulting to 100 (Apple's default). */
    fun volume(context: Context): Double =
        parityPrefs(context).getFloat(VOLUME_KEY, DEFAULT_VOLUME.toFloat()).toDouble().coerceIn(0.0, 100.0)

    fun setVolume(context: Context, volume0to100: Double) {
        parityPrefs(context).edit().putFloat(VOLUME_KEY, volume0to100.coerceIn(0.0, 100.0).toFloat()).apply()
    }

    /** The persisted mute state, defaulting to false (Apple's default). */
    fun muted(context: Context): Boolean = parityPrefs(context).getBoolean(MUTED_KEY, false)

    fun setMuted(context: Context, muted: Boolean) {
        parityPrefs(context).edit().putBoolean(MUTED_KEY, muted).apply()
    }
}

// ---------------------------------------------------------------------------------------------------
// StillWatchingSettings - Apple @AppStorage("vortx.stillWatchingPrompt")=true / (...AfterEpisodes)=4
// ---------------------------------------------------------------------------------------------------

/**
 * The "Still watching?" idle / binge guard, the Android port of Apple's `vortx.stillWatchingPrompt`
 * (Bool, default true) and `vortx.stillWatchingAfterEpisodes` (Int, default 4). When enabled the player
 * pauses and asks after a long idle stretch OR after N back-to-back auto-advanced episodes with no
 * interaction; Continue resumes (or rolls to the pending next episode), Stop leaves the player. Any
 * interaction re-arms the idle deadline and clears the auto-advance streak.
 *
 * Mirrors app/Sources/PlayerScreen.swift: `idleWatchTimeout` (4h), the 15s poll, and the binge boundary
 * `consecutiveAutoAdvances >= max(1, stillWatchingAfterEpisodes)`.
 */
object StillWatchingSettings {
    const val PROMPT_KEY = "vortx.stillWatchingPrompt"
    const val AFTER_EPISODES_KEY = "vortx.stillWatchingAfterEpisodes"
    const val DEFAULT_AFTER_EPISODES = 4

    /** No-interaction stretch before the idle prompt fires (Apple `idleWatchTimeout` = 4h). */
    const val IDLE_TIMEOUT_MS = 4L * 60 * 60 * 1000

    /** Idle-watch poll cadence (Apple sleeps 15s between checks). */
    const val IDLE_POLL_MS = 15_000L

    /** The episode-count choices Settings offers (iOSSettingsView.swift:751). */
    val afterEpisodesChoices: List<Int> = listOf(2, 3, 4, 5, 6, 8, 10)

    /** Whether the prompt is armed. Defaults to ON, matching Apple. */
    fun promptEnabled(context: Context): Boolean = parityPrefs(context).getBoolean(PROMPT_KEY, true)

    fun setPromptEnabled(context: Context, enabled: Boolean) {
        parityPrefs(context).edit().putBoolean(PROMPT_KEY, enabled).apply()
    }

    /** The binge threshold, defaulting to 4 (Apple's default), floored at 1 like Apple's `max(1, …)`. */
    fun afterEpisodes(context: Context): Int =
        parityPrefs(context).getInt(AFTER_EPISODES_KEY, DEFAULT_AFTER_EPISODES).coerceAtLeast(1)

    fun setAfterEpisodes(context: Context, count: Int) {
        parityPrefs(context).edit().putInt(AFTER_EPISODES_KEY, count).apply()
    }
}
