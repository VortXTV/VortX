package com.vortx.android.model

import android.content.Context
import android.content.res.Resources

/**
 * Player audio/subtitle auto-selection preferences plus the video upscaling preset. The Android port of
 * Apple `app/Sources/Player/TrackPreferences.swift` (the `TrackPreferences` struct, its `ForcedPolicy`
 * enum, the `VideoUpscaling` preset enum, and the `PlaybackSettings.videoUpscaling` persistence).
 *
 * Persistence uses [android.content.SharedPreferences] (the direct analogue of Apple's `UserDefaults`,
 * and the pattern the sibling `SearchHistoryStore`/`AuthIdentityStore` ports already use). The stored keys
 * and value encoding (comma-joined language lists, the raw enum storage strings) MATCH Apple's keys so the
 * values ride the same cross-device settings-backup blob (`doc.settings`) once `SettingsBackup` is ported.
 */
data class TrackPreferences(
    /** Preferred languages in priority order, as ISO codes (e.g. ["en", "ja"]). */
    val audioLanguages: List<String>,
    val subtitleLanguages: List<String>,
    /** What subtitles to show when you DID get your preferred audio language. */
    val forcedPolicy: ForcedPolicy,
    /** Track titles containing any of these (case-insensitive) are never auto-picked (e.g. "commentary"). */
    val rejectTerms: List<String>,
) {
    /** Subtitle policy once the preferred audio language was obtained. Storage strings match Apple's rawValues. */
    enum class ForcedPolicy(val storageValue: String, val label: String) {
        OFF("off", "Off"),               // never auto-show subtitles once you have your audio language
        FORCED("forced", "Forced only"), // only forced subtitles (foreign-dialogue captions)
        ALWAYS("always", "Always on");   // always show full subtitles in your language

        companion object {
            /** Apple defaults to `.forced` when the stored value is absent/unknown. */
            fun fromStorage(raw: String?): ForcedPolicy =
                entries.firstOrNull { it.storageValue == raw } ?: FORCED
        }
    }

    companion object {
        /** Curated language choices for the settings UI (first = stored ISO code). Mirrors Apple `commonLanguages`. */
        val commonLanguages: List<Pair<String, String>> = listOf(
            "en" to "English", "es" to "Spanish", "fr" to "French", "de" to "German",
            "it" to "Italian", "pt" to "Portuguese", "hi" to "Hindi", "ja" to "Japanese",
            "ko" to "Korean", "zh" to "Chinese", "ar" to "Arabic", "ru" to "Russian",
            "tr" to "Turkish", "nl" to "Dutch", "pl" to "Polish", "sv" to "Swedish",
        )

        /** The device's preferred languages as ISO codes, deduplicated, used as the default. Mirrors Apple `deviceLanguages`. */
        val deviceLanguages: List<String>
            get() {
                val seen = LinkedHashSet<String>()
                val locales = Resources.getSystem().configuration.locales
                for (i in 0 until locales.size()) {
                    val code = locales[i].language.lowercase()
                    if (code.isNotEmpty()) seen.add(code)
                }
                return if (seen.isEmpty()) listOf("en") else seen.toList()
            }
    }
}

/**
 * Video upscaling / quality preset, mapped to libmpv (gpu-next / libplacebo) scaler + debanding options.
 * The Android port of Apple `VideoUpscaling`. Applied as a BASELINE during player setup; `.standard` is
 * intentionally a no-op (keeps VortX's existing sharp libplacebo default). Storage strings match Apple's
 * rawValues so a synced/backed-up value round-trips across platforms.
 */
enum class VideoUpscaling(val storageValue: String, val label: String, val detail: String) {
    PERFORMANCE("performance", "Performance", "Fastest. Best for a constrained device or to save battery."),
    STANDARD("standard", "Standard", "Sharp default with debanding. Recommended for most devices."),
    HIGH_QUALITY("highQuality", "High Quality", "Sharper upscaling for capable GPUs. Heavier; not for weak hardware."),
    ANIME4K("anime4k", "Anime4K", "Anime-tuned neural upscaling. Very GPU-heavy. Use on animation only.");

    /** mpv option (key, value) pairs for this preset, applied during player setup. `.standard` is empty (baseline untouched). */
    val mpvOptions: List<Pair<String, String>>
        get() = when (this) {
            STANDARD -> emptyList()
            PERFORMANCE -> listOf(
                "scale" to "bilinear", "cscale" to "bilinear", "dscale" to "bilinear",
                "deband" to "no", "dither-depth" to "no",
            )
            HIGH_QUALITY -> listOf(
                "scale" to "ewa_lanczossharp", "cscale" to "ewa_lanczossharp", "dscale" to "mitchell",
                "deband" to "yes", "deband-iterations" to "2", "dither-depth" to "auto",
            )
            ANIME4K -> listOf(
                "scale" to "bilinear", "cscale" to "bilinear", "dscale" to "bilinear", "deband" to "no",
            )
        }

    /**
     * Ordered file names of the bundled Anime4K shader chain (Mode A: restore + upscale, Medium CNN
     * variants), resolved from the app's shaders folder at runtime. Order is significant. Empty otherwise.
     */
    val glslShaderFileNames: List<String>
        get() = when (this) {
            ANIME4K -> listOf(
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl",
            )
            else -> emptyList()
        }

    companion object {
        fun fromStorage(raw: String?): VideoUpscaling? = entries.firstOrNull { it.storageValue == raw }
    }
}

/**
 * SharedPreferences-backed accessor for [TrackPreferences] and [VideoUpscaling], the Android analogue of
 * Apple's `TrackPreferences.current`/`.save()` and `PlaybackSettings.videoUpscaling` (both on `UserDefaults`).
 *
 * [isConstrainedDevice] stands in for Apple `PerformanceMode.isConstrainedDevice` (not yet ported to Android
 * per the parity map). It defaults to `false` so a caller can inject the real value once `PerformanceMode`
 * lands, preserving Apple's constrained-device fallbacks (Anime4K -> Performance, and the per-device default).
 */
class TrackPreferencesStore(
    context: Context,
    private val isConstrainedDevice: Boolean = false,
) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /** Current preferences: device languages plus sensible defaults until the user customizes them. */
    val current: TrackPreferences
        get() = TrackPreferences(
            audioLanguages = list(prefs.getString(KEY_AUDIO, null)) ?: TrackPreferences.deviceLanguages,
            subtitleLanguages = list(prefs.getString(KEY_SUBTITLE, null)) ?: TrackPreferences.deviceLanguages,
            forcedPolicy = TrackPreferences.ForcedPolicy.fromStorage(prefs.getString(KEY_FORCED, null)),
            rejectTerms = list(prefs.getString(KEY_REJECT, null)) ?: listOf("commentary", "sdh"),
        )

    fun save(p: TrackPreferences) {
        prefs.edit()
            .putString(KEY_AUDIO, p.audioLanguages.joinToString(","))
            .putString(KEY_SUBTITLE, p.subtitleLanguages.joinToString(","))
            .putString(KEY_FORCED, p.forcedPolicy.storageValue)
            .putString(KEY_REJECT, p.rejectTerms.joinToString(","))
            .apply()
    }

    /**
     * Video upscaling preset. Default is hardware-aware: a constrained device gets [VideoUpscaling.PERFORMANCE],
     * everything else [VideoUpscaling.STANDARD]. A constrained device never actually runs Anime4K even if the
     * stored value (or a synced profile) selected it. Mirrors Apple `PlaybackSettings.videoUpscaling`.
     */
    var videoUpscaling: VideoUpscaling
        get() {
            val stored = VideoUpscaling.fromStorage(prefs.getString(KEY_UPSCALING, null))
            if (stored != null) {
                if (stored == VideoUpscaling.ANIME4K && isConstrainedDevice) return VideoUpscaling.PERFORMANCE
                return stored
            }
            return if (isConstrainedDevice) VideoUpscaling.PERFORMANCE else VideoUpscaling.STANDARD
        }
        set(value) {
            prefs.edit().putString(KEY_UPSCALING, value.storageValue).apply()
        }

    /**
     * Preferred trailer AUDIO languages (ISO-639-1 base codes, priority order) for selecting the matching
     * audio track when a trailer ships MULTIPLE audio languages: the explicit trailer-language override first
     * (when set), then the preferred audio languages, then the device languages. Deduped, lowercased, never
     * empty. Mirrors Apple `TrackPreferences.trailerAudioLanguages`.
     */
    val trailerAudioLanguages: List<String>
        get() {
            val seen = LinkedHashSet<String>()
            val out = ArrayList<String>()
            fun add(raw: String?) {
                if (raw.isNullOrEmpty()) return
                val code = raw.substringBefore('-').lowercase()
                if (code.isNotEmpty() && seen.add(code)) out.add(code)
            }
            add(prefs.getString(KEY_TRAILER_LANG, null)?.takeIf { it.isNotEmpty() })
            current.audioLanguages.forEach { add(it) }
            TrackPreferences.deviceLanguages.forEach { add(it) }
            return if (out.isEmpty()) listOf("en") else out
        }

    /** Split a comma list into trimmed, lowercased, non-empty codes; null when nothing usable. Mirrors Apple `list()`. */
    private fun list(s: String?): List<String>? {
        if (s.isNullOrEmpty()) return null
        val parts = s.split(",").map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        return parts.ifEmpty { null }
    }

    companion object {
        const val PREFS_FILE = "vortx_settings"
        const val KEY_AUDIO = "stremiox.tracks.audioLangs"
        const val KEY_SUBTITLE = "stremiox.tracks.subLangs"
        const val KEY_FORCED = "stremiox.tracks.forced"
        const val KEY_REJECT = "stremiox.tracks.reject"
        const val KEY_UPSCALING = "stremiox.videoUpscaling"
        const val KEY_TRAILER_LANG = "stremiox.trailerLanguage"
    }
}
