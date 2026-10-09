package com.vortx.android.sources

import com.vortx.android.engine.SourceListModel
import com.vortx.android.engine.EngineState
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executors

class SourceMatchConfidencePipelineTest {
    private val prefs = SourcePrefsSnapshot.DEFAULT.copy(useAddonOrder = true, matchConfidenceThreshold = 90)
    private val context = SourceMatchContext.create("Severance", isSeries = true, season = 1, episode = 2)
    private fun source(id: String, episode: Int = 2) = StreamSource(
        id = id, addon = "Addon", title = "Cached 4K", filename = "Severance.S01E0$episode.mkv",
        url = "https://example.invalid/$id", bingeGroup = "same-release",
        requestHeaders = mapOf("X-Test" to "retained"),
    )
    private fun group(vararg sources: StreamSource) = StreamGroup("Addon", sources.toList())

    @Test fun everyRankingEntryPointFiltersBeforePinsContinuityAndDownloads() {
        val good = source("good")
        val wrong = source("wrong", 3)
        val groups = listOf(group(wrong, good))
        val pin = ResolvedPin(SourcePin(addon = "Addon", quality = "4K", flavor = "", bingeGroup = "same-release"), SourcePinScope.GLOBAL)
        assertEquals(listOf(good), StreamRanking.rankedGroups(groups, prefs, pin, context).flatMap { it.streams })
        assertSame(good, StreamRanking.best(groups, prefs, pin, context))
        assertSame(good, StreamRanking.best(groups, continuity = "4k", binge = "same-release", pin = pin,
            prefs = prefs, matchContext = context))
        assertEquals(listOf(good), StreamRanking.rankedCandidates(groups, continuity = "4k", pin = pin,
            prefs = prefs, matchContext = context))
        assertEquals(listOf(good), StreamRanking.rankedFlat(groups, prefs = prefs, matchContext = context))
        assertEquals(listOf(good), StreamRanking.applyUserFilters(groups, prefs, context).flatMap { it.streams })
        assertFalse(StreamRanking.passesUserFilters(wrong, prefs, context))
        assertEquals("https://example.invalid/good", good.url)
        assertEquals(mapOf("X-Test" to "retained"), good.requestHeaders)
    }

    @Test fun sharedAssemblyFiltersEveryContributorAndShownQualityBucket() {
        val good = source("good")
        val wrong = source("wrong", 3)
        val assembled = SourceListModel.assemble(
            raw = listOf(group(wrong, good)), torboxStreams = listOf(wrong.copy(id = "torbox")),
            singularityStreams = listOf(wrong.copy(id = "pool")),
            communityJsGroups = listOf(group(wrong.copy(id = "custom"))),
            mediaServerGroups = listOf(group(wrong.copy(id = "server", isMediaServer = true))),
            ctx = SourceListModel.Context(metaId = "custom:show", streamId = "opaque-episode", requestGeneration = 42,
                prefs = prefs, matchContext = context),
        )
        assertEquals(listOf(good), assembled.groups.flatMap { it.streams })
        assertSame(good, assembled.best)
        assertEquals(listOf(good), assembled.resolutionOptions.map { it.second })
        assertEquals(42L, assembled.requestGeneration)
        assertEquals("opaque-episode", assembled.streamId)
    }

    @Test fun offRetainsMissingWrongAndPackSourcesAndOriginalOrder() {
        val groups = listOf(group(source("wrong", 3), source("unknown").copy(filename = null), source("good")))
        val off = prefs.copy(matchConfidenceThreshold = 0)
        assertEquals(groups, StreamRanking.rankedGroups(groups, off, matchContext = context))
        assertTrue(off.noFiltersActive)
        assertNotEquals(off.cacheTag, prefs.cacheTag)
        // Raw repository ranking defers title filtering until request-bound final assembly.
        assertEquals(groups, StreamRanking.rankedGroups(groups, prefs))
    }

    @Test fun customEpisodeIdsUseExactMetadataAndAliasesAreFrozen() {
        val aliases = mutableListOf("Severance")
        val detail = MetaDetail("custom:show", MediaType.SERIES, "Localized name", titleAliases = aliases,
            videos = listOf(Episode(id = "unparseable-custom-id", title = "Episode", season = 1, episode = 2)))
        val captured = SourceMatchContext.from(detail, "unparseable-custom-id")
        aliases[0] = "Different Show"
        assertEquals(100, SourceMatchConfidence.score(source("good"), captured))
        assertEquals(0, SourceMatchConfidence.score(source("wrong", 3), captured))
        assertEquals(60, SourceMatchConfidence.score(source("unknown"), SourceMatchContext.from(detail.copy(titleAliases = listOf("Severance")), "other-id")))
    }

    @Test fun actualMetadataProjectionDecodesKnownNamesWithoutChangingTargetIdentity() {
        val detail = requireNotNull(EngineState.parseMetaDetail("""{"metaItems":[{"content":{"type":"Ready","content":{
            "id":"custom:show","type":"series","name":"Localized name","originalName":"Severance",
            "aliases":["Original alias", {"title":"Alternate name"},42,null],
            "videos":[{"id":"opaque-episode","season":1,"episode":2,"title":"Episode"}]
        }}}]}"""))
        assertEquals("custom:show", detail.id)
        assertEquals(listOf("Severance", "Original alias", "Alternate name"), detail.titleAliases)
        assertEquals(100, SourceMatchConfidence.score(source("good"), SourceMatchContext.from(detail, "opaque-episode")))
        assertEquals(0, SourceMatchConfidence.score(source("wrong", 3), SourceMatchContext.from(detail, "opaque-episode")))
    }

    @Test fun parallelRequestsNeverReadAnotherTitleOrInstalledOwnerPreferences() {
        val otherContext = SourceMatchContext.create("Succession", isSeries = true, season = 4, episode = 1)
        val other = source("other").copy(filename = "Succession.S04E01.mkv")
        val good = source("good")
        val groups = listOf(group(other, good))
        val executor = Executors.newFixedThreadPool(2)
        try {
            val futures = listOf(context to good, otherContext to other).map { (target, expected) ->
                executor.submit<Boolean> {
                    repeat(40) {
                        StreamRanking.installReading(SourcePrefsSnapshot.DEFAULT.copy(maxResolution = 720))
                        assertSame(expected, StreamRanking.best(groups, prefs = prefs, matchContext = target))
                    }
                    true
                }
            }
            futures.forEach { assertTrue(it.get()) }
        } finally {
            executor.shutdownNow()
            StreamRanking.installReading(SourcePrefsSnapshot.DEFAULT)
        }
    }

    @Test fun sameFlavorPickerWinnerUsesCapturedAudioHintInsteadOfOppositeGlobalPreferences() {
        val english = source("picker-english").copy(title = "1080p WEB-DL", filename = "Severance.S01E02.1080p.WEB-DL.English.mkv")
        val hindi = source("picker-hindi").copy(title = "1080p WEB-DL", filename = "Severance.S01E02.1080p.WEB-DL.Hindi.mkv")
        val groups = listOf(group(english, hindi))
        val captured = prefs.copy(audioLanguages = listOf("hi"))
        try {
            StreamRanking.installReading(prefs.copy(audioLanguages = listOf("en")))
            // Prove this fixture exposes the old global-reading winner, not merely an equal-score tie.
            assertSame(english, StreamRanking.variantOptions(groups, "1080p").single().second)
            assertSame(hindi, StreamRanking.variantOptions(groups, "1080p", prefs = captured).single().second)
            assertSame(hindi, StreamRanking.qualityOptions(groups, prefs = captured).single().second)
            assertSame(hindi, StreamRanking.resolutionOptions(groups, prefs = captured).single().second)
            StreamRanking.installReading(captured)
            assertSame(english, StreamRanking.variantOptions(groups, "1080p", prefs = prefs.copy(audioLanguages = listOf("en"))).single().second)
        } finally {
            StreamRanking.installReading(SourcePrefsSnapshot.DEFAULT)
        }
    }
}
