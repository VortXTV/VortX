package com.vortx.android.sources

import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MediaType
import com.vortx.android.model.StreamSource
import java.text.Normalizer
import java.util.Locale
import kotlin.math.roundToInt

/** Immutable title/episode evidence captured by a source request, never a global "current title". */
class SourceMatchContext private constructor(
    internal val titles: List<List<String>>,
    val year: Int?,
    val isSeries: Boolean,
    val season: Int?,
    val episode: Int?,
) {
    internal val fingerprint: String = listOf(titles, year, isSeries, season, episode).joinToString("|")

    companion object {
        fun create(
            title: String,
            aliases: List<String> = emptyList(),
            year: Int? = null,
            isSeries: Boolean = false,
            season: Int? = null,
            episode: Int? = null,
        ): SourceMatchContext = SourceMatchContext(
            (listOf(title) + aliases.take(16)).map { SourceMatchConfidence.titleTokens(it, stripBrackets = false) }
                .filter { it.isNotEmpty() }.distinct(),
            year?.takeIf { it in 1870..2199 }, isSeries,
            season?.takeIf { it >= 0 }, episode?.takeIf { it >= 0 },
        )

        fun from(detail: MetaDetail?, episodeId: String?, fallbackTitle: String = ""): SourceMatchContext {
            val selected = detail?.videos?.firstOrNull { it.id == episodeId }
            return create(
                title = detail?.name?.takeIf { it.isNotBlank() } ?: fallbackTitle,
                aliases = detail?.titleAliases.orEmpty(),
                year = Regex("^(?:18|19|20|21)\\d{2}").find(detail?.releaseInfo.orEmpty())?.value?.toIntOrNull(),
                isSeries = detail?.type == MediaType.SERIES || episodeId != null,
                season = selected?.season,
                episode = selected?.episode,
            )
        }
    }
}

/**
 * A deterministic 0..100 text-evidence score, not a probability or provider trust score.
 *
 * Filename is authoritative when present; otherwise release lines in description/title are compared.
 * Unicode case/diacritics, punctuation and release metadata are normalized. Exact known title prefixes
 * protect literal words such as "Complete" from metadata trimming; a bracketed exact known title such
 * as "[REC]" is retained while unrelated release groups are discarded. The best known title/alias
 * uses token Dice similarity with bounded edit-distance credit (at least 60% per token). Provider names,
 * quality fields, URLs, pins and cache status never add title evidence. Extra/missing title words reduce
 * the score. Work is bounded to 2 KiB, 32 title tokens, 16 aliases and 8 release lines per source.
 *
 * Explicit wrong season/episode or a conflicting title-year scores zero. An exact episode keeps the
 * title score; a containing episode range caps it at 95; a matching season pack at 70; absent episode
 * evidence at 60. Anime absolute numbers are accepted for season 1 only (later-season absolute-number
 * mappings cannot be inferred from metadata). Unknown titles score zero. With threshold 0 every source
 * passes unchanged. Raw repository ranking may defer this filter until a request context is supplied;
 * every selectable list/pick supplies its frozen request context.
 */
object SourceMatchConfidence {
    private const val MAX_TEXT = 2048
    private const val MAX_TOKENS = 32
    private val words = Regex("[\\p{L}\\p{N}]+")
    private val bracket = Regex("\\[[^\\]\\r\\n]*\\]")
    private val marks = Regex("\\p{M}+")
    private val yearPattern = Regex("(?<![\\p{L}\\p{N}])((?:18|19|20|21)\\d{2})(?![\\p{L}\\p{N}])")
    private val seasonEpisode = Regex("(?i)(?<![\\p{L}\\p{N}])s(\\d{1,3})[ ._-]*e(\\d{1,4})((?:[ ._-]*(?:e|-[ ._-]*e?)[ ._-]*\\d{1,4})*)(?!\\d)")
    private val crossEpisode = Regex("(?i)(?<![\\p{L}\\p{N}])(\\d{1,3})x(\\d{1,4})(?:[ ._]*-[ ._]*(\\d{1,4}))?(?!\\d)")
    private val namedEpisode = Regex("(?i)\\bseason[ ._-]*(\\d{1,3})[ ._-]+episode[ ._-]*(\\d{1,4})(?!\\d)")
    private val seasonPack = Regex("(?i)(?<![\\p{L}\\p{N}])(?:s|season[ ._-]*)(\\d{1,3})(?![\\p{L}\\p{N}])")
    private val episodeOnly = Regex("(?i)(?:\\b(?:episode|ep)[ ._-]*|[ .]+-[ .]+)(\\d{1,4})(?:[ .]*-[ .]*(\\d{1,4}))?(?!\\d)")
    private val technicalStart = Regex("(?i)(?<![\\p{L}\\p{N}])(?:2160p?|1080p?|720p?|480p?|4k|uhd|web[ ._-]?(?:dl|rip)|blu[ ._-]?ray|bdrip|hdtv|remux|x26[45]|h[ .]?26[45]|hevc|av1|hdr10?|dovi|dv|aac|ddp|dts|atmos|proper|repack|complete|multi)(?![\\p{L}\\p{N}])")
    private val articles = setOf("the", "a", "an")

    fun passes(source: StreamSource, threshold: Int, context: SourceMatchContext): Boolean =
        threshold <= 0 || score(source, context) >= threshold.coerceIn(1, 100)

    fun score(source: StreamSource, context: SourceMatchContext): Int {
        if (context.titles.isEmpty()) return 0
        val filename = source.filename?.trim()?.takeIf { it.isNotEmpty() }
        val evidence = if (filename != null) {
            listOf(filename.substringAfterLast('/').substringAfterLast('\\'))
        } else {
            (source.description.orEmpty().lineSequence().take(7).toList() + source.title).take(8)
        }
        val evaluated = evidence.filterNot {
            filename == null && providerOnlyLabel(it, source.addon)
        }.map { evaluate(it, context) }
        // A release that identifies the right show but explicitly identifies another episode/year cannot
        // be rescued by the same source's generic title line.
        if (evaluated.any { it.conflict }) return 0
        return evaluated.maxOfOrNull { it.score } ?: 0
    }

    private data class Evaluation(val score: Int, val conflict: Boolean = false)
    private data class EpisodeEvidence(val start: Int, val season: Int?, val episodes: Set<Int>?, val cap: Int)

    private fun providerOnlyLabel(raw: String, addon: String): Boolean {
        val provider = titleTokens(addon, stripBrackets = false)
        val text = normalizeRelease(raw, listOf(provider))
        // A real release line can share the add-on's name; an episode code/year distinguishes it from
        // a provider-plus-quality badge. A filename never enters this fallback-only check.
        if (episodeEvidence(text) != null || yearPattern.containsMatchIn(text)) return false
        val end = metadataStart(text, listOf(provider)) ?: text.length
        return provider.isNotEmpty() && titleTokens(text.take(end), stripBrackets = false) == provider
    }

    private fun evaluate(raw: String, context: SourceMatchContext): Evaluation {
        val text = normalizeRelease(raw, context.titles)
        val episodic = episodeEvidence(text)
        val technical = metadataStart(text, context.titles)
        val end = listOfNotNull(episodic?.start, technical).minOrNull() ?: text.length
        val prefix = text.take(end)
        val candidateYears = yearPattern.findAll(prefix).map { it.groupValues[1].toInt() }.toList()
        // Numeric titles (1899, 1923, 2001: A Space Odyssey) are title tokens, not remake years.
        val titleNumbers = context.titles.flatten().toSet()
        val releaseYears = candidateYears.filter { it.toString() !in titleNumbers }
        val clean = yearPattern.replace(prefix) { if (it.value in titleNumbers) it.value else " " }
            .replace(Regex("(?i)\\.(?:mkv|mp4|avi|m4v|ts|webm)$"), " ")
        val candidate = titleTokens(clean, stripBrackets = false)
        val titleScore = context.titles.maxOfOrNull { similarity(it, candidate) } ?: 0
        if (titleScore == 0) return Evaluation(0)
        if (context.year != null && releaseYears.any { it != context.year }) return Evaluation(0, true)
        if (!context.isSeries) return Evaluation(if (episodic == null) titleScore else 0)
        if (episodic == null || context.episode == null || context.season == null) {
            return Evaluation(minOf(titleScore, 60))
        }
        if (episodic.season != null && episodic.season != context.season) return Evaluation(0, true)
        if (episodic.episodes != null) {
            if (context.episode !in episodic.episodes) return Evaluation(0, true)
            if (episodic.season == null && context.season != 1) return Evaluation(minOf(titleScore, 60))
        }
        // Every explicit code, including mixed S01E02 / 2x03 notation, must contain the target.
        for (pattern in listOf(seasonEpisode, crossEpisode, namedEpisode)) {
            for (match in pattern.findAll(text)) {
                val identity = episodeEvidence(match.value) ?: continue
                if (identity.season != context.season || identity.episodes?.contains(context.episode) == false) {
                    return Evaluation(0, true)
                }
            }
        }
        return Evaluation(minOf(titleScore, episodic.cap))
    }

    private fun episodeEvidence(text: String): EpisodeEvidence? {
        seasonEpisode.find(text)?.let { match ->
            val first = match.groupValues[2].toIntOrNull() ?: return null
            val tail = Regex("\\d+").findAll(match.groupValues[3]).mapNotNull { it.value.toIntOrNull() }.toList()
            val episodes = mutableSetOf(first)
            var previous = first
            for (part in Regex("(?:e|-[ ._-]*e?)[ ._-]*(\\d{1,4})").findAll(match.groupValues[3])) {
                val next = part.groupValues[1].toIntOrNull() ?: continue
                if (part.value.startsWith('-')) episodes.addAll(previous..next.coerceAtLeast(previous))
                else episodes.add(next)
                previous = next
            }
            return EpisodeEvidence(match.range.first, match.groupValues[1].toIntOrNull(), episodes, if (tail.isEmpty()) 100 else 95)
        }
        crossEpisode.find(text)?.let { match ->
            val first = match.groupValues[2].toIntOrNull() ?: return null
            val last = match.groupValues[3].toIntOrNull() ?: first
            return EpisodeEvidence(match.range.first, match.groupValues[1].toIntOrNull(), (first..last.coerceAtLeast(first)).toSet(), if (first == last) 100 else 95)
        }
        namedEpisode.find(text)?.let { match ->
            val ep = match.groupValues[2].toIntOrNull() ?: return null
            return EpisodeEvidence(match.range.first, match.groupValues[1].toIntOrNull(), setOf(ep), 100)
        }
        seasonPack.find(text)?.let { match ->
            return EpisodeEvidence(match.range.first, match.groupValues[1].toIntOrNull(), null, 70)
        }
        episodeOnly.find(text)?.let { match ->
            val first = match.groupValues[1].toIntOrNull() ?: return null
            val last = match.groupValues[2].toIntOrNull() ?: first
            return EpisodeEvidence(match.range.first, null, (first..last.coerceAtLeast(first)).toSet(), if (first == last) 100 else 95)
        }
        return null
    }

    private fun normalize(text: String, stripBrackets: Boolean = true): String = marks.replace(
        Normalizer.normalize(text.take(MAX_TEXT), Normalizer.Form.NFKD), "",
    ).lowercase(Locale.ROOT).replace("&", " and ").let { if (stripBrackets) bracket.replace(it, " ") else it }

    private fun normalizeRelease(raw: String, titles: List<List<String>>): String =
        bracket.replace(normalize(raw, stripBrackets = false)) { group ->
            val tokens = titleTokens(group.value, stripBrackets = false)
            if (tokens.isNotEmpty() && titles.any { it == tokens }) group.value else " "
        }

    private fun metadataStart(text: String, titles: List<List<String>>): Int? {
        val tokens = words.findAll(text).take(MAX_TOKENS).filterNot { it.value in articles }.toList()
        // Only a complete, literal prefix protects title words. A substring elsewhere cannot suppress
        // metadata parsing or bypass the normal similarity/conflicting year/episode checks.
        val literalTitleEnd = titles.mapNotNull { title ->
            if (title.isNotEmpty() && title.size <= tokens.size && title.indices.all { title[it] == tokens[it].value })
                tokens[title.lastIndex].range.last + 1 else null
        }.maxOrNull() ?: 0
        return technicalStart.findAll(text).firstOrNull { it.range.first >= literalTitleEnd }?.range?.first
    }

    internal fun titleTokens(text: String, stripBrackets: Boolean = true): List<String> {
        val tokens = words.findAll(normalize(text, stripBrackets)).map { it.value.take(64) }.take(MAX_TOKENS).toList()
        return tokens.filterNot { it in articles }.ifEmpty { tokens }
    }

    private fun similarity(expected: List<String>, candidate: List<String>): Int {
        if (expected.isEmpty() || candidate.isEmpty()) return 0
        val used = BooleanArray(candidate.size)
        var credit = 0.0
        for (token in expected) {
            var winner = -1
            var best = 0.0
            for (i in candidate.indices) {
                if (used[i]) continue
                val affinity = tokenSimilarity(token, candidate[i])
                if (affinity > best) { winner = i; best = affinity }
            }
            if (winner >= 0 && best >= 0.6) { used[winner] = true; credit += best }
        }
        return (200.0 * credit / (expected.size + candidate.size)).roundToInt().coerceIn(0, 100)
    }

    private fun tokenSimilarity(left: String, right: String): Double {
        if (left == right) return 1.0
        // Tiny or numeric tokens need exact agreement: "Up" != "Us", and sequel 2 != 3.
        if (minOf(left.length, right.length) < 4 || left.all(Char::isDigit) || right.all(Char::isDigit)) return 0.0
        if (minOf(left.length, right.length).toDouble() / maxOf(left.length, right.length) < 0.6) return 0.0
        var row = IntArray(right.length + 1) { it }
        for (i in left.indices) {
            val next = IntArray(right.length + 1)
            next[0] = i + 1
            for (j in right.indices) {
                next[j + 1] = minOf(next[j] + 1, row[j + 1] + 1, row[j] + if (left[i] == right[j]) 0 else 1)
            }
            row = next
        }
        return 1.0 - row.last().toDouble() / maxOf(left.length, right.length)
    }
}
