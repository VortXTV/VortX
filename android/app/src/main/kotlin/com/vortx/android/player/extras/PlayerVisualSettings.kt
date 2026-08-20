package com.vortx.android.player.extras

import android.content.Context
import android.hardware.display.DisplayManager
import android.view.Display
import com.vortx.android.player.VideoScaleMode

/**
 * Small device-scoped player visual settings that the Apple player persists and the Android player did not
 * yet. Each keeps Apple's EXACT persistence key and value strings (the same-key mandate) in the shared
 * `vortx_settings` [android.content.SharedPreferences] file, so a choice made on Apple or web rides the same
 * cross-device settings blob and takes effect here with no UI involved.
 */
private const val SETTINGS_FILE = "vortx_settings"

private fun prefs(context: Context) =
    context.applicationContext.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)

/**
 * Persisted aspect-ratio / zoom mode, the Android port of Apple's `@AppStorage("stremiox.videoSize")`
 * (default "original"). Apple stores three raw strings: "original" (whole frame at correct aspect),
 * "fill" (crop to screen), "stretch" (distort to fill); those map one-to-one onto Android's
 * [VideoScaleMode] FIT / ZOOM / STRETCH. Reading it at player start means the viewer's last choice is
 * restored instead of snapping back to Fit every title, exactly as Apple's `@AppStorage` restores it.
 */
object AspectRatioSetting {
    const val KEY = "stremiox.videoSize"

    const val ORIGINAL = "original"
    const val FILL = "fill"
    const val STRETCH = "stretch"

    fun toStorage(mode: VideoScaleMode): String = when (mode) {
        VideoScaleMode.FIT -> ORIGINAL
        VideoScaleMode.ZOOM -> FILL
        VideoScaleMode.STRETCH -> STRETCH
    }

    fun fromStorage(raw: String?): VideoScaleMode = when (raw) {
        FILL -> VideoScaleMode.ZOOM
        STRETCH -> VideoScaleMode.STRETCH
        else -> VideoScaleMode.FIT // "original" / unset
    }

    /** The persisted mode, defaulting to [VideoScaleMode.FIT] (Apple's "original"). */
    fun current(context: Context): VideoScaleMode = fromStorage(prefs(context).getString(KEY, null))

    /** Persist the chosen mode under Apple's key. */
    fun setCurrent(context: Context, mode: VideoScaleMode) {
        prefs(context).edit().putString(KEY, toStorage(mode)).apply()
    }
}

/**
 * "Auto-rotate to landscape in the player", the Android port of Apple's
 * `@AppStorage("stremiox.autoLandscapeInPlayer")` (default true). When ON, opening a non-trailer stream turns
 * the phone to landscape (both landscape orientations, following the sensor), matching the video's shape, and
 * releases the lock when the player closes. When OFF the player keeps the device's current orientation. A
 * no-op on TV, which is always landscape. Apple forces landscape for every non-trailer play; this mirrors that.
 */
object AutoLandscapeSetting {
    const val KEY = "stremiox.autoLandscapeInPlayer"

    /** Whether to auto-rotate. Defaults to ON, matching Apple. */
    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY, enabled).apply()
    }
}

/**
 * "Keep playing in the background", the Android port of Apple's `@AppStorage("stremiox.keepPlayingInBackground")`
 * (default true). When ON the player does not pause on backgrounding, so audio keeps going with the screen off
 * or the app behind another (the libmpv engine additionally drops video decode off-screen to save power, the
 * ExoPlayer engine keeps decoding audio with no surface). When OFF the player pauses on background as before.
 *
 * HONEST LIMITATION, stated so this is not mistaken for parity: iOS keeps a backgrounded app's audio alive
 * through its audio session, so Apple's setting continues indefinitely. Android suspends a backgrounded app
 * that owns no foreground service, and VortX runs no media foreground service yet (see PlayerMediaSession),
 * so here the audio continues until the OS freezes the process and then resumes when the app returns. The
 * setting and the client-side gate are real; indefinite background playback is a separate service-layer piece.
 */
object KeepPlayingBackgroundSetting {
    const val KEY = "stremiox.keepPlayingInBackground"

    /** Whether to keep playing on background. Defaults to ON, matching Apple. */
    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY, enabled).apply()
    }
}

/** True when the device's default display advertises any HDR output mode. Uses [DisplayManager], which is
 * available from an application context on every supported release (unlike `Context.display`, which needs a
 * UI context on R+). Returns false when the capability cannot be read, so an unknown display never claims
 * HDR. The Android analogue of Apple's `displaySupportsHDR()`. */
fun displaySupportsHdr(context: Context): Boolean {
    val manager = context.applicationContext.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
        ?: return false
    val display = manager.getDisplay(Display.DEFAULT_DISPLAY) ?: return false
    return display.isHdr
}

/**
 * HDR to SDR tone-mapping policy, the Android port of Apple's `@AppStorage("stremiox.hdrToneMapMode")`
 * (default "auto"), including Apple's migration of the older `stremiox.forceSDRTonemap` bool (true -> "on",
 * else "auto"). mpv-only: the libmpv engine tone-maps HDR/DV to SDR pixels via libplacebo, so it honours
 * this; the ExoPlayer / Dolby Vision engine passes HDR through in hardware and the panel decides, so the
 * control is hidden there (an honest no-op, like the other mpv-only rows).
 *
 *   - "auto" (default): tone-map HDR/DV to SDR only when the display cannot actually show HDR, so a non-HDR
 *     screen stops rendering HDR washed-out while a capable screen still gets real HDR.
 *   - "on": always tone-map to SDR (the manual fix for a green/purple DV Profile 7 mis-render).
 *   - "off": never tone-map (always request HDR passthrough).
 */
object HdrToneMapSetting {
    const val KEY = "stremiox.hdrToneMapMode"

    /** Legacy bool Apple migrates from; read only when [KEY] is absent. */
    const val LEGACY_FORCE_SDR_KEY = "stremiox.forceSDRTonemap"

    enum class Mode(val storageValue: String, val label: String, val detail: String) {
        AUTO("auto", "Auto", "Tone-map only on a non-HDR screen"),
        ON("on", "On", "Always tone-map to SDR"),
        OFF("off", "Off", "Always request HDR");

        companion object {
            fun fromStorage(raw: String?): Mode = entries.firstOrNull { it.storageValue == raw } ?: AUTO
        }
    }

    /** The persisted mode, applying Apple's legacy-bool migration when the mode key is absent. */
    fun currentMode(context: Context): Mode {
        val p = prefs(context)
        p.getString(KEY, null)?.let { return Mode.fromStorage(it) }
        return if (p.getBoolean(LEGACY_FORCE_SDR_KEY, false)) Mode.ON else Mode.AUTO
    }

    fun setMode(context: Context, mode: Mode) {
        prefs(context).edit().putString(KEY, mode.storageValue).apply()
    }

    /** Whether the engine should force HDR/DV down to SDR output right now, per the mode + display. */
    fun forceSDR(context: Context): Boolean = when (currentMode(context)) {
        Mode.ON -> true
        Mode.OFF -> false
        Mode.AUTO -> !displaySupportsHdr(context)
    }
}
