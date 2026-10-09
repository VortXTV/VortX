package com.vortx.android.sources

import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SourceMatchConfidenceTest {
    @Test
    fun configuredConfidenceExcludesWrongShowAndEpisodeFromProductionRanking() {
        val good = source("good", "Severance.S01E02.1080p.WEB-DL.mkv")
        val groups = listOf(StreamGroup("Addon", listOf(
            good,
            source("wrong-show", "Succession.S01E02.2160p.REMUX.mkv"),
            source("wrong-episode", "Severance.S01E03.2160p.REMUX.mkv"),
        )))
        val ranked = StreamRanking.rankedGroups(
            groups, prefs = SourcePrefsSnapshot.DEFAULT.copy(matchConfidenceThreshold = 90),
            matchContext = show("Severance", 1, 2),
        )
        assertEquals(listOf(good), ranked.flatMap { it.streams })
    }

    @Test fun exactReleaseNamesNormalizeNoiseAndDiacritics() {
        for (filename in listOf("Amélie.2001.1080p.WEB-DL.x264.mkv", "Amelie (2001) [1080p] [YTS].mp4")) {
            assertEquals(100, SourceMatchConfidence.score(source("a", filename), SourceMatchContext.create("Amélie", year = 2001)))
        }
        assertEquals(100, score("The.White.Lotus.S02E03.2160p.HDR.DDP5.1-GROUP.mkv", "The White Lotus", 2, 3))
        assertEquals(100, score("Law.and.Order.S01E02.1080p.mkv", "Law & Order", 1, 2))
    }

    @Test fun literalMetadataWordsAndBracketedTitlesAreNotDiscardedOrAcceptedAsSubstrings() {
        val complete = SourceMatchContext.create("A Complete Unknown", year = 2024)
        assertEquals(100, SourceMatchConfidence.score(source("a", "A.Complete.Unknown.2024.1080p.WEB-DL.mkv"), complete))
        for (wrong in listOf("Almost.Complete.Unknown.2024.1080p.mkv", "A.Complete.Stranger.2024.1080p.mkv",
            "A.Complete.Unknown.2023.1080p.mkv", "A.Complete.Unknown.S01E02.1080p.mkv")) {
            assertFalse(wrong, SourceMatchConfidence.passes(source("a", wrong), 90, complete))
        }
        val rec = SourceMatchContext.create("[REC]", year = 2007)
        assertEquals(100, SourceMatchConfidence.score(source("a", "[REC].2007.1080p.BluRay.mkv"), rec))
        assertEquals(100, SourceMatchConfidence.score(source("a", "[YTS].[REC].2007.1080p.BluRay.mkv"), rec))
        for (wrong in listOf("[REC2].2007.1080p.mkv", "Another.Movie.[REC].2007.1080p.mkv", "[REC].2009.1080p.mkv")) {
            assertFalse(wrong, SourceMatchConfidence.passes(source("a", wrong), 90, rec))
        }
        assertEquals(0, SourceMatchConfidence.score(source("a", "").copy(filename = null, addon = "[REC]", title = "[REC] 1080p"), rec))
        assertEquals(0, SourceMatchConfidence.score(source("a", "").copy(filename = null, addon = "A Complete Unknown", title = "A Complete Unknown 1080p"), complete))
    }

    @Test fun explicitEpisodeCodesAndRemakeYearsNeverReceiveHighScores() {
        for (filename in listOf("Severance.S01E03.mkv", "Severance.S02E02.mkv", "Severance.1x03.mkv",
            "Severance.Season.2.Episode.2.mkv", "Severance.S01E02.S02E03.mkv", "Severance.S01E02.2x03.mkv")) {
            assertEquals(filename, 0, score(filename, "Severance", 1, 2))
        }
        assertEquals(0, SourceMatchConfidence.score(source("a", "Dune.1984.1080p.mkv"), SourceMatchContext.create("Dune", year = 2021)))
        assertEquals(0, SourceMatchConfidence.score(source("a", "Doctor.Who.1963.S01E02.mkv"),
            SourceMatchContext.create("Doctor Who", year = 2005, isSeries = true, season = 1, episode = 2)))
        assertEquals(100, SourceMatchConfidence.score(source("a", "Doctor.Who.S01E02.2025.1080p.mkv"),
            SourceMatchContext.create("Doctor Who", year = 2005, isSeries = true, season = 1, episode = 2)))
    }

    @Test fun seasonAndEpisodePacksHaveExplicitCapsAndMembership() {
        assertEquals(70, score("Severance.S01.Complete.1080p.mkv", "Severance", 1, 2))
        assertEquals(0, score("Severance.S02.Complete.1080p.mkv", "Severance", 1, 2))
        assertEquals(95, score("Severance.S01E01-E03.1080p.mkv", "Severance", 1, 2))
        assertEquals(0, score("Severance.S01E01E03.1080p.mkv", "Severance", 1, 2))
        assertEquals(0, score("Severance.S01E01-E03.1080p.mkv", "Severance", 1, 4))
        assertEquals(95, score("Severance.1x01-03.1080p.mkv", "Severance", 1, 2))
        assertEquals(0, score("Severance.S01E01-E03E05.1080p.mkv", "Severance", 1, 4))
    }

    @Test fun animeAliasesAndAbsoluteEpisodeEvidenceUseMetadataNumbering() {
        val anime = SourceMatchContext.create("進撃の巨人", aliases = listOf("Shingeki no Kyojin", "Attack on Titan"),
            isSeries = true, season = 1, episode = 3)
        assertEquals(100, SourceMatchConfidence.score(source("a", "[SubsPlease] Shingeki no Kyojin - 03 (1080p) [ABC123].mkv"), anime))
        assertEquals(0, SourceMatchConfidence.score(source("a", "[SubsPlease] Shingeki no Kyojin - 04 (1080p).mkv"), anime))
        assertEquals(60, score("Attack.on.Titan - 03 (1080p).mkv", "Attack on Titan", 2, 3))
        assertEquals(100, score("進撃の巨人.S01E03.1080p.mkv", "進撃の巨人", 1, 3))
    }

    @Test fun numericTitlesAreNotReleaseYearsOrFuzzySequelNumbers() {
        assertEquals(100, score("1899.S01E02.1080p.mkv", "1899", 1, 2))
        assertEquals(100, SourceMatchConfidence.score(source("a", "2001.A.Space.Odyssey.1968.1080p.mkv"),
            SourceMatchContext.create("2001: A Space Odyssey", year = 1968)))
        assertEquals(0, SourceMatchConfidence.score(source("a", "1917.2019.1080p.mkv"), SourceMatchContext.create("1923", year = 2022)))
    }

    @Test fun missingEvidenceFailsEnabledThresholdAndNeverUsesProviderBadges() {
        val context = show("Severance", 1, 2)
        assertEquals(60, score("Severance.1080p.mkv", "Severance", 1, 2))
        val unknown = source("a", "").copy(filename = null, addon = "Severance", title = "2160p HDR Cached", quality = "Severance S01E02")
        assertEquals(0, SourceMatchConfidence.score(unknown, context))
        assertFalse(SourceMatchConfidence.passes(unknown, 1, context))
        assertTrue(SourceMatchConfidence.passes(unknown, 0, context))
        val fromDescription = unknown.copy(description = "Severance.S01E02.1080p.WEB-DL\n💾 5 GB")
        assertEquals(100, SourceMatchConfidence.score(fromDescription, context))
        assertEquals(0, SourceMatchConfidence.score(fromDescription.copy(filename = "Severance.S01E03.mkv"), context))
        assertEquals(0, SourceMatchConfidence.score(fromDescription.copy(description = "Severance.S01E03", title = "Severance"), context))
        val providerLabel = unknown.copy(addon = "Movie", title = "Movie 4K HDR Cached")
        assertEquals(0, SourceMatchConfidence.score(providerLabel, SourceMatchContext.create("Movie")))
        assertEquals(100, SourceMatchConfidence.score(providerLabel.copy(filename = "Movie.2023.1080p.mkv"),
            SourceMatchContext.create("Movie", year = 2023)))
    }

    @Test fun similarityPercentageHasDeterministicInclusiveBoundary() {
        val context = show("White Lotus", 1, 2)
        val release = source("a", "White.Lotus.Special.S01E02.mkv")
        assertEquals(80, SourceMatchConfidence.score(release, context))
        assertTrue(SourceMatchConfidence.passes(release, 80, context))
        assertFalse(SourceMatchConfidence.passes(release, 81, context))
        assertEquals(89, score("Sevrance.S01E02.mkv", "Severance", 1, 2))
    }

    private fun show(title: String, season: Int, episode: Int) = SourceMatchContext.create(
        title, isSeries = true, season = season, episode = episode,
    )

    private fun score(filename: String, title: String, season: Int, episode: Int) =
        SourceMatchConfidence.score(source("a", filename), show(title, season, episode))

    private fun source(id: String, filename: String) = StreamSource(
        id = id, addon = "Addon", title = "Cached 4K", filename = filename,
        url = "https://example.invalid/$id", bingeGroup = "release-family",
    )
}
