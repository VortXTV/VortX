package com.vortx.android.ui.tv

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import org.junit.Assert.*
import org.junit.Test

class TvQuickViewPolicyTest {
    private val movie = MetaItem("tt123", MediaType.MOVIE, "Title")
    private val owner = ContinueWatchingOwner("profile", "account", "principal", true, 1)

    @Test fun `setting applies only to ordinary VOD catalog selections`() {
        assertTrue(tvCatalogOpensQuickView(movie, true))
        assertTrue(tvCatalogOpensQuickView(movie.copy(type = MediaType.SERIES), true))
        assertFalse(tvCatalogOpensQuickView(movie, false))
        assertFalse(tvCatalogOpensQuickView(movie.copy(type = MediaType.TV), true))
        assertFalse(tvCatalogOpensQuickView(movie.copy(type = MediaType.CHANNEL), true))
    }

    @Test fun `resume and remote episode admissions retain their direct route`() {
        val resumeIntents = listOf(
            movie.copy(progress = 0f), movie.copy(resumeSeconds = 0.0),
            movie.copy(preferredEpisode = PreferredEpisode(1, 2)),
            movie.copy(continueWatchingPermit = "opaque"),
            movie.copy(continueWatchingUnavailableMessage = "Unavailable"),
            movie.copy(continueWatchingActivityAtMillis = 1),
        )
        resumeIntents.forEach { assertFalse(it.toString(), tvCatalogOpensQuickView(it, true)) }
    }

    @Test fun `auto Watch must match typed title and every owner dimension`() {
        val selection = TvQuickViewSelection(movie, owner)
        assertTrue(tvQuickWatchMatchesDetail(selection, movie, owner))
        assertFalse(tvQuickWatchMatchesDetail(null, movie, owner))
        assertFalse(tvQuickWatchMatchesDetail(selection, movie.copy(id = "tt456"), owner))
        assertFalse(tvQuickWatchMatchesDetail(selection, movie.copy(type = MediaType.SERIES), owner))
        listOf(owner.copy(profileId = "other"), owner.copy(accountSlot = "other"),
            owner.copy(principal = "other"), owner.copy(revision = 2), owner.copy(usesEngineHistory = false)).forEach {
            assertFalse(tvQuickWatchMatchesDetail(selection, movie, it))
        }
    }
}
