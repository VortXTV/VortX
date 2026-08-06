package com.vortx.android.sources

import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SeriesSourceStickyRankingTest {

    @After
    fun clearHealth() {
        ProviderHealth.clearForTests()
    }

    @Test
    fun storageContractRoundTripsAndPrunesToNewestOneHundredEighty() {
        assertEquals("stremiox.seriesSourceSticky.profile-a", SeriesSourceSticky.storageKey("profile-a"))
        val choices = (0..200).associate { index ->
            "series-$index" to SeriesSourceSticky.Choice(
                addon = "addon-$index",
                bingeGroup = "group-$index",
                timestamp = index.toDouble(),
            )
        }

        val pruned = SeriesSourceSticky.prune(choices)
        assertEquals(180, pruned.size)
        assertFalse("series-20" in pruned)
        assertTrue("series-21" in pruned)
        assertEquals(pruned, SeriesSourceSticky.decode(SeriesSourceSticky.encode(pruned)))
    }

    @Test
    fun malformedStoredChoiceFailsClosed() {
        assertThrows(Exception::class.java) {
            SeriesSourceSticky.decode("""{"series":{"addon":"A"}}""")
        }
    }

    @Test
    fun providerPenaltyIsCaseInsensitiveDecaysAndCapsAtSixtyFour() {
        ProviderHealth.noteFailure("  AddOn A  ", nowMs = 1_000L)
        assertTrue(ProviderHealth.penaltyActive("addon a", nowMs = 1_000L))
        assertTrue(ProviderHealth.penaltyActive("ADDON A", nowMs = 600_999L))
        assertFalse(ProviderHealth.penaltyActive("addon a", nowMs = 601_000L))

        repeat(70) { ProviderHealth.noteFailure("provider-$it", nowMs = 10_000L + it) }
        val active = ProviderHealth.activeAddons(nowMs = 10_100L)
        assertEquals(ProviderHealth.MAX_PROVIDERS, active.size)
        assertFalse("provider-0" in active)
        assertTrue("provider-69" in active)
    }

    @Test
    fun stickyAndHealthUseOneBoundedBonusBlockAndKeepBestInSyncWithCandidates() {
        val first = source("first", "Provider A", "2160p Remux HDR")
        val sticky = source("sticky", "Provider B", "2160p Remux HDR", bingeGroup = "release-b")
        val groups = listOf(
            StreamGroup("Provider A", listOf(first)),
            StreamGroup("Provider B", listOf(sticky)),
        )
        val preference = SeriesSourceSticky.Preference(addon = "provider b", bingeGroup = "release-b")

        assertEquals(StreamRanking.STICKY_WEIGHT, StreamRanking.stickyBonus(sticky, "Provider B", preference))
        assertEquals(
            StreamRanking.CALLER_BONUS_CEILING,
            StreamRanking.callerBonuses(sticky, "Provider B", "2160p remux hdr", "release-b", preference),
        )

        val winner = StreamRanking.best(
            groups,
            continuity = null,
            sticky = preference,
            providerPenalty = { it.equals("Provider A", ignoreCase = true) },
        )
        val candidates = StreamRanking.rankedCandidates(
            groups,
            continuity = null,
            sticky = preference,
            providerPenalty = { it.equals("Provider A", ignoreCase = true) },
        )
        assertEquals(sticky, winner)
        assertEquals(winner, candidates.first())
    }

    @Test
    fun recentFailureDemotesAnOtherwiseEqualProvider() {
        val failed = source("failed", "Provider A", "1080p WEB-DL")
        val healthy = source("healthy", "Provider B", "1080p WEB-DL")
        val groups = listOf(
            StreamGroup("Provider A", listOf(failed)),
            StreamGroup("Provider B", listOf(healthy)),
        )

        val winner = StreamRanking.best(
            groups,
            continuity = null,
            providerPenalty = { it == "Provider A" },
        )
        assertEquals(healthy, winner)
    }

    @Test
    fun wantedProviderWaitsThenOpensOnMatchSettlementOrDeadline() {
        val ready = listOf(StreamGroup("Provider A", listOf(source("a", "Provider A", "1080p"))))

        assertFalse(StreamRanking.resolveSettled(ready, 1, 2, 5.0, "1080p", wantedAddon = "Provider B"))
        assertTrue(
            StreamRanking.resolveSettled(
                ready + StreamGroup("provider b", listOf(source("b", "provider b", "1080p"))),
                1,
                2,
                5.0,
                "1080p",
                wantedAddon = "Provider B",
            ),
        )
        assertTrue(StreamRanking.resolveSettled(ready, 2, 2, 5.0, "1080p", wantedAddon = "Provider B"))
        assertTrue(StreamRanking.resolveSettled(ready, 1, 2, 12.01, "1080p", wantedAddon = "Provider B"))
        assertTrue(StreamRanking.resolveSettled(ready, 1, 2, 4.01, null, wantedAddon = "Provider B"))

        val trailerOnly = ready + StreamGroup(
            "Provider B",
            listOf(
                StreamSource(
                    id = "trailer",
                    addon = "Provider B",
                    title = "Trailer",
                    ytId = "video-id",
                ),
            ),
        )
        assertFalse(StreamRanking.resolveSettled(trailerOnly, 1, 2, 5.0, "1080p", wantedAddon = "Provider B"))
    }

    private fun source(
        id: String,
        addon: String,
        title: String,
        bingeGroup: String? = null,
    ) = StreamSource(
        id = id,
        addon = addon,
        title = title,
        url = "https://example.invalid/$id",
        bingeGroup = bingeGroup,
    )
}
