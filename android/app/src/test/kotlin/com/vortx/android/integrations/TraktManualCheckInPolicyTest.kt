package com.vortx.android.integrations

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TraktManualCheckInPolicyTest {
    private val movie = MetaDetail(id = "tt1234567", type = MediaType.MOVIE, name = "Film")
    private val series = MetaDetail(id = "tmdb:tv:42", type = MediaType.SERIES, name = "Show")
    private val episode = Episode(id = "ep-2", title = "Episode", season = 2, episode = 5)

    @Test fun `movie target needs only its title identity`() {
        assertEquals(TraktManualCheckInPolicy.Target.Movie("tt1234567"),
            TraktManualCheckInPolicy.target(movie, null))
    }

    @Test fun `series target is the same primary episode and never the whole show`() {
        assertEquals(TraktManualCheckInPolicy.Target.EpisodeTarget("tmdb:42", 2, 5),
            TraktManualCheckInPolicy.target(series, episode))
        assertNull(TraktManualCheckInPolicy.target(series, null))
    }

    @Test fun `explicitly selected special episode with season zero is valid`() {
        val special = episode.copy(season = 0, episode = 2)
        assertEquals(TraktManualCheckInPolicy.Target.EpisodeTarget("tmdb:42", 0, 2),
            TraktManualCheckInPolicy.target(series, special))
    }

    @Test fun `series with no resolved episode and unusable id cannot be offered`() {
        assertNull(TraktManualCheckInPolicy.target(series, null))
        val unusable = movie.copy(id = "catalog:film:77")
        assertNull(TraktManualCheckInPolicy.target(unusable, null))
        assertNull(TraktManualCheckInPolicy.target(movie.copy(type = MediaType.TV), null))
    }

    @Test fun `disconnected and opted out states hide the action`() {
        val target = TraktManualCheckInPolicy.target(movie, null)
        assertFalse(TraktManualCheckInPolicy.canOffer(true, true, true, false, target))
        assertFalse(TraktManualCheckInPolicy.canOffer(true, false, true, true, target))
        assertFalse(TraktManualCheckInPolicy.canOffer(true, true, false, true, target))
    }

    @Test fun `stale async completion is discarded after account profile title or episode changes`() {
        val request = TraktManualCheckInPolicy.Owner(8, "OWNER", "tt1234567", TraktManualCheckInPolicy.Target.Movie("tt1234567"))
        val changedAccount = request.copy(accountEpoch = 9)
        val changedProfile = request.copy(profileId = "GUEST")
        val changedTitle = request.copy(titleId = "tt7654321")
        assertNull(TraktManualCheckInPolicy.completion(changedAccount, request, TraktManualCheckInPolicy.RequestState.SUCCESS))
        assertNull(TraktManualCheckInPolicy.completion(changedProfile, request, TraktManualCheckInPolicy.RequestState.SUCCESS))
        assertNull(TraktManualCheckInPolicy.completion(changedTitle, request, TraktManualCheckInPolicy.RequestState.SUCCESS))
        val seriesOwner = request.copy(target = TraktManualCheckInPolicy.Target.EpisodeTarget("tt1234567", 1, 1))
        val otherEpisode = seriesOwner.copy(target = TraktManualCheckInPolicy.Target.EpisodeTarget("tt1234567", 1, 2))
        assertNull(TraktManualCheckInPolicy.completion(otherEpisode, seriesOwner, TraktManualCheckInPolicy.RequestState.SUCCESS))
    }

    @Test fun `only one request runs and accepted outcomes distinguish success conflict failure`() {
        val owner = TraktManualCheckInPolicy.Owner(8, "OWNER", "tt1234567", TraktManualCheckInPolicy.Target.Movie("tt1234567"))
        val request = TraktManualCheckInPolicy.begin(TraktManualCheckInPolicy.RequestState.IDLE, owner)
        assertEquals(TraktManualCheckInPolicy.RequestState.IN_FLIGHT, request)
        assertNull(TraktManualCheckInPolicy.begin(request!!, owner))
        val anotherAction = owner.copy(titleId = "tt7654321")
        assertNull(TraktManualCheckInPolicy.begin(TraktManualCheckInPolicy.RequestState.IDLE, anotherAction))
        for (outcome in listOf(TraktManualCheckInPolicy.RequestState.SUCCESS,
                TraktManualCheckInPolicy.RequestState.CONFLICT, TraktManualCheckInPolicy.RequestState.FAILURE)) {
            assertEquals(outcome, TraktManualCheckInPolicy.completion(owner, owner, outcome))
        }
        TraktManualCheckInPolicy.finish(owner)
        assertEquals(TraktManualCheckInPolicy.RequestState.IN_FLIGHT,
            TraktManualCheckInPolicy.begin(TraktManualCheckInPolicy.RequestState.IDLE, anotherAction))
        TraktManualCheckInPolicy.finish(anotherAction)
        assertTrue(TraktManualCheckInPolicy.canOffer(true, true, true, true,
            TraktManualCheckInPolicy.target(movie, null)))
    }
}
