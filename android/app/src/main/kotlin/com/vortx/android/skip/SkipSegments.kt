package com.vortx.android.skip

import kotlin.math.roundToInt

/// Skip-segment model + resolver, a line-for-line Kotlin port of `app/Sources/Player/SkipSegments.swift`.
/// Pure value types and pure functions (no Android, no network), so this unit-tests identically to the
/// Swift original and is shared by the crowd fetch ([SkipTimestampService]) and the player skip button.

/// One entry from mpv's `chapter-list` (a title and its start time, in seconds). Mirrors Apple `MPVChapter`.
data class MpvChapter(val title: String, val start: Double)

/// A skippable span the player offers to jump past. Mirrors Apple `SkipSegment`.
data class SkipSegment(val kind: Kind, val start: Double, val end: Double) {
    enum class Kind(val raw: String) {
        INTRO("intro"), RECAP("recap"), CREDITS("credits"), PREVIEW("preview");

        companion object {
            /// The `SkipSegment.Kind(rawValue:)` analogue: null for an unknown wire kind (e.g. skip.vortx.tv's
            /// `post_credit`, which has no matching kind and is dropped on read, exactly as on Apple).
            fun fromRaw(raw: String): Kind? = entries.firstOrNull { it.raw == raw }
        }
    }

    val id: String get() = "${kind.raw}-${start.toInt()}"

    val label: String get() = when (kind) {
        Kind.INTRO -> "Skip Intro"
        Kind.RECAP -> "Skip Recap"
        Kind.CREDITS -> "Skip Credits"
        Kind.PREVIEW -> "Skip Preview"
    }
}

/// A detected span from ONE source, before resolution. Each detection layer (named chapters today,
/// crowd-sourced timestamps, later on-device heuristics) produces candidates and [SegmentResolver] votes,
/// so layers stay independent and new ones just plug in. Mirrors Apple `SegmentCandidate`.
data class SegmentCandidate(
    val kind: SkipSegment.Kind,
    val start: Double,
    val end: Double,
    val source: Source,
    val confidence: Double,
) {
    /// Priority order: higher [priority] wins ties. Mirrors Apple `SegmentCandidate.Source` (a `Comparable`
    /// backed by an Int rawValue).
    enum class Source(val priority: Int) {
        CHAPTER(0), CROWD_API(1), MANUAL(2),
    }
}

/// Merges candidates from all layers into the final skip segments. Every span passes sanity guards first
/// (an intro must end in the first 60% of the runtime, credits must start in the back half), so one bad
/// crowd entry or mis-titled chapter can never cause a wild mid-episode skip. Where two layers found the
/// same span, the higher-confidence source wins. Mirrors Apple `SegmentResolver`.
object SegmentResolver {

    fun resolve(candidates: List<SegmentCandidate>, duration: Double): List<SkipSegment> {
        if (duration <= 0) return emptyList()
        val pool = candidates.mapNotNull { clamp(it, duration) }.toMutableList()
        val result = mutableListOf<SkipSegment>()
        while (pool.isNotEmpty()) {
            val seed = pool.removeAt(0)
            val cluster = mutableListOf(seed)
            // Pull every remaining candidate that OVERLAPS the seed (same kind), matching Apple's
            // `pool.removeAll { other in ... cluster.append(other); return true }`. The overlap test is
            // against the SEED's bounds, not the growing cluster's, exactly as on Apple.
            val iterator = pool.iterator()
            while (iterator.hasNext()) {
                val other = iterator.next()
                if (other.kind == seed.kind && other.start < seed.end && seed.start < other.end) {
                    cluster.add(other)
                    iterator.remove()
                }
            }
            // Highest (confidence, then source priority) wins the cluster, matching Apple's
            // `cluster.max(by: { ($0.confidence, $0.source) < ($1.confidence, $1.source) })`.
            val best = cluster.maxWithOrNull(compareBy({ it.confidence }, { it.source.priority }))
            if (best != null) result.add(SkipSegment(best.kind, best.start, best.end))
        }
        return result.sortedBy { it.start }
    }

    private fun clamp(c: SegmentCandidate, duration: Double): SegmentCandidate? {
        val start = maxOf(0.0, minOf(c.start, duration))
        val end = maxOf(0.0, minOf(c.end, duration))
        if (end - start < 5) return null // sub-5s spans are noise, not segments
        when (c.kind) {
            SkipSegment.Kind.INTRO, SkipSegment.Kind.RECAP ->
                if (!(end - start <= 1200 && end <= duration * 0.6)) return null
            SkipSegment.Kind.CREDITS, SkipSegment.Kind.PREVIEW ->
                if (start < duration * 0.5) return null
        }
        return c.copy(start = start, end = end)
    }
}

/// Layer 1: skip spans from named media chapters, the universal (no-network) baseline that desktop players
/// use. A chapter whose title reads like an opening/recap becomes an intro/recap, an ending/credits chapter
/// becomes credits, and the segment runs to the next chapter's start (or the end of the file). Crowd-sourced
/// timestamps ([SkipTimestampService]) layer on top via [SegmentResolver]. Mirrors Apple `SkipSegments`.
object SkipSegments {

    /// `(token, requiresWholeWord)`. Short ambiguous tokens (anime "OP"/"ED") need a word boundary so they
    /// don't match inside longer words ("op" must not fire on "Opening" or "Stop").
    private val introTokens = listOf("opening" to false, "intro" to false, "op" to true)
    private val recapTokens = listOf("recap" to false, "previously" to false)
    private val creditsTokens = listOf("ending" to false, "outro" to false, "credits" to false, "closing" to false, "ed" to true)
    private val previewTokens = listOf("preview" to false, "next episode" to false)

    /// Intro is checked before credits so "opening credits" reads as an intro, not credits.
    fun chapterCandidates(chapters: List<MpvChapter>, duration: Double): List<SegmentCandidate> {
        if (chapters.isEmpty() || duration <= 0) return emptyList()
        val sorted = chapters.sortedBy { it.start }
        val candidates = mutableListOf<SegmentCandidate>()
        for ((i, chapter) in sorted.withIndex()) {
            val title = chapter.title.lowercase()
            val kind = when {
                introTokens.any { matches(title, it.first, it.second) } -> SkipSegment.Kind.INTRO
                recapTokens.any { matches(title, it.first, it.second) } -> SkipSegment.Kind.RECAP
                creditsTokens.any { matches(title, it.first, it.second) } -> SkipSegment.Kind.CREDITS
                previewTokens.any { matches(title, it.first, it.second) } -> SkipSegment.Kind.PREVIEW
                else -> null
            } ?: continue
            val end = if (i + 1 < sorted.size) sorted[i + 1].start else duration
            if (end <= chapter.start + 1) continue // ignore degenerate / zero-length spans
            candidates.add(SegmentCandidate(kind, chapter.start, end, SegmentCandidate.Source.CHAPTER, 0.8))
        }
        return candidates
    }

    /// Chapter-only detection, kept for callers that don't merge other layers.
    fun detect(chapters: List<MpvChapter>, duration: Double): List<SkipSegment> =
        SegmentResolver.resolve(chapterCandidates(chapters, duration), duration)

    private fun matches(title: String, token: String, wholeWord: Boolean): Boolean {
        val idx = title.indexOf(token)
        if (idx < 0) return false
        if (!wholeWord) return true
        val before = if (idx == 0) null else title[idx - 1]
        val afterIdx = idx + token.length
        val after = if (afterIdx >= title.length) null else title[afterIdx]
        fun isBoundary(c: Char?): Boolean = c == null || !c.isLetter()
        return isBoundary(before) && isBoundary(after)
    }
}

/// Pure helper for drawing chapter boundary ticks on the seek bar (both players share it). Side-effect-free
/// so it unit-tests like the skip logic above. Mirrors Apple `ChapterMarks`.
object ChapterMarks {

    /// Chapter start times as fractions of the runtime (0..1), for tick marks along the scrubber. Drops the
    /// implicit leading chapter (start < 1s) and any marker within 5s of the end (cosmetic noise), then
    /// collapses fractions that round to the same 0.1% position so a stable-key list over the result never
    /// has duplicates.
    fun fractions(chapters: List<MpvChapter>, duration: Double): List<Double> {
        if (duration <= 0) return emptyList()
        val seen = HashSet<Int>()
        val out = mutableListOf<Double>()
        for (start in chapters.map { it.start }.sorted()) {
            if (start <= 1 || start >= duration - 5) continue
            val key = ((start / duration) * 1000).roundToInt()
            if (key <= 0 || key >= 1000 || !seen.add(key)) continue
            out.add(key / 1000.0)
        }
        return out
    }
}
