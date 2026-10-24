package com.vortx.android.ui.randompick

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class RandomPickPolicyTest {
    private val now = Instant.parse("2026-10-23T12:00:00Z")
    private val movie = MetaItem("same-id", MediaType.MOVIE, "Movie")
    private val show = MetaItem("same-id", MediaType.SERIES, "Show")

    @Test
    fun `library candidates exclude blank unavailable and live rows`() {
        val items = listOf(
            movie.copy(id = " "),
            movie.copy(name = "\t"),
            movie.copy(id = "unavailable", continueWatchingUnavailableMessage = "Try again"),
            movie.copy(id = "empty-message", continueWatchingUnavailableMessage = ""),
            movie.copy(id = "channel", type = MediaType.CHANNEL),
            movie.copy(id = "tv", type = MediaType.TV),
            movie,
            show,
        )

        assertEquals(listOf(movie, show), RandomPickPolicy.libraryCandidates(items, RandomLibraryFilter.ALL))
    }

    @Test
    fun `movie and show filters retain only their requested VOD type`() {
        val items = listOf(show, movie)

        assertEquals(listOf(movie), RandomPickPolicy.libraryCandidates(items, RandomLibraryFilter.MOVIES))
        assertEquals(listOf(show), RandomPickPolicy.libraryCandidates(items, RandomLibraryFilter.SHOWS))
        assertTrue(RandomPickPolicy.libraryCandidates(emptyList(), RandomLibraryFilter.ALL).isEmpty())
    }

    @Test
    fun `library deduplication preserves the first valid exact typed identity`() {
        val renamedDuplicate = movie.copy(name = "Later copy")
        val differentCase = movie.copy(id = "SAME-ID")
        val items = listOf(movie.copy(name = ""), movie, renamedDuplicate, show, differentCase)
        val candidates = RandomPickPolicy.libraryCandidates(items, RandomLibraryFilter.ALL)

        assertEquals(listOf(movie, show, differentCase), candidates)
        assertSame(movie, candidates.first())
    }

    @Test
    fun `episode candidates require a valid series detail identity`() {
        val detail = series(listOf(episode("first", 1, 1)))

        assertTrue(RandomPickPolicy.episodeCandidates(detail.copy(type = MediaType.MOVIE), now).isEmpty())
        assertTrue(RandomPickPolicy.episodeCandidates(detail.copy(type = MediaType.TV), now).isEmpty())
        assertTrue(RandomPickPolicy.episodeCandidates(detail.copy(type = MediaType.CHANNEL), now).isEmpty())
        assertTrue(RandomPickPolicy.episodeCandidates(detail.copy(id = " "), now).isEmpty())
        assertTrue(RandomPickPolicy.episodeCandidates(detail.copy(name = ""), now).isEmpty())
    }

    @Test
    fun `unknown release dates remain eligible while known future timestamps are excluded`() {
        val past = episode("past", 1, 1)
        val atNow = episode("now", 1, 2, now.toString())
        val offsetAtNow = episode("offset", 1, 3, "2026-10-23T14:00:00+02:00")
        val unknown = episode("unknown", 1, 4, null)
        val blank = episode("blank", 1, 5, " ")
        val malformed = episode("malformed", 1, 6, "not-a-date")
        val future = episode("future", 1, 8, now.plusNanos(1).toString())
        val paddedFuture = episode("padded-future", 1, 9, " ${now.plusNanos(1)} ")
        val paddedOffsetFuture = episode("padded-offset-future", 1, 10, " 2026-10-23T14:00:01+02:00 ")
        val candidates = RandomPickPolicy.episodeCandidates(
            series(listOf(past, atNow, offsetAtNow, unknown, blank, malformed, future, paddedFuture, paddedOffsetFuture)),
            now,
        )

        assertEquals(listOf(past, atNow, offsetAtNow, unknown, blank, malformed), candidates)
    }

    @Test
    fun `picker date-only parsing allows past and today but blocks future until UTC midnight`() {
        val past = episode("past-date", 1, 1, "2020-01-01")
        val today = episode("today-date", 1, 2, "2026-10-23")
        val future = episode("future-date", 1, 3, "2026-10-24")
        val paddedFuture = episode("padded-future-date", 1, 4, " 2026-10-24 ")
        val invalidCalendarDate = episode("invalid-date", 1, 5, "2026-02-30")
        val detail = series(listOf(past, today, future, paddedFuture, invalidCalendarDate))

        assertNull(today.releasedDate)
        assertEquals(listOf(past, today, invalidCalendarDate), RandomPickPolicy.episodeCandidates(detail, now))
        assertEquals(
            listOf(past, today, future, paddedFuture, invalidCalendarDate),
            RandomPickPolicy.episodeCandidates(detail, Instant.parse("2026-10-24T00:00:00Z")),
        )
    }

    @Test
    fun `episode candidates include S0E0 and episode zero in every season but reject negative coordinates and blank labels`() {
        val specialZero = episode("special-zero", 0, 0)
        val special = episode("special", 0, 1)
        val seasonOneZero = episode("season-one-zero", 1, 0)
        val first = episode("season-one", 1, 1)
        val later = episode("season-four", 4, 12)
        val candidates = RandomPickPolicy.episodeCandidates(
            series(listOf(
                specialZero,
                special,
                seasonOneZero,
                first,
                later,
                episode("negative-season", -1, 1),
                episode("negative-episode", 1, -1),
                episode(" ", 1, 2),
                episode("blank-title", 1, 3).copy(title = "\t"),
            )),
            now,
        )

        assertEquals(listOf(specialZero, special, seasonOneZero, first, later), candidates)
    }

    @Test
    fun `repeated episode identities with matching coordinates have one valid candidate`() {
        val first = episode("opaque-video-id", 2, 3)
        val invalidFirst = first.copy(title = "")
        val repeated = first.copy(title = "Later provider title")
        val other = episode("other-video-id", 1, 1)
        val candidates = RandomPickPolicy.episodeCandidates(series(listOf(invalidFirst, other, first, repeated)), now)

        assertEquals(listOf(other, first), candidates)
        assertSame(first, candidates.last())
    }

    @Test
    fun `forged duplicate video identity with different coordinates is excluded before eligibility filtering`() {
        val valid = episode("ambiguous", 1, 1)
        val forgedFuture = valid.copy(season = 2, released = now.plusSeconds(60).toString())
        val other = episode("other", 1, 2)
        assertEquals(
            listOf(other),
            RandomPickPolicy.episodeCandidates(series(listOf(valid, forgedFuture, other)), now),
        )
        val forgedInvalid = valid.copy(episode = -1, released = null)
        assertEquals(
            listOf(other),
            RandomPickPolicy.episodeCandidates(series(listOf(forgedInvalid, valid, other)), now),
        )
    }

    @Test
    fun `empty candidates return no selection without invoking key or random`() {
        val picked = RandomPickPolicy.pick<String>(
            emptyList(),
            currentKey = "current",
            key = { error("No empty-list key lookup") },
            nextInt = { error("No empty-list randomness") },
        )

        assertNull(picked)
    }

    @Test
    fun `a singleton remains selectable even when it is current without invoking random`() {
        val picked = RandomPickPolicy.pick(
            listOf(movie),
            currentKey = titleKey(movie),
            key = ::titleKey,
            nextInt = { error("No singleton randomness") },
        )

        assertSame(movie, picked)
    }

    @Test
    fun `repeat avoidance excludes the current typed identity only when alternatives exist`() {
        val other = movie.copy(id = "other", name = "Other")
        val requestedBounds = mutableListOf<Int>()
        val picked = RandomPickPolicy.pick(
            listOf(movie, movie.copy(name = "Duplicate current"), show, other),
            currentKey = titleKey(movie),
            key = ::titleKey,
            nextInt = { bound -> requestedBounds += bound; bound - 1 },
        )

        assertSame(other, picked)
        assertEquals(listOf(2), requestedBounds)
        assertSame(
            show,
            RandomPickPolicy.pick(listOf(movie, show), titleKey(movie), ::titleKey) {
                error("The sole alternate needs no randomness")
            },
        )
    }

    @Test
    fun `injected random index deterministically selects from the full pool when current is absent`() {
        val items = listOf(movie, show)
        val requestedBounds = mutableListOf<Int>()
        val picked = RandomPickPolicy.pick(items, currentKey = "movie:missing", key = ::titleKey) { bound ->
            requestedBounds += bound
            1
        }

        assertSame(show, picked)
        assertEquals(listOf(2), requestedBounds)
        assertSame(movie, RandomPickPolicy.pick(items, null, ::titleKey) { 0 })
    }

    @Test
    fun `preview requires the same account profile generation and current permission`() {
        val owner = Owner("account-a", "profile-a", generation = 4L)
        val preview = RandomPickPreview(movie, owner)

        assertSame(movie, preview.currentOrNull(owner.copy(), allowed = true))
        assertNull(preview.currentOrNull(owner.copy(account = "account-b"), allowed = true))
        assertNull(preview.currentOrNull(owner.copy(profile = "profile-b"), allowed = true))
        assertNull(preview.currentOrNull(owner.copy(generation = 5L), allowed = true))
        assertNull(preview.currentOrNull(owner, allowed = false))
    }

    private fun titleKey(item: MetaItem): String = "${item.type.id}:${item.id}"

    private fun series(episodes: List<Episode>) = MetaDetail("series-id", MediaType.SERIES, "Series", videos = episodes)

    private fun episode(id: String, season: Int, number: Int, released: String? = "2020-01-01T00:00:00Z") =
        Episode(id, "Episode $number", season, number, released = released)

    private data class Owner(val account: String, val profile: String, val generation: Long)
}
