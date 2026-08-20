package com.vortx.android.moat

import android.content.Context
import com.vortx.android.player.subtitles.SubtitleSidecarTransport

/**
 * The single "give-to-get" consent gate for VortX's community data pool. The Kotlin port of Apple
 * `app/SourcesShared/MoatConsent.swift`.
 *
 * One master switch governs whether this device both CONTRIBUTES anonymized playback / source metadata to
 * the shared pool AND CONSUMES what the pool gives back. It is the opt-out for the WHOLE pool: turning it OFF
 * stops the device from contributing anything AND from consuming every pooled improvement (community scrub
 * previews, community subtitles, community skip segments, localized metadata, and the community source
 * index). Opt-out means out of the pool entirely, in both directions: there is no take-without-give.
 *
 * The default is ON. On a fresh install with no stored value the key is absent, so presence is checked before
 * the value (identical to the [com.vortx.android.trickplay.CommunityTrickplay] pattern) and an unset install
 * reads as ON.
 *
 * The user-facing disclosure is deliberately GENERIC. It says the app may collect anonymized playback and
 * source metadata to improve results, and nothing about how the pool is structured or used. Every pool
 * contribute + read call site consults [contributeAndConsume] (folded into each client's own feature gate),
 * so this one switch is the whole surface.
 */
object MoatConsent {

    /**
     * The @AppStorage / UserDefaults <-> SharedPreferences key, byte-for-byte Apple's `MoatConsent.key`
     * (`stremiox.moatContribute`). The same key on the same kind of store keeps the setting in parity across
     * platforms and lets a settings backup round-trip byte-for-byte. Uses the `stremiox.` namespace like the
     * other player-adjacent settings so the 0.4 `stremiox.` -> `vortx.` rename seam maps it uniformly.
     */
    const val KEY = "stremiox.moatContribute"

    /**
     * The one-line disclosure shown next to the toggle in Settings, byte-for-byte Apple's
     * `MoatConsent.disclosure`. Generic on purpose: it reveals nothing about the pool's design, only that
     * anonymized playback + source metadata may be collected to improve results. Keep this wording opaque.
     */
    const val DISCLOSURE = "VortX may collect anonymized playback, source metadata, and subtitle dialogue to improve results."

    /**
     * The shared player-adjacent settings file, the same store [com.vortx.android.trickplay.CommunityTrickplay]
     * and the player settings write to, so every give-to-get toggle lives together and a backup covers them all.
     */
    private const val SETTINGS_FILE = "vortx_settings"

    /**
     * The master gate. Default ON: an unset value (fresh install) reads as true because presence is checked
     * before the value, matching Apple's `object(forKey:) == nil -> true`. When it returns false the device is
     * fully out of the pool, in both directions.
     */
    @Volatile private var generation: Long = 0L

    data class Snapshot(val enabled: Boolean, val generation: Long)

    /**
     * Capture one consent authority before asynchronous community work. Callers must compare a fresh
     * [snapshot] before every publication so a revoked choice wins over an already-running request.
     */
    fun snapshot(context: Context): Snapshot = synchronized(this) {
        Snapshot(contributeAndConsume(context), generation)
    }

    fun isCurrent(context: Context, expected: Snapshot): Boolean = synchronized(this) {
        expected.enabled && generation == expected.generation && contributeAndConsume(context)
    }

    fun contributeAndConsume(context: Context): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)
        if (!prefs.contains(KEY)) return false
        return prefs.getBoolean(KEY, false)
    }

    /**
     * Persist the viewer's pool opt-in / opt-out under the SAME [KEY] Apple writes, in the SAME kind of store,
     * so the value round-trips byte-for-byte with Apple and the web. The write side [contributeAndConsume] was
     * always meant to pair with; the settings "anonymized pool" row is its first writer. Once the key exists,
     * [contributeAndConsume] returns the stored value instead of the unset default (on).
     */
    fun setContribute(context: Context, enabled: Boolean) {
        synchronized(this) {
            context.applicationContext
                .getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY, enabled)
                .apply()
            generation += 1L
            if (!enabled) SubtitleSidecarTransport.clear(context.applicationContext)
        }
    }
}
