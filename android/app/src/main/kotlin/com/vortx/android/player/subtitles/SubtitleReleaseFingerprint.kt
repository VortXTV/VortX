package com.vortx.android.player.subtitles

/**
 * Content-key + release-fingerprint helpers for VortX's community-subtitle system. The Kotlin port of Apple
 * `app/SourcesShared/SubtitleReleaseFingerprint.swift`, matched so a key/fingerprint computed here indexes the
 * SAME pool at `subtitles.vortx.tv` an Apple- or web-signed client hits.
 *
 * The pool keys everything on a `content_key` (the title/episode) plus, for the learned SYNC OFFSET, a
 * `fingerprint` (the specific RIP). The point of the fingerprint: an offset learned on one encode (e.g. a
 * WEB-DL that starts 900 ms after the black frame) must NOT be applied to a different rip of the same episode
 * (a BluRay remux with a different intro), or it would push everyone's subtitles OUT of sync. So two streams
 * share a fingerprint only when they are plausibly the same underlying media: same frame-rate, same runtime
 * (bucketed), same release-quality tokens.
 *
 * This is FOUNDATION-only pure logic: no network, no state, deterministic. The integration pass supplies the
 * real inputs (duration from the player once known, release text from the chosen stream); every input is
 * optional so a caller that knows little still gets a stable, if coarser, fingerprint.
 */
object SubtitleReleaseFingerprint {

    // MARK: - content_key

    /**
     * The pool `content_key` for a title or episode.
     *
     *   - movie:   `imdb:tt<id>`                    e.g. `imdb:tt0111161`
     *   - episode: `imdb:tt<id>:<season>:<episode>` e.g. `imdb:tt0903747:1:1`
     *
     * [imdbId] may arrive with or without the leading `tt` and with or without an `imdb:`/`tt` prefix; it is
     * normalized to the bare numeric-plus-tt core so the key is stable regardless of the caller's format.
     * Returns null when no usable IMDb id is present (the whole feature no-ops without a content key).
     */
    fun contentKey(imdbId: String?, season: Int? = null, episode: Int? = null): String? {
        val tt = normalizedImdb(imdbId) ?: return null
        return if (season != null && episode != null) "imdb:$tt:$season:$episode" else "imdb:$tt"
    }

    /**
     * Reduce any of `tt0111161`, `0111161`, `imdb:tt0111161`, `imdb:tt0111161:1:2` to the bare `tt0111161`
     * core, or null when there is no `tt<digits>` / bare-digits id to be found.
     */
    private fun normalizedImdb(raw: String?): String? {
        val cleaned = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        TT_ID.find(cleaned)?.let { return it.value }
        DIGITS.find(cleaned)?.let { return "tt${it.value}" }
        return null
    }

    private val TT_ID = Regex("tt\\d+")
    private val DIGITS = Regex("\\d+")

    // MARK: - release fingerprint

    /**
     * A short, stable fingerprint of the PLAYING RIP, used only to scope the learned sync offset to media that
     * is plausibly the same encode. Deterministic: the same inputs always produce the same string.
     *
     * Inputs (all optional; the integration pass fills what the player/stream actually knows):
     *   - [frameRate]:    the video frame-rate if the player has surfaced it (e.g. 23.976, 25, 29.97). Rounded
     *                     to 3 dp so 23.976023976... and 23.976 collapse together. null when unknown.
     *   - [durationSecs]: the media runtime in seconds (from the player once the file is open). Bucketed to the
     *                     nearest [durationBucketSecs] (default 30 s) so two rips of the same episode that
     *                     differ by a couple of seconds of black frames still match, but a different cut does
     *                     not. null when unknown.
     *   - [releaseName]:  the stream's release / quality text (title + tags, e.g.
     *                     "Show.S01E01.1080p.WEB-DL.x264-GRP"). Distilled to a sorted set of strong quality
     *                     tokens (1080p / 2160p / web-dl / bluray / remux / x264 / x265 / hdr / ...). The title
     *                     words are dropped so only the ENCODE signature contributes.
     *
     * Fallback: when frame-rate is unknown, the fingerprint is built from the duration bucket plus the
     * normalized release name so it is still stable and rip-specific. When nothing at all is known it returns a
     * fixed sentinel ("unknown") so callers never have to branch on null.
     *
     * The result is `<12-hex>`: a truncated FNV-1a hash of the normalized component string, short enough for a
     * URL query value and stable across launches (it does NOT use a per-process-seeded hash).
     */
    fun releaseFingerprint(
        frameRate: Double? = null,
        durationSecs: Double? = null,
        releaseName: String? = null,
        durationBucketSecs: Int = 30,
    ): String {
        val components = mutableListOf<String>()

        if (frameRate != null && frameRate > 0 && frameRate.isFinite()) {
            components.add("fps:${"%.3f".format(frameRate)}")
        }

        if (durationSecs != null && durationSecs > 0 && durationSecs.isFinite()) {
            val bucket = maxOf(1, durationBucketSecs)
            val bucketed = Math.round(durationSecs / bucket).toInt() * bucket
            components.add("dur:$bucketed")
        }

        val tokens = qualityTokens(releaseName)
        if (tokens.isNotEmpty()) {
            components.add("src:${tokens.joinToString("-")}")
        } else if (!releaseName.isNullOrEmpty()) {
            // No strong quality token parsed: fall back to a normalized form of the whole name so the
            // fingerprint is still rip-specific rather than collapsing every untagged rip together.
            components.add("nm:${normalizeName(releaseName)}")
        }

        if (components.isEmpty()) return "unknown"
        return shortHash(components.joinToString("|"))
    }

    // MARK: - helpers

    /**
     * Strong, unambiguous release-quality tokens, lowercased and SORTED so token order in the source name is
     * irrelevant (the same rip described in a different word order fingerprints identically). Deliberately
     * conservative: only encode/quality signatures, never title words.
     */
    private val qualityMarkers: List<String> = listOf(
        "2160p", "1080p", "720p", "480p", "4k", "uhd",
        "web-dl", "webdl", "webrip", "bluray", "blu-ray", "bdrip", "brrip", "hdrip", "dvdrip", "remux",
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid",
        "hdr", "hdr10", "dolby", "dovi", "hlg", "sdr", "10bit", "8bit",
        "atmos", "truehd", "dts", "ddp", "aac", "ac3", "flac",
    )

    /**
     * The sorted, de-duplicated set of quality tokens present in [name] (word-boundary matched so "1080p" in
     * "S1080P" is not mismatched and "hdr" inside a title word is not a false hit). Empty when none present.
     */
    fun qualityTokens(name: String?): List<String> {
        val lowered = name?.lowercase()?.takeIf { it.isNotEmpty() } ?: return emptyList()
        val found = sortedSetOf<String>()
        for (marker in qualityMarkers) {
            // Require non-alphanumeric boundaries so tokens embedded in a longer word do not match. The markers
            // contain only "-" and "." beyond alphanumerics, so a literal-quoted pattern is exact.
            val pattern = Regex("(?<![a-z0-9])${Regex.escape(marker)}(?![a-z0-9])")
            if (pattern.containsMatchIn(lowered)) found.add(marker)
        }
        return found.toList()
    }

    /**
     * Lowercase, strip everything but alphanumerics, collapse to a bounded-length core. Used only for the
     * no-quality-token fallback so an untagged rip still yields a stable, deterministic string.
     */
    private fun normalizeName(name: String): String {
        val kept = name.lowercase().filter { it.isLetterOrDigit() }
        return kept.take(64)
    }

    /**
     * A stable 12-hex-char FNV-1a hash of [input]. Deterministic across launches and processes (unlike a
     * per-process-seeded hash, which must NOT be used for a persisted/shared key).
     */
    private fun shortHash(input: String): String {
        var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325 FNV offset basis
        val prime = 0x100000001b3L // FNV prime
        for (byte in input.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toLong() and 0xFF)
            hash *= prime
        }
        val masked = hash and 0xffffffffffffL
        return "%012x".format(masked)
    }
}
