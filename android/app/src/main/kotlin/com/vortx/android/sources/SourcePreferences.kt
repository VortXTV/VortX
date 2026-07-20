package com.vortx.android.sources

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.engine.StreamRanking

/// The source categories the ranking system recognises. [MEDIA_SERVER] is FIRST so [allCases] (the
/// fresh-install default order) puts your own servers at the top, which is what a person who connects one
/// expects. The Android port of Apple `SourceType`: [storageValue] matches Apple's raw values so the
/// comma-joined order string lines up field-for-field across platforms.
enum class SourceType(val storageValue: String, val label: String, val detail: String) {
    MEDIA_SERVER("mediaServer", "My Servers", "Direct play from your Plex, Jellyfin, and Emby servers"),
    DEBRID("debrid", "Debrid", "Real-Debrid, AllDebrid, Premiumize, TorBox, Debrid-Link"),
    USENET("usenet", "Usenet", "NZB / Usenet sources"),
    TORRENT("torrent", "Torrent", "BitTorrent info-hash streams"),
    DIRECT("direct", "Direct", "Plain HTTP/HTTPS streams from add-ons");

    companion object {
        /// Declared order == the fresh-install default type priority (Apple `SourceType.allCases`).
        val allCases: List<SourceType> get() = entries.toList()

        fun fromStorage(raw: String): SourceType? = entries.firstOrNull { it.storageValue == raw }
    }
}

/// One-tap source presets that set the quality caps + source-type order together, so a viewer can pick a
/// taste ("biggest/best files" vs "save data") without tuning each control. Mirrors Apple `SourcePreset`.
/// Presets leave the keyword/regex filters and safety mode alone (those are user-owned).
enum class SourcePreset(val storageValue: String, val label: String, val detail: String) {
    BEST_QUALITY(
        "bestQuality", "Best Quality",
        "Highest resolution, no size cap. Best for fast connections and big screens.",
    ),
    BALANCED(
        "balanced", "Balanced",
        "High quality with a sane size cap, so nothing absurdly large auto-plays.",
    ),
    DATA_SAVER(
        "dataSaver", "Data Saver",
        "Caps at 1080p and small files, instant sources only. Best on cellular or a tight plan.",
    ),
}

/// An immutable capture of the ranking-relevant preferences, the Android port of Apple
/// `SourcePreferences.Snapshot`. [StreamRanking] reads a snapshot (never a live mutable store) so the
/// off-thread rank can never race a Settings edit on another thread -- the exact race Apple's frozen
/// snapshot fixes. Compiled regexes are captured too: a [Regex] is immutable + thread-safe for matching.
///
/// [audioLanguages] is folded IN (Apple's ranker reads `TrackPreferences.current` live, but the Android
/// ranker is a context-free `object`, so the audio languages the foreign-audio demotion needs must ride
/// the snapshot). [isKids] carries the Kids-profile guard flag (false until the Profiles layer lands, so
/// the guard is present-but-inactive and default ranking is unchanged).
data class SourcePrefsSnapshot(
    val useAddonOrder: Boolean,
    val typeOrder: List<SourceType>,
    val keywordsAreRegex: Boolean,
    val excludeRegex: Regex?,
    val includeRegex: Regex?,
    val excludeTerms: List<String>,
    val includeTerms: List<String>,
    val preferTerms: List<String>,
    val avoidBehavior: String,
    val autoPickBest: Boolean,
    val safetyMode: String,
    val instantOnly: Boolean,
    val hideDeadTorrents: Boolean,
    val excludeAV1: Boolean,
    val hdrOnly: Boolean,
    val maxResolution: Int,
    val minResolution: Int,
    val hideUnknownResolution: Boolean,
    val preferredAudioOnly: Boolean,
    val maxFileSizeGB: Double,
    val audioLanguages: List<String>,
    val isKids: Boolean,
) {
    /// Whether the Hide / Require fields impose any filter, accounting for regex vs substring mode.
    /// Mirrors Apple `keywordFilterActive`.
    val keywordFilterActive: Boolean
        get() = if (keywordsAreRegex) {
            excludeRegex != null || includeRegex != null
        } else {
            excludeTerms.isNotEmpty() || includeTerms.isNotEmpty()
        }

    /// True when none of the opt-in filters are engaged, so the ranking can take its no-op fast path.
    /// Prefer terms count as "active" too (they BOOST, so the ranker must always apply the nudge). Avoid
    /// terms in "rank" mode register through [keywordFilterActive]. Mirrors Apple `noFiltersActive`.
    val noFiltersActive: Boolean
        get() = !keywordFilterActive && preferTerms.isEmpty() && safetyMode == "off" &&
            !hideDeadTorrents && !instantOnly && !hdrOnly && !excludeAV1 && maxResolution == 0 &&
            minResolution == 0 && !hideUnknownResolution && !preferredAudioOnly && maxFileSizeGB == 0.0

    /// Dominant-tier score added to a stream so its source type is the primary sort key. Mirrors Apple
    /// `SourcePreferences.tierWeight(for:)` / `Snapshot.tierWeight(for:)`: the type's position in
    /// [typeOrder] indexes the fixed 15k-spaced weight ladder; an absent type falls to the bottom weight.
    fun tierWeight(type: SourceType): Int {
        val idx = typeOrder.indexOf(type).let { if (it < 0) typeOrder.size - 1 else it }
        return if (idx < TIER_WEIGHTS.size) TIER_WEIGHTS[idx] else 0
    }

    /// A compact fingerprint of every preference that changes stream FILTERING or RANKING order, folded
    /// into [StreamRanking]'s memoized score-cache key so two different snapshots never share a cached
    /// score. The Android analogue of Apple's `rankingSignature` (which Apple uses to invalidate its
    /// detail memo). Includes [audioLanguages] + [isKids], both of which move rank order.
    val cacheTag: String by lazy {
        listOf(
            typeOrder.joinToString(",") { it.storageValue },
            if (useAddonOrder) "1" else "0",
            excludeTerms.joinToString(","), includeTerms.joinToString(","),
            preferTerms.joinToString(","),
            if (keywordsAreRegex) "1" else "0",
            excludeRegex?.pattern.orEmpty(), includeRegex?.pattern.orEmpty(),
            avoidBehavior, if (autoPickBest) "1" else "0",
            safetyMode,
            if (hideDeadTorrents) "1" else "0",
            if (instantOnly) "1" else "0",
            if (excludeAV1) "1" else "0",
            if (hdrOnly) "1" else "0",
            maxResolution.toString(), minResolution.toString(),
            if (hideUnknownResolution) "1" else "0",
            if (preferredAudioOnly) "1" else "0",
            maxFileSizeGB.toString(),
            audioLanguages.joinToString(","),
            if (isKids) "1" else "0",
        ).joinToString("|")
    }

    companion object {
        /// FIVE slots (media servers is the top tier): the 15k step keeps source type the dominant key
        /// (cache +8000 clears the ~5,800 quality spread but stays under the step; junk -100,000 sinks
        /// below the legit ceiling). Matches Apple `SourcePreferences.tierWeights`.
        val TIER_WEIGHTS = intArrayOf(60_000, 45_000, 30_000, 15_000, 0)

        /// The empty/default snapshot the ranker reads when no store has installed one. Every filter is a
        /// no-op ([noFiltersActive] == true), scoring adds no language/chip offsets, and [tierWeight]
        /// reproduces the default media-server > debrid > usenet > torrent > direct ladder -- so ranking is
        /// BYTE-IDENTICAL to the pre-preference-layer core scorer. This is the no-regression backstop.
        val DEFAULT = SourcePrefsSnapshot(
            useAddonOrder = false,
            typeOrder = SourceType.allCases,
            keywordsAreRegex = false,
            excludeRegex = null,
            includeRegex = null,
            excludeTerms = emptyList(),
            includeTerms = emptyList(),
            preferTerms = emptyList(),
            avoidBehavior = "hide",
            autoPickBest = false,
            safetyMode = "off",
            instantOnly = false,
            hideDeadTorrents = false,
            excludeAV1 = false,
            hdrOnly = false,
            maxResolution = 0,
            minResolution = 0,
            hideUnknownResolution = false,
            preferredAudioOnly = false,
            maxFileSizeGB = 0.0,
            audioLanguages = emptyList(),
            isKids = false,
        )
    }
}

/// Persisted source-ranking preferences, the Android port of Apple `SourcePreferences`. Backed by
/// [SharedPreferences] under Apple's EXACT flat keys (the `stremiox.streaming.*` / `vortx.streaming.*`
/// namespaces), living in the shared `vortx_settings` file so the values ride the same cross-device
/// settings-backup blob as [com.vortx.android.model.TrackPreferencesStore]. Read by [StreamRanking]
/// through an immutable [SourcePrefsSnapshot].
///
/// Per-profile scoping: Apple's `SourcePreferences` uses FLAT keys (not per-profile-namespaced) and gets
/// its per-profile behavior from `ProfileStore.applyPlayback` rewriting those flat keys on a profile
/// switch, with `reload()` re-syncing. This port mirrors that design exactly: flat Apple keys today (one
/// active profile), and [reload] ready for the Profiles layer to drive on a switch. That is why the keys
/// are NOT namespaced here -- doing so would diverge from Apple's on-disk keys and break the backup-blob
/// field alignment. [SourcePinStore] (the other per-profile store) uses Apple's per-profile-namespaced
/// key, exactly as Apple splits the two.
class SourcePreferencesStore(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    // ---- Type order ----

    var typeOrder: List<SourceType>
        get() = readOrder()
        set(value) {
            prefs.edit().putString(ORDER_KEY, value.joinToString(",") { it.storageValue }).apply()
            StreamRanking.invalidateCaches() // memoized scores embed the tier weights
        }

    var useAddonOrder: Boolean
        get() = prefs.getBoolean(ADDON_ORDER_KEY, DEFAULT_USE_ADDON_ORDER)
        set(value) { prefs.edit().putBoolean(ADDON_ORDER_KEY, value).apply() }

    // ---- Keyword filters ----

    var excludeKeywords: String
        get() = prefs.getString(EXCLUDE_KEY, DEFAULT_EXCLUDE_KEYWORDS) ?: DEFAULT_EXCLUDE_KEYWORDS
        set(value) { prefs.edit().putString(EXCLUDE_KEY, value).apply() }

    var includeKeywords: String
        get() = prefs.getString(INCLUDE_KEY, DEFAULT_INCLUDE_KEYWORDS) ?: DEFAULT_INCLUDE_KEYWORDS
        set(value) { prefs.edit().putString(INCLUDE_KEY, value).apply() }

    var keywordsAreRegex: Boolean
        get() = prefs.getBoolean(REGEX_KEY, DEFAULT_KEYWORDS_ARE_REGEX)
        set(value) { prefs.edit().putBoolean(REGEX_KEY, value).apply() }

    // ---- Smart Source Selection (Lane A) ----

    var preferKeywords: String
        get() = prefs.getString(PREFER_KEY, DEFAULT_PREFER_KEYWORDS) ?: DEFAULT_PREFER_KEYWORDS
        set(value) {
            prefs.edit().putString(PREFER_KEY, value).apply()
            StreamRanking.invalidateCaches() // Prefer boost changes rank order
        }

    var avoidBehavior: String
        get() = prefs.getString(AVOID_BEHAVIOR_KEY, DEFAULT_AVOID_BEHAVIOR) ?: DEFAULT_AVOID_BEHAVIOR
        set(value) {
            prefs.edit().putString(AVOID_BEHAVIOR_KEY, value).apply()
            StreamRanking.invalidateCaches() // "rank" mode changes rank order
        }

    var autoPickBest: Boolean
        get() = prefs.getBoolean(AUTO_PICK_BEST_KEY, DEFAULT_AUTO_PICK_BEST)
        set(value) { prefs.edit().putBoolean(AUTO_PICK_BEST_KEY, value).apply() }

    // ---- Safety + numeric filters ----

    var safetyMode: String
        get() = prefs.getString(SAFETY_KEY, DEFAULT_SAFETY_MODE) ?: DEFAULT_SAFETY_MODE
        set(value) { prefs.edit().putString(SAFETY_KEY, value).apply() }

    var hideDeadTorrents: Boolean
        get() = prefs.getBoolean(HIDE_DEAD_KEY, DEFAULT_HIDE_DEAD_TORRENTS)
        set(value) { prefs.edit().putBoolean(HIDE_DEAD_KEY, value).apply() }

    var instantOnly: Boolean
        get() = prefs.getBoolean(INSTANT_ONLY_KEY, DEFAULT_INSTANT_ONLY)
        set(value) { prefs.edit().putBoolean(INSTANT_ONLY_KEY, value).apply() }

    var maxResolution: Int
        get() = prefs.getInt(MAX_RESOLUTION_KEY, DEFAULT_MAX_RESOLUTION)
        set(value) { prefs.edit().putInt(MAX_RESOLUTION_KEY, value).apply() }

    var minResolution: Int
        get() = prefs.getInt(MIN_RESOLUTION_KEY, DEFAULT_MIN_RESOLUTION)
        set(value) { prefs.edit().putInt(MIN_RESOLUTION_KEY, value).apply() }

    var hideUnknownResolution: Boolean
        get() = prefs.getBoolean(HIDE_UNKNOWN_RES_KEY, DEFAULT_HIDE_UNKNOWN_RESOLUTION)
        set(value) { prefs.edit().putBoolean(HIDE_UNKNOWN_RES_KEY, value).apply() }

    var preferredAudioOnly: Boolean
        get() = prefs.getBoolean(PREFERRED_AUDIO_KEY, DEFAULT_PREFERRED_AUDIO_ONLY)
        set(value) { prefs.edit().putBoolean(PREFERRED_AUDIO_KEY, value).apply() }

    var maxFileSizeGB: Double
        get() = prefs.getFloat(MAX_FILE_SIZE_KEY, DEFAULT_MAX_FILE_SIZE_GB.toFloat()).toDouble()
        set(value) { prefs.edit().putFloat(MAX_FILE_SIZE_KEY, value.toFloat()).apply() }

    var hdrOnly: Boolean
        get() = prefs.getBoolean(HDR_ONLY_KEY, DEFAULT_HDR_ONLY)
        set(value) { prefs.edit().putBoolean(HDR_ONLY_KEY, value).apply() }

    var excludeAV1: Boolean
        get() = prefs.getBoolean(EXCLUDE_AV1_KEY, DEFAULT_EXCLUDE_AV1)
        set(value) { prefs.edit().putBoolean(EXCLUDE_AV1_KEY, value).apply() }

    /// The remembered Sources-list sort ("best" / "size" / "seeders"). "best" (the engine ranking) by
    /// default. Mirrors Apple `defaultSourceSort`.
    var defaultSourceSort: String
        get() = prefs.getString(DEFAULT_SORT_KEY, "best") ?: "best"
        set(value) { prefs.edit().putString(DEFAULT_SORT_KEY, value).apply() }

    // ---- Derived reads ----

    /// Parsed, lowercased, non-empty exclude / include / prefer terms (substring mode). Mirrors Apple
    /// `excludeTerms` / `includeTerms` / `preferTerms`.
    val excludeTerms: List<String> get() = terms(excludeKeywords)
    val includeTerms: List<String> get() = terms(includeKeywords)
    val preferTerms: List<String> get() = terms(preferKeywords)

    // ---- Mutations mirroring Apple ----

    /// Move the type at [index] one step toward the top (direction = -1) or bottom (+1). Mirrors Apple
    /// `moveType`.
    fun moveType(index: Int, direction: Int) {
        val order = typeOrder.toMutableList()
        val target = index + direction
        if (target < 0 || target >= order.size) return
        val tmp = order[index]; order[index] = order[target]; order[target] = tmp
        typeOrder = order
    }

    /// Apply a one-tap quality preset. Mirrors Apple `apply(_:)`: instant sources first, the per-preset
    /// caps, and it clears any resolution FLOOR (a 4K floor under Data Saver's 1080p cap would empty the
    /// list). Leaves the keyword filters + safety mode alone (user-owned).
    fun apply(preset: SourcePreset) {
        typeOrder = listOf(
            SourceType.MEDIA_SERVER, SourceType.DEBRID, SourceType.USENET,
            SourceType.TORRENT, SourceType.DIRECT,
        )
        hideDeadTorrents = true
        minResolution = 0
        when (preset) {
            SourcePreset.BEST_QUALITY -> {
                maxResolution = 0; maxFileSizeGB = 0.0; instantOnly = false; hdrOnly = false; excludeAV1 = false
            }
            SourcePreset.BALANCED -> {
                maxResolution = 0; maxFileSizeGB = 15.0; instantOnly = false; hdrOnly = false; excludeAV1 = false
            }
            SourcePreset.DATA_SAVER -> {
                maxResolution = 1080; maxFileSizeGB = 4.0; instantOnly = true; hdrOnly = false; excludeAV1 = true
            }
        }
    }

    /// Re-read is implicit on Android (every getter reads [SharedPreferences] live), so on a profile switch
    /// or settings-backup restore [reload] only needs to drop the memoized scores computed under the old
    /// values; the next source rank rebuilds a fresh snapshot off the new prefs. A hook for the future
    /// Profiles layer to call on a switch. Mirrors the intent of Apple `reload()` (which re-syncs the
    /// singleton's in-memory copy + invalidates the ranking cache).
    fun reload() {
        StreamRanking.invalidateCaches()
    }

    // ---- Snapshot + install ----

    /// Capture the ranking-relevant prefs into an immutable [SourcePrefsSnapshot]. [audioLanguages] comes
    /// from [com.vortx.android.model.TrackPreferencesStore]`.current.audioLanguages` (the ranker's
    /// context-free `object` cannot read them itself). [isKids] is false until the Profiles layer lands.
    fun snapshot(audioLanguages: List<String>, isKids: Boolean = false): SourcePrefsSnapshot {
        val regex = keywordsAreRegex
        return SourcePrefsSnapshot(
            useAddonOrder = useAddonOrder,
            typeOrder = typeOrder,
            keywordsAreRegex = regex,
            excludeRegex = compilePattern(excludeKeywords, regex),
            includeRegex = compilePattern(includeKeywords, regex),
            excludeTerms = excludeTerms,
            includeTerms = includeTerms,
            preferTerms = preferTerms,
            avoidBehavior = avoidBehavior,
            autoPickBest = autoPickBest,
            safetyMode = safetyMode,
            instantOnly = instantOnly,
            hideDeadTorrents = hideDeadTorrents,
            excludeAV1 = excludeAV1,
            hdrOnly = hdrOnly,
            maxResolution = maxResolution,
            minResolution = minResolution,
            hideUnknownResolution = hideUnknownResolution,
            preferredAudioOnly = preferredAudioOnly,
            maxFileSizeGB = maxFileSizeGB,
            audioLanguages = audioLanguages,
            isKids = isKids,
        )
    }

    /// Build a snapshot and install it as the ranker's active reading, mirroring Apple's singleton being
    /// globally reachable via `SourcePreferences.reading`. Callers with a stream list to rank install the
    /// fresh snapshot before ranking; every [StreamRanking] entry point then reads it.
    fun installSnapshot(audioLanguages: List<String> = emptyList(), isKids: Boolean = false) {
        StreamRanking.installReading(snapshot(audioLanguages, isKids))
    }

    /// Parsed, lowercased, non-empty terms from a comma list. Mirrors Apple `terms`.
    private fun terms(csv: String): List<String> =
        csv.split(",").map { it.trim().lowercase() }.filter { it.isNotEmpty() }

    private fun readOrder(): List<SourceType> {
        val saved = prefs.getString(ORDER_KEY, "").orEmpty()
        val order = saved.split(",").mapNotNull { SourceType.fromStorage(it) }.toMutableList()
        // Media servers migrate to the FRONT when a stored order predates the tier (your own copy outranks
        // everything by default). Idempotent: a stored order already containing it is never re-migrated. A
        // new install has an empty stored order, so the append below already fronts it. Mirrors Apple
        // `readOrder`.
        if (order.isNotEmpty() && !order.contains(SourceType.MEDIA_SERVER)) {
            order.add(0, SourceType.MEDIA_SERVER)
        }
        for (t in SourceType.allCases) if (!order.contains(t)) order.add(t)
        return order
    }

    companion object {
        const val PREFS_FILE = "vortx_settings"

        // Apple's EXACT flat preference keys.
        const val ORDER_KEY = "stremiox.streaming.sourceTypeOrder"
        const val ADDON_ORDER_KEY = "stremiox.streaming.useAddonOrder"
        const val EXCLUDE_KEY = "stremiox.streaming.excludeKeywords"
        const val INCLUDE_KEY = "stremiox.streaming.includeKeywords"
        const val SAFETY_KEY = "stremiox.streaming.safetyMode"
        const val HIDE_DEAD_KEY = "stremiox.streaming.hideDeadTorrents"
        const val INSTANT_ONLY_KEY = "stremiox.streaming.instantOnly"
        const val MAX_RESOLUTION_KEY = "stremiox.streaming.maxResolution"
        const val MIN_RESOLUTION_KEY = "stremiox.streaming.minResolution"
        const val HIDE_UNKNOWN_RES_KEY = "stremiox.streaming.hideUnknownResolution"
        const val PREFERRED_AUDIO_KEY = "stremiox.streaming.preferredAudioOnly"
        const val MAX_FILE_SIZE_KEY = "stremiox.streaming.maxFileSizeGB"
        const val HDR_ONLY_KEY = "stremiox.streaming.hdrOnly"
        const val EXCLUDE_AV1_KEY = "stremiox.streaming.excludeAV1"
        const val DEFAULT_SORT_KEY = "stremiox.streaming.defaultSourceSort"
        const val REGEX_KEY = "stremiox.streaming.keywordsAreRegex"
        // Smart Source Selection (Lane A) keys are born in the vortx.* namespace directly (Apple's note).
        const val PREFER_KEY = "vortx.streaming.preferKeywords"
        const val AVOID_BEHAVIOR_KEY = "vortx.streaming.avoidBehavior"
        const val AUTO_PICK_BEST_KEY = "vortx.streaming.autoPickBest"

        // Documented per-profile stream-filter defaults, in ONE place (Apple's `defaultX` constants).
        const val DEFAULT_SAFETY_MODE = "off"
        const val DEFAULT_INSTANT_ONLY = false
        const val DEFAULT_HIDE_DEAD_TORRENTS = false
        const val DEFAULT_HDR_ONLY = false
        const val DEFAULT_EXCLUDE_AV1 = false
        const val DEFAULT_EXCLUDE_KEYWORDS = ""
        const val DEFAULT_INCLUDE_KEYWORDS = ""
        const val DEFAULT_KEYWORDS_ARE_REGEX = false
        const val DEFAULT_MAX_RESOLUTION = 0
        const val DEFAULT_MAX_FILE_SIZE_GB = 0.0
        const val DEFAULT_MIN_RESOLUTION = 0
        const val DEFAULT_HIDE_UNKNOWN_RESOLUTION = false
        const val DEFAULT_PREFERRED_AUDIO_ONLY = false
        const val DEFAULT_USE_ADDON_ORDER = false
        const val DEFAULT_PREFER_KEYWORDS = ""
        const val DEFAULT_AVOID_BEHAVIOR = "hide"
        const val DEFAULT_AUTO_PICK_BEST = false

        /// Compile a user pattern case-insensitively, or null when regex mode is off, the field is blank,
        /// or the pattern is invalid (fail-open: a bad regex applies no filter rather than hiding
        /// everything). Mirrors Apple `compilePattern`.
        fun compilePattern(pattern: String, enabled: Boolean): Regex? {
            val trimmed = pattern.trim()
            if (!enabled || trimmed.isEmpty()) return null
            return runCatching { Regex(trimmed, RegexOption.IGNORE_CASE) }.getOrNull()
        }
    }
}
