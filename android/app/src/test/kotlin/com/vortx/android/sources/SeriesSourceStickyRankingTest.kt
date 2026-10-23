package com.vortx.android.sources

import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SeriesSourceStickyRankingTest {

    private class MemoryPersistence : SeriesSourceStickyPersistence {
        private val values = mutableMapOf<String, String>()
        override fun read(key: String): String? = synchronized(values) { values[key] }
        override fun write(key: String, value: String): Boolean = synchronized(values) {
            values[key] = value
            true
        }
        override fun contains(key: String): Boolean = synchronized(values) { key in values }
    }

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
    fun twoInstancesMergeAgainstLatestPersistenceWithoutLosingEitherSeries() {
        val persistence = MemoryPersistence()
        var now = 1_000L
        val first = SeriesSourceSticky(persistence, activeProfileId = { "profile-a" }, nowMs = { now++ })
        val second = SeriesSourceSticky(persistence, activeProfileId = { "profile-a" }, nowMs = { now++ })

        // Prime both instance caches with the same empty snapshot before either writes.
        assertNull(first.preference("show-a"))
        assertNull(second.preference("show-b"))
        first.record("show-a", "Provider A", "release-a")
        second.record("show-b", "Provider B", "release-b")

        assertEquals("Provider A", first.preference("show-a")?.addon)
        assertEquals("Provider B", first.preference("show-b")?.addon)
        assertEquals("Provider A", second.preference("show-a")?.addon)
        assertEquals("Provider B", second.preference("show-b")?.addon)
    }

    @Test
    fun capturedWriteIsRejectedAcrossProfileRoundTrip() {
        val persistence = MemoryPersistence()
        var profile = "profile-a"
        val sticky = SeriesSourceSticky(persistence, activeProfileId = { profile })
        val stale = sticky.capture("show")!!

        profile = "profile-b"
        sticky.onProfileChanged()
        profile = "profile-a"
        sticky.onProfileChanged()

        assertFalse(sticky.record(stale, "Provider A", "release-a"))
        assertNull(sticky.preference("show"))
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

    @Test
    fun bingeKeepsTheChosenQualityAfterOneFallbackEpisode() {
        // The viewer picked 1080p. One episode had no 1080p and played the 720p release, so the hints from the
        // stream playing now name the 720p release. The next episode has both again.
        val full = source("full", "Provider A", "Show S01E03 1080p WEB-DL", bingeGroup = "a-1080")
        val fallback = source("fallback", "Provider A", "Show S01E03 720p WEB-DL", bingeGroup = "a-720")
        val groups = listOf(StreamGroup("Provider A", listOf(fallback, full)))
        val hint = StreamRanking.signature(fallback)

        val withoutFloor = SeriesSourceSticky.Preference(addon = "Provider A", bingeGroup = "a-1080")
        assertEquals(
            "the slide this guards against",
            fallback,
            StreamRanking.best(groups, continuity = hint, binge = "a-720", sticky = withoutFloor),
        )

        val chosen = withoutFloor.copy(resolution = StreamRanking.knownResolution(full))
        assertEquals(1080, chosen.resolution)
        assertEquals(full, StreamRanking.best(groups, continuity = hint, binge = "a-720", sticky = chosen))
        assertEquals(full, StreamRanking.rankedCandidates(groups, continuity = hint, binge = "a-720", sticky = chosen).first())
    }

    @Test
    fun aLowerReleaseIsStillTheFallbackWhenNothingMeetsTheFloor() {
        val only = source("only", "Provider A", "Show S01E04 720p WEB-DL", bingeGroup = "a-720")
        val chosen = SeriesSourceSticky.Preference(addon = "Provider A", bingeGroup = "a-1080", resolution = 1080)

        assertEquals(
            only,
            StreamRanking.best(listOf(StreamGroup("Provider A", listOf(only))), continuity = "720p", binge = "a-720", sticky = chosen),
        )
    }

    @Test
    fun explicitPickRemembersItsResolutionAndOlderRecordsHaveNoFloor() {
        val persistence = MemoryPersistence()
        val sticky = SeriesSourceSticky(persistence, activeProfileId = { "profile-a" })
        sticky.record("show", "Provider A", "a-1080", resolution = 1080)
        assertEquals(1080, sticky.preference("show")?.resolution)

        val legacy = SeriesSourceSticky.decode("""{"show":{"addon":"Provider A","bingeGroup":"g","ts":1.0}}""")
        assertNull(legacy.getValue("show").resolution)
        val roundTrip = SeriesSourceSticky.decode(SeriesSourceSticky.encode(mapOf("show" to legacy.getValue("show").copy(resolution = 2160))))
        assertEquals(2160, roundTrip.getValue("show").resolution)
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
