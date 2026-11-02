package com.vortx.android.engine

import java.text.Normalizer
import java.math.BigDecimal
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * How well a stream's release name matches the title being opened, for the optional title-match source filter
 * (#172). The Apple twin is `SourcesShared/SourceTitleMatch.swift`; both run `test/fixtures/source-title-match.json`.
 *
 * Only a release-style name can be judged: a filename or a description line with separated words and a release
 * marker (year, episode tag, resolution or video extension). A stream that names no release, such as
 * "Debridio 1080p", scores null and is always kept.
 */
object SourceTitleMatch {
    data class Target(val title: String, val year: Int? = null, val season: Int? = null, val episode: Int? = null)

    /** Thresholds the setting offers, in percent; 0 is off. */
    val thresholds = listOf(0, 50, 70, 90)

    /** The first plausible release year in catalog text such as "2021" or "2019-2023", for a movie target. */
    fun year(releaseInfo: String?): Int? = releaseInfo?.let { text ->
        Regex("(?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9])").find(text)?.value?.toInt()
    }

    /** 0..100, or null when none of the texts names a release to compare. The best-scoring release wins. */
    fun score(texts: List<String?>, target: Target): Int? {
        val all = tokens(normalized(target.title))
        val wanted = all.filterNot(STOP_WORDS::contains).ifEmpty { all }
        if (wanted.isEmpty()) return null
        return texts.filterNotNull()
            .flatMap { it.lines() }
            .mapNotNull { releaseScore(it, wanted, target) }
            .maxOrNull()
    }

    /** True when the stream should stay listed at [threshold] percent. */
    fun passes(texts: List<String?>, target: Target, threshold: Int): Boolean {
        if (threshold !in thresholds || threshold <= 0) return true
        val score = score(texts, target) ?: return true
        return score >= threshold
    }

    private val STOP_WORDS = setOf("the", "a", "an", "and", "of")
    private val VIDEO_EXTENSIONS = setOf("mkv", "mp4", "avi", "m4v", "mov", "ts", "webm", "wmv")
    private val RESOLUTION_TOKENS = setOf("480p", "576p", "720p", "1080p", "1080i", "2160p", "4k", "uhd")

    private sealed interface Marker {
        data class Year(val year: Int) : Marker
        data class Episode(val season: Int, val episodes: IntRange) : Marker
        data class Season(val season: Int) : Marker
        data object Resolution : Marker
        data object VideoExtension : Marker
    }

    private fun releaseScore(line: String, wanted: List<String>, target: Target): Int? {
        // Preserve explicit episode ranges before punctuation becomes token separators.
        // S01E01-E03 (or S01E01-03) covers episodes 1..3, not only episode 1.
        val ranged = Regex("(?i)(s[0-9]+e[0-9]+)-e?([0-9]+)(?![0-9])")
            .replace(line, "${'$'}1e${'$'}2")
        val words = tokens(normalized(ranged))
        if (words.size < 2) return null
        val markers = words.indices.mapNotNull { index ->
            marker(words[index], words.getOrNull(index + 1))?.let { index to it }
        }
        val firstMarker = markers.firstOrNull()?.first ?: return null
        if (firstMarker <= 0 || !isRelease(line, markers.map { it.second })) return null
        val prefix = words.subList(0, firstMarker)
        val titleWords = prefix.filterNot(STOP_WORDS::contains).ifEmpty { prefix }
        var score = dice(wanted, titleWords)

        for ((_, found) in markers) {
            when (found) {
                is Marker.Episode -> {
                    val wantedSeason = target.season
                    val wantedEpisode = target.episode
                    if (wantedSeason != null && wantedEpisode != null &&
                        (found.season != wantedSeason || wantedEpisode !in found.episodes)
                    ) return 0
                }
                is Marker.Season -> if (target.season != null && found.season != target.season) return 0
                is Marker.Year -> {
                    val wantedYear = target.year
                    if (target.season == null && wantedYear != null && abs(found.year - wantedYear) > 1) {
                        score = minOf(score, 30)
                    }
                }
                Marker.Resolution, Marker.VideoExtension -> Unit
            }
        }
        return score
    }

    /**
     * A line names a release only with release evidence: a video file extension, an episode or season tag, a year
     * next to a resolution, or a dotted scene name. A bare label such as "Debridio 1080p" does not.
     */
    private fun isRelease(line: String, markers: List<Marker>): Boolean {
        if (markers.any { it is Marker.VideoExtension || it is Marker.Episode || it is Marker.Season }) return true
        if (markers.any { it is Marker.Year } && markers.any { it is Marker.Resolution }) return true
        val trimmed = line.trim()
        return !trimmed.contains(' ') && trimmed.split('.').filter(String::isNotEmpty).size >= 4
    }

    private fun marker(word: String, next: String?): Marker? {
        if (word in RESOLUTION_TOKENS) return Marker.Resolution
        if (word in VIDEO_EXTENSIONS) return Marker.VideoExtension
        if (word.length == 4) word.toIntOrNull()?.takeIf { it in 1900..2099 }?.let { return Marker.Year(it) }
        episodeTag(word)?.let { return it }
        if (word == "season") next?.toIntOrNull()?.let { return Marker.Season(it) }
        return null
    }

    /** `s01e02`, `s01e02e03`, `1x02` and `s01`. */
    private fun episodeTag(word: String): Marker? {
        val eIndex = word.indexOf('e')
        if (word.startsWith("s") && eIndex > 1) {
            val season = word.substring(1, eIndex).toIntOrNull()
            if (season != null) {
                val parts = word.substring(eIndex + 1).split('e').filter(String::isNotEmpty)
                val episodes = parts.mapNotNull(String::toIntOrNull)
                if (episodes.isEmpty() || episodes.size != parts.size) return null
                return Marker.Episode(season, episodes.min()..episodes.max())
            }
        }
        if (word.startsWith("s") && word.length in 2..3) word.substring(1).toIntOrNull()?.let { return Marker.Season(it) }
        val parts = word.split('x').filter(String::isNotEmpty)
        if (parts.size == 2 && parts[0].length <= 2 && parts[1].length >= 2) {
            val season = parts[0].toIntOrNull()
            val episode = parts[1].toIntOrNull()
            if (season != null && episode != null) return Marker.Episode(season, episode..episode)
        }
        return null
    }

    /** Sorensen-Dice over word sets, in percent: "Dune" against "Dune Part Two" is 50, not a full match. */
    private fun dice(a: List<String>, b: List<String>): Int {
        val left = a.toSet()
        val right = b.toSet()
        if (left.isEmpty() || right.isEmpty()) return 0
        return (200.0 * left.intersect(right).size / (left.size + right.size)).roundToInt()
    }

    /** Lower-cased, accents folded, "&" read as "and", and every non-alphanumeric run turned into one space. */
    fun normalized(text: String): String {
        val folded = Normalizer.normalize(text, Normalizer.Form.NFKD)
            .replace(Regex("\\p{M}+"), "")
            .lowercase(Locale.ROOT)
            .replace("&", " and ")
            .replace("'", "")
            .replace("’", "")
        val output = StringBuilder()
        var lastWasSpace = true
        for (character in folded) {
            if (character.isLetterOrDigit()) {
                output.append(character)
                lastWasSpace = false
            } else if (!lastWasSpace) {
                output.append(' ')
                lastWasSpace = true
            }
        }
        return output.toString().trim()
    }

    private fun tokens(normalized: String): List<String> = normalized.split(' ').filter(String::isNotEmpty)
}

/** A stored or synced threshold the setting offers, else null (an unknown value never filters). */
object SourceTitleMatchThreshold {
    fun admitted(value: Any?): Int? {
        if (value !is Number) return null
        val integer = runCatching { BigDecimal(value.toString()).intValueExact() }.getOrNull() ?: return null
        return integer.takeIf { it in SourceTitleMatch.thresholds }
    }
}
