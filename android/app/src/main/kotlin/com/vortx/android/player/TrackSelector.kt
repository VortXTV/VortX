package com.vortx.android.player

import com.vortx.android.model.TrackPreferences

/**
 * Picks the audio and subtitle track to auto-select from the available tracks and the user's
 * preferences. Pure and side-effect free (so it is unit-testable), and engine-agnostic: it operates on
 * the chrome's own [PlayerTrack] list, so ONE selector serves both libmpv and ExoPlayer.
 *
 * The Android port of Apple `app/Sources/Player/TrackSelector.swift`, kept faithful to its policy so both
 * platforms auto-pick the same track for the same file + preferences (issue #76: a Turkish-only
 * preference must not silently play a French dub off a multi-language European release). [PlayerTrack]
 * carries the same fields Apple's `MPVTrack` did (id / lang / title / forced), so the selection rules map
 * across one-for-one.
 */
object TrackSelector {

    /**
     * The audio and subtitle track ids to select. A [subtitleId] of `-1` means "subtitles off"; a `null`
     * [audioId] means "leave the engine's default" (neither the user's chain nor the English fallback
     * matched, so the container/first-track default the engine already chose is kept).
     */
    data class Selection(val audioId: Int?, val subtitleId: Int?)

    /**
     * The audio and subtitle track to auto-select. Mirrors Apple `TrackSelector.select`.
     *
     * No track matching the user's language chain (#76, ozdek's report) does NOT leave the pick to the
     * engine default: unpicked, both engines defer to the container's default/first audio track, which on
     * multi-language European releases is frequently the local dub, so a Turkish-only preference played
     * French. It falls back to English, the original language of the overwhelming majority of the catalog.
     * The subtitle policy keys off the CHAIN match, not the fallback: English-fallback audio counts as
     * foreign-language content, so full subtitles in the user's language still auto-enable.
     */
    fun select(
        audio: List<PlayerTrack>,
        subtitles: List<PlayerTrack>,
        preferences: TrackPreferences,
    ): Selection {
        val chainPick = firstMatch(audio, preferences.audioLanguages, preferences.rejectTerms)
        val audioPick = chainPick ?: firstMatch(audio, listOf("en"), preferences.rejectTerms)
        val subtitle = selectSubtitle(subtitles, preferences, gotPreferredAudio = chainPick != null)
        return Selection(audioPick?.id, subtitle)
    }

    /**
     * Whether the chrome should fall back to an EXTERNAL (add-on) subtitle for this load: the user's
     * preferences wanted FULL subtitles but no embedded track matched the language chain. Mirrors
     * [selectSubtitle]'s policy exactly, so the add-on fallback never fires when the user asked for
     * subtitles off / forced-only while their preferred audio is present, and never fires when an embedded
     * track already satisfies the chain (the embedded auto-select handles that case).
     */
    fun wantsExternalSubtitle(
        audio: List<PlayerTrack>,
        subtitles: List<PlayerTrack>,
        preferences: TrackPreferences,
    ): Boolean {
        val gotPreferredAudio = firstMatch(audio, preferences.audioLanguages, preferences.rejectTerms) != null
        // With preferred audio present, only the "always" policy shows full subtitles; off/forced-only must
        // not trigger a full external sub. Foreign-language content (no preferred audio) always wants them.
        if (gotPreferredAudio && preferences.forcedPolicy != TrackPreferences.ForcedPolicy.ALWAYS) return false
        return firstMatch(subtitles, preferences.subtitleLanguages, preferences.rejectTerms) == null
    }

    /** First track whose language matches the priority list and whose title isn't rejected. */
    private fun firstMatch(tracks: List<PlayerTrack>, languages: List<String>, reject: List<String>): PlayerTrack? {
        for (lang in languages) {
            tracks.firstOrNull { matches(it.lang, lang) && !isRejected(it, reject) }?.let { return it }
        }
        return null
    }

    /** The subtitle track id to select, or `-1` for "off". Mirrors Apple `selectSubtitle`. */
    private fun selectSubtitle(
        subs: List<PlayerTrack>,
        preferences: TrackPreferences,
        gotPreferredAudio: Boolean,
    ): Int {
        if (subs.isEmpty()) return SUBTITLE_OFF
        // Foreign-language content (no preferred audio matched): show full subtitles so you can follow.
        if (!gotPreferredAudio) {
            return firstMatch(subs, preferences.subtitleLanguages, preferences.rejectTerms)?.id ?: SUBTITLE_OFF
        }
        return when (preferences.forcedPolicy) {
            TrackPreferences.ForcedPolicy.OFF -> SUBTITLE_OFF
            TrackPreferences.ForcedPolicy.ALWAYS ->
                firstMatch(subs, preferences.subtitleLanguages, preferences.rejectTerms)?.id ?: SUBTITLE_OFF
            TrackPreferences.ForcedPolicy.FORCED -> selectForcedSubtitle(subs, preferences)
        }
    }

    /**
     * Match by the container's FORCED disposition flag FIRST: real forced tracks are flagged
     * (AV_DISPOSITION_FORCED / mpv track-list `forced` / ExoPlayer SELECTION_FLAG_FORCED), not labelled
     * "forced" in the title, so the old title-only match never fired for them. Prefer a forced track in a
     * preferred subtitle language, then ANY forced track (forced subs are meant to show regardless of
     * language), then fall back to the legacy title-contains-"forced" heuristic for the rare container that
     * only labels forced in its title. Off if nothing qualifies. Mirrors Apple's `.forced` branch.
     */
    private fun selectForcedSubtitle(subs: List<PlayerTrack>, preferences: TrackPreferences): Int {
        for (lang in preferences.subtitleLanguages) {
            subs.firstOrNull { it.forced && matches(it.lang, lang) && !isRejected(it, preferences.rejectTerms) }
                ?.let { return it.id }
        }
        subs.firstOrNull { it.forced && !isRejected(it, preferences.rejectTerms) }?.let { return it.id }
        for (lang in preferences.subtitleLanguages) {
            subs.firstOrNull {
                matches(it.lang, lang) &&
                    it.title.lowercase().contains("forced") &&
                    !isRejected(it, preferences.rejectTerms)
            }?.let { return it.id }
        }
        return SUBTITLE_OFF
    }

    private fun isRejected(track: PlayerTrack, reject: List<String>): Boolean {
        val title = track.title.lowercase()
        return reject.any { it.isNotEmpty() && title.contains(it.lowercase()) }
    }

    /** Language match, tolerant of 2- vs 3-letter ISO codes (en/eng) and region suffixes (en-US). */
    fun matches(a: String?, b: String?): Boolean {
        val ca = canonical(a)
        return ca.isNotEmpty() && ca == canonical(b)
    }

    /** Reduce a language code to a canonical 2-letter form (eng -> en, en-US -> en, ja -> ja). */
    fun canonical(code: String?): String {
        val base = code?.lowercase()?.substringBefore('-') ?: ""
        if (base.length == 3) alpha3to2[base]?.let { return it }
        return base.take(2)
    }

    /** Subtitle sentinel: no track selected (subtitles off). */
    const val SUBTITLE_OFF = -1

    /**
     * 3-letter codes whose 2-letter form is NOT their first two letters, in both ISO 639-2/T and /B
     * spellings (Matroska muxers write the B codes: "rum", "slo", "per", ...), plus the legacy
     * OpenSubtitles codes add-ons still send ("pob" = Brazilian Portuguese, "scc"/"scr" = Serbian/
     * Croatian). Without an entry the take(2) fallback can cross languages entirely: "est" (Estonian) would
     * match an "es" (Spanish) preference and "rum" (Romanian) a "ru" (Russian) one. Byte-for-byte the Apple
     * `alpha3to2` table so both platforms canonicalize identically.
     */
    private val alpha3to2: Map<String, String> = mapOf(
        "eng" to "en", "spa" to "es", "fra" to "fr", "fre" to "fr", "deu" to "de", "ger" to "de",
        "ita" to "it", "por" to "pt", "rus" to "ru", "jpn" to "ja", "kor" to "ko", "zho" to "zh",
        "chi" to "zh", "ara" to "ar", "hin" to "hi", "nld" to "nl", "dut" to "nl", "swe" to "sv",
        "nor" to "no", "dan" to "da", "fin" to "fi", "pol" to "pl", "tur" to "tr", "tha" to "th",
        "vie" to "vi", "ind" to "id", "heb" to "he", "ell" to "el", "gre" to "el", "ces" to "cs", "cze" to "cs",
        "ron" to "ro", "rum" to "ro", "bul" to "bg", "slk" to "sk", "slo" to "sk", "fas" to "fa",
        "per" to "fa", "est" to "et", "lav" to "lv", "lit" to "lt", "isl" to "is", "ice" to "is",
        "mkd" to "mk", "mac" to "mk", "sqi" to "sq", "alb" to "sq", "hye" to "hy", "arm" to "hy",
        "kat" to "ka", "geo" to "ka", "eus" to "eu", "baq" to "eu", "cym" to "cy", "wel" to "cy",
        "msa" to "ms", "may" to "ms", "ben" to "bn", "mal" to "ml", "mar" to "mr", "kan" to "kn",
        "mya" to "my", "bur" to "my", "khm" to "km", "lao" to "lo", "kaz" to "kk", "bos" to "bs",
        "mlt" to "mt", "gle" to "ga", "fil" to "tl", "tgl" to "tl", "pob" to "pt", "scc" to "sr", "scr" to "hr",
    )
}
