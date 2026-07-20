package com.vortx.android.player

import android.app.ActivityManager
import android.content.Context
import java.io.File
import kotlin.math.roundToInt

/**
 * Player-side settings models, the Android port of Apple's four small player-settings value types:
 * `SubtitleStyle.swift`, `AudioOutputMode.swift`, `DiskCacheSetting.swift`, and `PerformanceMode.swift`.
 *
 * Each keeps Apple's persistence keys and value encoding, so a value rides the same cross-device
 * settings-backup blob once `SettingsBackup` is ported (identical to how [com.vortx.android.model
 * .TrackPreferencesStore] mirrors Apple's `UserDefaults` keys). Persistence uses the shared
 * `vortx_settings` [android.content.SharedPreferences] file (the direct analogue of Apple `UserDefaults`).
 *
 * Each model is a read side (`current(context)`) plus a symmetric write side used by the Round 6 Settings
 * UI ([com.vortx.android.ui.screens.PlaybackSettingsScreen]). The engines read the persisted value at LOAD
 * time and apply it, so a change made in Settings takes effect on the next play, and a synced/backed-up
 * choice takes effect with no UI involved at all.
 */
private const val SETTINGS_FILE = "vortx_settings"

private fun prefs(context: Context) =
    context.applicationContext.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)

// ---------------------------------------------------------------------------------------------------
// SubtitleStyle - Apple app/Sources/Player/SubtitleStyle.swift
// ---------------------------------------------------------------------------------------------------

/**
 * User-tunable subtitle appearance, applied to BOTH engines: libmpv via `sub-*` properties/options and
 * ExoPlayer via its `SubtitleView` `CaptionStyleCompat`. The Android port of Apple `SubtitleStyle`.
 *
 * mpv colour note (kept identical to Apple): colours are `#AARRGGBB` (alpha first). Opaque text/border
 * colours use the plain 6-digit `#RRGGBB` form; the subtitle background and shadow use the 8-digit form,
 * where the alpha byte is the whole point.
 *
 * DIVERGENCE from Apple: Apple names a BUNDLED face (`sub-font`) because it ships Noto in the app bundle.
 * Android's shipped libmpv artifact carries no bundled face and libass base-font selection is strictly
 * name-based with no wildcard last resort, so naming an unavailable face can render NO subtitles at all.
 * We therefore do NOT emit `sub-font` here (MpvConfig ships `embeddedfonts=yes` + `subs-fallback=yes` so
 * in-container fonts and the libass default still render); the Modern look comes from the thin-outline +
 * shadow treatment, not the face, exactly as Apple documents.
 */
data class SubtitleStyle(
    val fontId: String,
    val sizeId: String,
    val sizeScale: Double,
    val colorId: String,
    val backgroundId: String,
) {
    /** The named base size times the fine multiplier, the value handed to mpv's `sub-font-size`. */
    val fontSize: Int get() = (baseFontSize(sizeId) * sizeScale).roundToInt()

    /** Opaque subtitle text colour as an `#RRGGBB` hex string. */
    val colorHex: String get() = colorHexFor(colorId)

    /** Modern (streaming-service look: thin outline + soft shadow) vs Classic (heavier border). */
    val isModern: Boolean get() = fontId == MODERN

    /**
     * mpv property/option name -> value pairs realizing the current style. Applied both at player setup
     * (as options, before init) and live (as properties). Every option that differs between font styles
     * appears in both branches, so a live switch fully overwrites the previous one. Mirrors Apple
     * `mpvOptions`, minus `sub-font` (see the class doc for why Android omits the face name).
     */
    fun mpvOptions(): List<Pair<String, String>> {
        val opts = mutableListOf(
            "sub-font-size" to fontSize.toString(),
            "sub-color" to colorHex,
            "sub-border-color" to "#000000",
        )
        if (isModern) {
            // Thin outline plus a soft offset shadow carries the contrast instead of a heavy border.
            opts += "sub-border-size" to "2"
            opts += "sub-shadow-offset" to "2"
            opts += "sub-shadow-color" to "#80000000"
        } else {
            opts += "sub-border-size" to "3"
            opts += "sub-shadow-offset" to "0"
            opts += "sub-shadow-color" to "#00000000"
        }
        opts += when (backgroundId) {
            SHADED -> "sub-back-color" to "#80000000" // ~50% black box
            BOX -> "sub-back-color" to "#FF000000"    // opaque black box
            else -> "sub-back-color" to "#00000000"   // outline only (transparent)
        }
        return opts
    }

    // ExoPlayer helpers (CaptionStyleCompat is built in ExoPlayerEngine from these primitive values, so
    // this model stays free of Media3 UI types).

    /** Opaque ARGB int for the subtitle text colour. */
    val foregroundColorArgb: Int get() = parseOpaqueHex(colorHex)

    /** ARGB int for the text-background box: transparent for outline-only, else the shaded/box alpha. */
    val backgroundColorArgb: Int
        get() = when (backgroundId) {
            SHADED -> 0x80000000.toInt()
            BOX -> 0xFF000000.toInt()
            else -> 0x00000000
        }

    /** Fractional text height for ExoPlayer's `SubtitleView.setFractionalTextSize`, scaled by [sizeScale]. */
    val exoTextSizeFraction: Float get() = (baseTextFraction(sizeId) * sizeScale).toFloat()

    companion object {
        // UserDefaults/SharedPreferences keys, byte-for-byte Apple's so a backup round-trips.
        const val KEY_FONT = "stremiox.sub.font"
        const val KEY_SIZE = "stremiox.sub.size"
        const val KEY_SIZE_SCALE = "stremiox.sub.sizeScale"
        const val KEY_COLOR = "stremiox.sub.color"
        const val KEY_BACKGROUND = "stremiox.sub.background"

        const val MODERN = "modern"
        const val SHADED = "shaded"
        const val BOX = "box"

        const val DEFAULT_FONT = MODERN
        const val DEFAULT_SIZE = "m"
        const val DEFAULT_COLOR = "white"
        const val DEFAULT_BACKGROUND = "outline"

        val SIZE_SCALE_RANGE = 0.60..1.80

        /** Fine +/- step on top of the named size. Apple `SubtitleStyle.sizeScaleStep`. */
        const val SIZE_SCALE_STEP = 0.10

        // The choices surfaced in Settings, ported from Apple `SubtitleStyle.fonts/sizes/colors/backgrounds`.
        // `id` is what persists, so these ids are Apple's and must not drift. Labels are Apple's copy.
        // Note the Modern/Classic split is a treatment here, not a face: this port deliberately does not
        // emit `sub-font` (see the divergence note on the class doc), so the ids still round-trip but the
        // look comes from the outline + shadow treatment.
        val fonts: List<Pair<String, String>> = listOf(
            MODERN to "Modern",
            "classic" to "Classic",
        )
        val sizes: List<Pair<String, String>> = listOf(
            "s" to "Small", "m" to "Medium", "l" to "Large", "xl" to "Extra Large",
        )
        val colors: List<Pair<String, String>> = listOf(
            "white" to "White", "yellow" to "Yellow", "soft" to "Soft",
        )
        val backgrounds: List<Pair<String, String>> = listOf(
            "outline" to "Outline only", SHADED to "Shaded", BOX to "Solid box",
        )

        /** Named base sizes -> mpv `sub-font-size` value (px on a ~1080p canvas), matching Apple. */
        private fun baseFontSize(id: String): Int = when (id) {
            "s" -> 40
            "l" -> 72
            "xl" -> 92
            else -> 55 // "m"
        }

        /** Named base sizes -> ExoPlayer fractional text height (fraction of view height). */
        private fun baseTextFraction(id: String): Double = when (id) {
            "s" -> 0.045
            "l" -> 0.070
            "xl" -> 0.090
            else -> 0.0533 // "m" ~ SubtitleView.DEFAULT_TEXT_SIZE_FRACTION
        }

        private fun colorHexFor(id: String): String = when (id) {
            "yellow" -> "#FFFF00"
            "soft" -> "#F2F2F2"
            else -> "#FFFFFF" // "white"
        }

        /** Parse `#RRGGBB` (or `#AARRGGBB`) into an opaque ARGB int. */
        private fun parseOpaqueHex(hex: String): Int {
            val clean = hex.removePrefix("#")
            val rgb = clean.takeLast(6).toLongOrNull(16) ?: 0xFFFFFF
            return (0xFF000000 or rgb).toInt()
        }

        /** The persisted style, defaulting to Apple's defaults for any absent key. */
        fun current(context: Context): SubtitleStyle {
            val p = prefs(context)
            val rawScale = if (p.contains(KEY_SIZE_SCALE)) p.getFloat(KEY_SIZE_SCALE, 1.0f).toDouble() else 1.0
            val scale = rawScale.coerceIn(SIZE_SCALE_RANGE.start, SIZE_SCALE_RANGE.endInclusive)
            return SubtitleStyle(
                fontId = p.getString(KEY_FONT, DEFAULT_FONT) ?: DEFAULT_FONT,
                sizeId = p.getString(KEY_SIZE, DEFAULT_SIZE) ?: DEFAULT_SIZE,
                sizeScale = scale,
                colorId = p.getString(KEY_COLOR, DEFAULT_COLOR) ?: DEFAULT_COLOR,
                backgroundId = p.getString(KEY_BACKGROUND, DEFAULT_BACKGROUND) ?: DEFAULT_BACKGROUND,
            )
        }

        /**
         * Persist [style] under Apple's keys. The write side of [current], used by the Settings UI.
         *
         * [SubtitleStyle.sizeScale] is clamped to [SIZE_SCALE_RANGE] and rounded to 0.01 on the way IN,
         * mirroring Apple's `subSizeScaleBinding` (iOSSettingsView.swift:1386) which clamps then rounds
         * before storing. Doing it here rather than in the UI means a bad value cannot reach the engine
         * regardless of which caller wrote it. [current] also clamps on read, so a value written by an
         * older build or synced from another platform is still safe.
         */
        fun save(context: Context, style: SubtitleStyle) {
            val clamped = style.sizeScale.coerceIn(SIZE_SCALE_RANGE.start, SIZE_SCALE_RANGE.endInclusive)
            val rounded = (clamped * 100).roundToInt() / 100.0
            prefs(context).edit()
                .putString(KEY_FONT, style.fontId)
                .putString(KEY_SIZE, style.sizeId)
                .putFloat(KEY_SIZE_SCALE, rounded.toFloat())
                .putString(KEY_COLOR, style.colorId)
                .putString(KEY_BACKGROUND, style.backgroundId)
                .apply()
        }
    }
}

// ---------------------------------------------------------------------------------------------------
// AudioOutputMode - Apple app/Sources/Player/AudioOutputMode.swift
// ---------------------------------------------------------------------------------------------------

/**
 * How the player drives audio output, the escape hatch for soundbars/receivers that mis-negotiate audio.
 * The Android port of Apple `AudioOutputMode`. Device-scoped (describes THIS device's audio hardware),
 * never per-profile.
 *
 * Applied on the libmpv engine, where VortX owns the AO negotiation. On the ExoPlayer engine
 * `DefaultAudioSink` negotiates channel layout / passthrough against `AudioCapabilities` itself and
 * exposes no runtime force, so [com.vortx.android.player.ExoPlayerEngine] documents this as a no-op there
 * (and the router already sends Atmos/passthrough streams to ExoPlayer for exactly that auto-negotiation).
 */
enum class AudioOutputMode(val storageValue: String, val label: String, val detail: String) {
    /** Match the route: multichannel receiver gets surround, anything stereo gets a clean downmix. */
    AUTO("auto", "Auto", "Matches your TV or receiver. Best for most setups."),

    /** Force a guaranteed stereo (2.0) downmix. The reliable fix when a soundbar plays no sound. */
    STEREO("stereo", "Stereo", "Forces a stereo downmix. Choose this if a soundbar or receiver plays no sound."),

    /** Decode Dolby/DTS to multichannel PCM and force it on, for a receiver that under-reports. */
    SURROUND("surround", "Surround", "Decodes Dolby/DTS to multichannel PCM and forces it on."),

    /** Bitstream Dolby/DTS untouched to an AV receiver that decodes them itself (best-effort on mpv). */
    PASSTHROUGH("passthrough", "Passthrough", "Hands Dolby/DTS to the receiver to decode (best-effort).");

    /**
     * mpv property/option name -> value pairs for this mode. `audio-channels` picks the downmix/upmix
     * target; PASSTHROUGH additionally arms `audio-spdif` so mpv bitstreams the listed codecs (falling
     * back to a decode if the route can't take the bitstream, so it never goes silent). Mirrors Apple's
     * `spdifCodecs`/channel policy split, adapted to mpv's Android AO.
     */
    fun mpvOptions(): List<Pair<String, String>> = when (this) {
        AUTO -> listOf("audio-channels" to "auto-safe")
        STEREO -> listOf("audio-channels" to "stereo")
        SURROUND -> listOf("audio-channels" to "auto")
        PASSTHROUGH -> listOf(
            "audio-spdif" to "ac3,dts,eac3,truehd,dts-hd",
            "audio-channels" to "auto",
        )
    }

    companion object {
        const val KEY = "stremiox.audioOutputMode"

        fun fromStorage(raw: String?): AudioOutputMode? = entries.firstOrNull { it.storageValue == raw }

        /** The persisted mode, defaulting to [AUTO] (Apple's default). */
        fun current(context: Context): AudioOutputMode =
            fromStorage(prefs(context).getString(KEY, null)) ?: AUTO

        /** Persist [mode]. The write side of [current], used by the Settings UI. */
        fun setCurrent(context: Context, mode: AudioOutputMode) {
            prefs(context).edit().putString(KEY, mode.storageValue).apply()
        }
    }
}

// ---------------------------------------------------------------------------------------------------
// DiskCacheSetting - Apple app/Sources/Player/DiskCacheSetting.swift
// ---------------------------------------------------------------------------------------------------

/**
 * User-configurable on-disk streaming/seek cache for libmpv. The Android port of Apple `DiskCacheSetting`.
 *
 * libmpv keeps a forward read-ahead buffer (`demuxer-max-bytes`) so the play head can run ahead of the
 * network. By default that buffer lives in RAM, which on a jetsam-bound Android device is tightly capped.
 * This setting moves the big buffer to an ON-DISK cache (`cache-on-disk=yes` + `cache-dir`), so a viewer
 * can pick a large forward buffer WITHOUT spending RAM.
 *
 * CRITICAL SAFETY (Apple's two owner guardrails, ported faithfully):
 *   1. Unbounded growth is impossible: any large/UNLIMITED value is still capped at a fraction of CURRENT
 *      FREE DISK at the moment the player starts ([resolvedMaxBytes]), recomputed every load.
 *   2. A finished title does not persist: the cache dir is wiped on a genuine playback exit (the mpv
 *      engine's `release`), so a crash can never leave an unbounded cache behind.
 *
 * Ships OFF by default (opt-in), matching Apple: the on-disk cache is the same mechanism that crashed
 * Apple TVs at ~21s into 4K remuxes, so it stays off until soak-tested on real hardware.
 */
object DiskCacheSetting {
    const val KEY = "stremiox.diskCacheBytes"

    const val GIB: Long = 1024L * 1024 * 1024
    const val UNLIMITED_SENTINEL: Long = -1

    /** OFF still needs a tiny forward buffer so playback is not starved. */
    const val OFF_FLOOR_BYTES: Long = 64L * 1024 * 1024 // 64 MiB

    /** Never let the cache consume more than half of FREE disk, even for UNLIMITED or a huge literal. */
    const val FREE_DISK_FRACTION: Double = 0.5

    /** Hard ceiling on a constrained device even when disk-backed. */
    const val CONSTRAINED_CEILING_BYTES: Long = 2 * GIB

    /** Fallback budget when free space can't be read (NOT the unset default, which is OFF). */
    const val DEFAULT_BYTES: Long = 2 * GIB

    /** The viewer's stored choice as a raw byte count (or a sentinel). Defaults to OFF (0) when unset. */
    fun storedBytes(context: Context): Long = prefs(context).getLong(KEY, 0L)

    fun setStoredBytes(context: Context, bytes: Long) {
        prefs(context).edit().putLong(KEY, bytes).apply()
    }

    fun isOff(context: Context): Boolean = storedBytes(context) == 0L
    fun isUnlimited(context: Context): Boolean = storedBytes(context) == UNLIMITED_SENTINEL

    /** Whether the on-disk cache should be armed at all. OFF keeps mpv on its in-memory buffer. */
    fun diskCacheEnabled(context: Context): Boolean = !isOff(context)

    /** On-disk cache location: an app cache subdirectory (the OS may purge it under storage pressure). */
    fun cacheDirectory(context: Context): File =
        File(context.applicationContext.cacheDir, "mpv-cache")

    /** Ensure the cache directory exists; returns its path for `cache-dir`, or null on failure. */
    fun ensureCacheDirectory(context: Context): String? {
        val dir = cacheDirectory(context)
        return if (dir.exists() || dir.mkdirs()) dir.absolutePath else null
    }

    /** Free bytes on the volume backing the cache directory, or null if it can't be read. */
    fun freeDiskBytes(context: Context): Long? =
        runCatching { cacheDirectory(context).parentFile?.usableSpace ?: context.cacheDir.usableSpace }
            .getOrNull()
            ?.takeIf { it > 0 }

    /**
     * The ACTUAL byte budget to hand mpv right now, after every safety clamp. Recomputed per played file
     * so it always reflects CURRENT free space, never a stale snapshot. Pure given ([context] free-disk +
     * [reduced]), so it is testable. Mirrors Apple `resolvedMaxBytes`.
     */
    fun resolvedMaxBytes(context: Context, reduced: Boolean): Long {
        val stored = storedBytes(context)
        if (stored == 0L) return OFF_FLOOR_BYTES

        val freeCeiling = freeDiskBytes(context)?.let { (it * FREE_DISK_FRACTION).toLong() } ?: DEFAULT_BYTES

        var budget = if (stored == UNLIMITED_SENTINEL) freeCeiling else minOf(stored, freeCeiling)
        if (reduced) budget = minOf(budget, CONSTRAINED_CEILING_BYTES)
        return maxOf(budget, OFF_FLOOR_BYTES)
    }

    /**
     * mpv option pairs arming the on-disk cache: `cache-on-disk=yes`, `cache-dir=<path>`. The large
     * `demuxer-max-bytes` that fills it is set per-file by the player (from [resolvedMaxBytes]). Empty when
     * OFF, or when the cache dir can't be created, so a missing path never disarms playback.
     */
    fun mpvOptions(context: Context): List<Pair<String, String>> {
        if (isOff(context)) return emptyList()
        val dir = ensureCacheDirectory(context) ?: return emptyList()
        return listOf(
            "cache-on-disk" to "yes",
            "cache-dir" to dir,
        )
    }

    /** Delete the cache directory's contents. Called on a genuine playback exit. Best-effort, never throws. */
    fun clearCache(context: Context) {
        runCatching {
            cacheDirectory(context).listFiles()?.forEach { it.deleteRecursively() }
        }
    }

    /** The picker choices, in order. `bytes` is the raw stored value; `label` is the menu text. */
    val pickerOptions: List<Pair<Long, String>> = listOf(
        0L to "Off",
        2 * GIB to "2 GB",
        5 * GIB to "5 GB",
        10 * GIB to "10 GB",
        20 * GIB to "20 GB",
        UNLIMITED_SENTINEL to "Unlimited",
    )

    fun label(bytes: Long): String = when {
        bytes == 0L -> "Off"
        bytes == UNLIMITED_SENTINEL -> "Unlimited"
        else -> "${(bytes / GIB.toDouble()).roundToInt()} GB"
    }
}

// ---------------------------------------------------------------------------------------------------
// PerformanceMode - Apple app/Sources/Player/PerformanceMode.swift
// ---------------------------------------------------------------------------------------------------

/**
 * One switch for a lighter playback path on memory-constrained devices. The Android port of Apple
 * `PerformanceMode`.
 *
 * Apple splits on physical memory (Apple TV HD, ~2 GB) rather than a model list. Android does the same via
 * [ActivityManager.MemoryInfo.totalMem]: a device under ~2.5 GB takes the reduced path. Auto by default,
 * overridable via [OVERRIDE_KEY]. In reduced mode the app keeps the forward buffer tight and (via
 * [DiskCacheSetting.resolvedMaxBytes]) caps the on-disk cache, so a weak CPU stays responsive while
 * decoding + serving.
 */
object PerformanceMode {
    /** SharedPreferences override: "auto" (default), "reduced" (force on), "full" (force off). */
    const val OVERRIDE_KEY = "stremiox.performanceMode"

    /** Apple's 2.5 GB split (Apple TV HD ~2 GB vs every Apple TV 4K 3 GB+); reused for Android. */
    const val CONSTRAINED_MEMORY_THRESHOLD: Long = 2_684_354_560L

    /** True on a memory-constrained device (total RAM below the threshold). */
    fun isConstrainedDevice(context: Context): Boolean {
        val am = context.applicationContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return false
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        return info.totalMem in 1 until CONSTRAINED_MEMORY_THRESHOLD
    }

    /** The effective reduced-mode decision: the explicit override wins, else the device split. */
    fun isReduced(context: Context): Boolean = when (prefs(context).getString(OVERRIDE_KEY, null)) {
        "reduced" -> true
        "full" -> false
        else -> isConstrainedDevice(context) // "auto" / unset
    }

    /**
     * The three choices the Settings picker offers, in Apple's order (iOSSettingsView.swift:1221).
     * [storageValue] matches Apple's picker tags, and [isReduced] above already reads those exact strings,
     * so the override the UI writes is the one the engine honours.
     */
    enum class Override(val storageValue: String, val label: String) {
        AUTO("auto", "Auto"),
        FULL("full", "Full"),
        REDUCED("reduced", "Reduced");

        companion object {
            /** Unknown/absent reads back as [AUTO], matching [isReduced]'s `else` branch. */
            fun fromStorage(raw: String?): Override =
                entries.firstOrNull { it.storageValue == raw } ?: AUTO
        }
    }

    /** The persisted override (not the effective decision, which is [isReduced]). */
    fun currentOverride(context: Context): Override =
        Override.fromStorage(prefs(context).getString(OVERRIDE_KEY, null))

    /** Persist the [Override] the viewer picked. */
    fun setOverride(context: Context, override: Override) {
        prefs(context).edit().putString(OVERRIDE_KEY, override.storageValue).apply()
    }
}

// ---------------------------------------------------------------------------------------------------
// AutoAddLibrarySetting - Apple @AppStorage("stremiox.autoAddLibrary")
// ---------------------------------------------------------------------------------------------------

/**
 * "Auto-add watched to Library": once playback of a title crosses ~60s it is added to the Library.
 * Default ON, byte-for-byte Apple's key and default (`@AppStorage("stremiox.autoAddLibrary") = true`,
 * app/Sources/PlayerScreen.swift:212 and app/SourcesTV/TVPlayerView.swift:50), so the value rides the same
 * cross-device settings blob as the sibling `stremiox.*` keys in this file once `SettingsBackup` is ported.
 *
 * Apple surfaces this as a Toggle on BOTH of its settings surfaces (iOSSettingsView.swift:594 and
 * SourcesTV/SettingsView.swift:92). Android READ this key at the 60s tick
 * ([com.vortx.android.ui.StremioXApp]) while offering no control to write it, so the behaviour was
 * permanently pinned to its default and a viewer could not turn it off. That is a settings-parity break,
 * hence this object plus the Library toggle on [com.vortx.android.ui.screens.PlaybackSettingsScreen].
 *
 * It lives here, next to the other `stremiox.*` values, so the key string is defined EXACTLY once: the read
 * side (the playback tick) and the write side (Settings) resolve to the same constant instead of two
 * literals that can silently drift apart.
 *
 * Read at fire time rather than at composition, so a change made in Settings takes effect on the very next
 * tick, which is the behaviour Apple gets for free from `@AppStorage` being an observed binding.
 */
object AutoAddLibrarySetting {
    const val KEY = "stremiox.autoAddLibrary"

    /** Whether auto-add is armed. Defaults to ON, matching Apple. */
    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY, true)

    /** Persist the viewer's choice. The write side of [isEnabled], used by the Settings UI. */
    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY, enabled).apply()
    }
}

// ---------------------------------------------------------------------------------------------------
// BadSourceAutoRetrySetting - kill switch for the bad-source auto-retry ladder
// ---------------------------------------------------------------------------------------------------

/**
 * Kill switch for the bad-source AUTO-RETRY ladder (the playback-routing half of the trust fix): when a
 * source is judged bad in the player (dead link, stall, or a runtime-mismatch junk file), the phone
 * shell automatically tries the next ranked source, and after 3 failed sources surfaces manual
 * selection. DEFAULT ON. Flipping it off restores the pre-ladder recovery (the error overlay's manual
 * "Choose another source"), for the same reason [com.vortx.android.engine.VortxServer.FLAG_KEY] exists:
 * a routing change this material needs a settings-level kill that requires no new build.
 *
 * DELIBERATELY NOT GATED by this flag: the runtime-mismatch CORRECTNESS itself -- never marking a
 * junk-length file watched, never firing auto-advance off its EOF, never scrobbling it as watched.
 * That lives inside [com.vortx.android.player.PlayerScreen] unconditionally; a kill switch that could
 * turn "10 seconds counts as watched" back on would defeat the fix.
 */
object BadSourceAutoRetrySetting {
    const val KEY = "vortx.player.badSourceAutoRetry"

    /** Whether the auto-retry ladder is armed. Read when the player is wired, per play. */
    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY, true)

    /** Persist the choice (no Settings UI yet; the key is flippable via the shared settings file). */
    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY, enabled).apply()
    }
}
