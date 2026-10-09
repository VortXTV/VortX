package com.vortx.android.ui.components

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class PosterMenuPolicyTest {
    private val movie = MetaItem("tt123", MediaType.MOVIE, "Movie")
    @Test fun `ordinary TV catalog cards have catalog quick actions while CW keeps its menu`() {
        assertEquals(PosterCardMenu.CATALOG, cinemaPosterMenu(movie, false))
        assertEquals(PosterCardMenu.CONTINUE_WATCHING, cinemaPosterMenu(movie, true))
    }
    @Test fun `remote or misplaced CW cards never gain catalog mutations`() {
        assertEquals(PosterCardMenu.NONE, cinemaPosterMenu(movie.copy(continueWatchingPermit = "lease"), false))
        assertEquals(PosterCardMenu.NONE, cinemaPosterMenu(movie.copy(continueWatchingUnavailableMessage = "Unavailable"), false))
        assertTrue(posterCatalogActions(movie.copy(continueWatchingPermit = "lease"), true, true, true).isEmpty())
    }
    @Test fun `unavailable callbacks and live media actions remain absent`() {
        assertTrue(posterCatalogActions(movie, false, false, false).isEmpty())
        assertTrue(posterCatalogActions(movie.copy(type = MediaType.CHANNEL), true, true, true).isEmpty())
        assertEquals(listOf(PosterCatalogAction.MARK_WATCHED, PosterCatalogAction.MARK_UNWATCHED), posterCatalogActions(movie, false, false, true))
    }
    @Test fun `watchlist requires actual supported typed identity rather than a dead callback`() {
        assertEquals(listOf(PosterCatalogAction.WATCHLIST), posterCatalogActions(movie, false, true, false))
        assertTrue(posterCatalogActions(movie.copy(id = "simkl:movie:123"), false, true, false).isEmpty())
        assertTrue(posterCatalogActions(movie.copy(id = "tt123/unsafe"), false, true, false).isEmpty())
    }
    @Test fun `action captures event authority before delayed executor instead of recapturing`() = runBlocking {
        var owner = "A"
        var executed: String? = null
        val action = capturePosterAction({ owner }) { captured -> executed = captured }
        owner = "B"
        assertNull(executed)
        action()
        assertEquals("A", executed)
    }
    @Test fun `failed acknowledgement remains failure and never fabricates success`() = runBlocking {
        val action = capturePosterAction({ "A" }) { _: String -> error("Checkpoint rejected") }
        assertTrue(runCatching { action() }.isFailure)
    }
}
