package com.vortx.android.sources

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import java.util.Locale

/** The host probe and Android JUnit wrapper run these same real-model/policy cases. No Android stubs. */
internal fun sourceQuickFilterPolicyCases(): Int {
    var count = 0
    fun case(name: String, checkCase: () -> Unit) {
        try { checkCase() } catch (failure: Throwable) { throw AssertionError(name, failure) }
        count++
    }
    fun source(text: String, id: String = "source", hash: String? = null) =
        StreamSource(id = id, addon = "Provider", title = text, infoHash = hash, isTorrent = hash != null)
    fun groups(vararg sources: StreamSource) = listOf(StreamGroup("Provider", sources.toList(), "https://provider.invalid"))
    fun rows(input: List<StreamGroup>, filters: SourceQuickFilters, revision: Long = 7L) =
        SourceQuickFilterIndex(input).matchingGroups(filters, revision).flatMap { it.streams }

    case("All returns original groups and exact source objects") {
        val input = groups(source("4K"), source("1080p"))
        check(SourceQuickFilterIndex(input).matchingGroups(SourceQuickFilters()) === input)
        check(rows(input, SourceQuickFilters()).zip(input.single().streams).all { (a, b) -> a === b })
    }
    case("text and URL never manufacture account cache evidence") {
        val advertised = source("⚡ [RD+] Cached HEVC HDR10").copy(url = "https://cdn.invalid/file")
        check(!sourceQuickFilterFacts(advertised).confirmedCached)
        check(rows(groups(advertised), SourceQuickFilters(cache = SourceCacheFacet.CONFIRMED)).isEmpty())
        check(rows(groups(advertised), SourceQuickFilters(cache = SourceCacheFacet.UNKNOWN)).single() === advertised)
    }
    case("real normalized torrent hit changes only transient evidence") {
        val original = source("⚡ Already advertised cached", hash = " AbCd ").copy(description = "Original provider text")
        val marked = markAccountConfirmedCache(groups(original), setOf("abcd"), 7L).single().streams.single()
        check(marked.accountConfirmedCacheRevision == 7L)
        check(marked.copy(accountConfirmedCacheRevision = null) == original)
        check(marked.id == original.id && marked.title == original.title && marked.description == original.description)
        check(rows(groups(marked), SourceQuickFilters(cache = SourceCacheFacet.CONFIRMED)).single() === marked)
    }
    case("no actual hit and repeated marking retain existing values") {
        val input = groups(source("Cached", hash = "abcd"))
        check(markAccountConfirmedCache(input, emptySet(), 7L) === input)
        check(markAccountConfirmedCache(input, setOf("ef01"), 7L) === input)
        val marked = markAccountConfirmedCache(input, setOf("abcd"), 7L)
        check(markAccountConfirmedCache(marked, setOf("abcd"), 7L) === marked)
    }
    case("Usenet media-server and YouTube claims stay unconfirmed") {
        val plain = source("Cached", hash = "abcd")
        val input = groups(
            plain.copy(nzbUrl = "https://nzb.invalid/file", url = null),
            plain.copy(isMediaServer = true),
            source("Cached").copy(ytId = "clip"),
            source("Cached").copy(url = "https://cdn.invalid/direct"),
        )
        check(markAccountConfirmedCache(input, setOf("abcd"), 7L) === input)
        check(input.single().streams.none { sourceQuickFilterFacts(it).confirmedCached })
    }
    case("missing range is Unknown not inferred SDR") {
        val facts = sourceQuickFilterFacts(source("Movie 2160p WEB-DL"))
        check(facts.ranges == setOf(SourceRangeFacet.UNKNOWN))
        check(facts.codecs == setOf(SourceCodecFacet.UNKNOWN))
        check(rows(groups(source("4K")), SourceQuickFilters(range = SourceRangeFacet.SDR)).isEmpty())
    }
    case("positive range aliases and mixed reported values are preserved") {
        val facts = sourceQuickFilterFacts(source("Dolby.Vision HDR10+ HLG SDR"))
        check(facts.ranges == setOf(SourceRangeFacet.DOLBY_VISION, SourceRangeFacet.HDR10_PLUS, SourceRangeFacet.HLG, SourceRangeFacet.SDR))
        check(sourceQuickFilterFacts(source("DoVi HDR10 HDR")).ranges ==
            setOf(SourceRangeFacet.DOLBY_VISION, SourceRangeFacet.HDR10, SourceRangeFacet.HDR))
    }
    case("codec aliases use token boundaries") {
        val facts = sourceQuickFilterFacts(source("HEVC x265 H.264 AVC AV1 VP9 MPEG-2"))
        check(facts.codecs == setOf(SourceCodecFacet.HEVC, SourceCodecFacet.AVC, SourceCodecFacet.AV1, SourceCodecFacet.VP9, SourceCodecFacet.MPEG2))
        check(sourceQuickFilterFacts(source("bravoav1suffix overhevcative myhdr10movie")).let {
            it.codecs == setOf(SourceCodecFacet.UNKNOWN) && it.ranges == setOf(SourceRangeFacet.UNKNOWN)
        })
    }
    case("negated technical tags do not become positive claims") {
        val facts = sourceQuickFilterFacts(source("No HDR without HEVC not AV1 non-SDR"))
        check(facts.ranges == setOf(SourceRangeFacet.UNKNOWN))
        check(facts.codecs == setOf(SourceCodecFacet.UNKNOWN))
    }
    case("description quality and filename are reported inputs but locator is not") {
        val actual = source("Movie").copy(description = "HDR10", quality = "HLG", filename = "movie.HEVC.mkv",
            url = "https://cdn.invalid/AV1", infoHash = "SDR", id = "DV")
        val facts = sourceQuickFilterFacts(actual)
        check(facts.ranges == setOf(SourceRangeFacet.HDR10, SourceRangeFacet.HLG))
        check(facts.codecs == setOf(SourceCodecFacet.HEVC))
    }
    case("template placeholders and oversized provider labels remain bounded") {
        val template = sourceQuickFilterFacts(source("Movie {HDR10 HEVC}"))
        check(template.ranges == setOf(SourceRangeFacet.UNKNOWN) && template.codecs == setOf(SourceCodecFacet.UNKNOWN))
        val oversized = sourceQuickFilterFacts(source("a".repeat(20_000) + " HDR10 HEVC"))
        check(oversized.ranges == setOf(SourceRangeFacet.UNKNOWN) && oversized.codecs == setOf(SourceCodecFacet.UNKNOWN))
    }
    case("parser is locale independent") {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            check(sourceQuickFilterFacts(source("DOLBY VISION")).ranges == setOf(SourceRangeFacet.DOLBY_VISION))
        } finally { Locale.setDefault(previous) }
    }
    case("same source IDs are never merged or cached as another transport") {
        val first = source("HDR10 HEVC", "duplicate").copy(url = "https://one.invalid/1")
        val second = source("SDR AVC", "duplicate").copy(url = "https://two.invalid/2")
        val input = groups(first, second, first.copy(requestHeaders = mapOf("Referer" to "https://headers.invalid")))
        val selected = rows(input, SourceQuickFilters(range = SourceRangeFacet.HDR10))
        check(selected.size == 2 && selected.first() === first)
        check(selected[1].requestHeaders.isNotEmpty() && selected[1].url == first.url)
        check(rows(input, SourceQuickFilters(range = SourceRangeFacet.SDR)).single() === second)
    }
    case("range codec and cache facets intersect without reordering") {
        val first = source("HDR10 HEVC", "1", "abcd").copy(accountConfirmedCacheRevision = 7L)
        val second = source("HDR10 AVC", "2", "ef01").copy(accountConfirmedCacheRevision = 7L)
        val third = source("HDR10 HEVC", "3")
        val input = groups(first, second, third)
        check(rows(input, SourceQuickFilters(SourceCacheFacet.CONFIRMED, SourceRangeFacet.HDR10, SourceCodecFacet.HEVC)) == listOf(first))
        check(input.single().streams == listOf(first, second, third))
    }
    case("newly empty group slots and same-name provider order remain stable") {
        val first = StreamGroup("Same", listOf(source("HDR10 HEVC")), "")
        val second = StreamGroup("Same", listOf(source("SDR AVC")), "")
        val input = listOf(first, second)
        val selected = SourceQuickFilterIndex(input).matchingGroups(SourceQuickFilters(range = SourceRangeFacet.SDR))
        check(selected.size == input.size && selected[0].streams.isEmpty() && selected[1] === second)
        check(selected.map { it.addon to it.base } == input.map { it.addon to it.base })
    }
    case("empty filter result resets to original complete list") {
        val input = groups(source("HDR10 HEVC"))
        val index = SourceQuickFilterIndex(input)
        check(index.matchingGroups(SourceQuickFilters(codec = SourceCodecFacet.AV1)).single().streams.isEmpty())
        check(index.matchingGroups(SourceQuickFilters()) === input)
        check(SourceQuickFilterIndex(emptyList()).matchingGroups(SourceQuickFilters(cache = SourceCacheFacet.CONFIRMED)).isEmpty())
    }
    case("cheap event revision revokes credential owner and ABA proof while All never blanks") {
        val source = source("Cached HDR10 HEVC", hash = "abcd")
        val marked = markAccountConfirmedCache(groups(source), setOf("abcd"), 7L)
        val index = SourceQuickFilterIndex(marked)
        val confirmed = SourceQuickFilters(cache = SourceCacheFacet.CONFIRMED)
        check(index.matchingGroups(confirmed, 7L).single().streams.size == 1)
        check(index.matchingGroups(confirmed, 8L).single().streams.isEmpty())
        check(index.matchingGroups(confirmed, 9L).single().streams.isEmpty()) // A -> B -> A still has a new event revision.
        check(index.matchingGroups(confirmed).single().streams.isEmpty()) // unavailable witness fails closed.
        check(index.matchingGroups(SourceQuickFilters(), 8L) === marked)
        check(index.matchingGroups(SourceQuickFilters(cache = SourceCacheFacet.UNKNOWN), 8L).single().streams.single() === marked.single().streams.single())
        check(markAccountConfirmedCache(marked, emptySet(), 7L).single().streams.single().accountConfirmedCacheRevision == null)
        val unmarked = groups(source)
        check(markAccountConfirmedCache(unmarked, setOf("abcd"), -1L) === unmarked)
    }
    return count
}
