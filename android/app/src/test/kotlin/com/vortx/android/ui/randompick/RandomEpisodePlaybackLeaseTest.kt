package com.vortx.android.ui.randompick

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class RandomEpisodePlaybackLeaseTest {
    private val now = Instant.parse("2026-10-24T12:00:00Z")
    private val episode = Episode("tt123:1:2", "Aired episode", 1, 2, released = "2020-01-01T00:00:00Z")
    private val detail = MetaDetail("tt123", MediaType.SERIES, "Series", videos = listOf(episode))
    private val request = Any()
    private val owner = Owner("profile", "principal", 3, false, "pin-v1", false)
    private val lease = RandomEpisodePlaybackLease(owner, detail.id, detail.type, episode, request)

    @Test fun completeOwnerAndExactRequestAreRequired() {
        assertTrue(accepts())
        assertFalse(accepts(currentOwner = owner.copy(principal = "different")))
        assertFalse(accepts(currentOwner = owner.copy(revision = 4)))
        assertFalse(accepts(currentOwner = owner.copy(kids = true)))
        assertFalse(accepts(currentOwner = owner.copy(pin = "pin-v2")))
        assertFalse(accepts(currentOwner = owner.copy(locked = true)))
        assertFalse(accepts(currentOwner = null))
        assertFalse(accepts(currentRequest = Any()))
        assertFalse(accepts(selected = "tt123:1:1"))
    }

    @Test fun changedInventoryCannotReusePreviewIdentity() {
        assertFalse(accepts(currentDetail = detail.copy(id = "tt999")))
        assertFalse(accepts(currentDetail = detail.copy(type = MediaType.MOVIE)))
        assertFalse(accepts(currentDetail = detail.copy(videos = emptyList())))
        assertFalse(accepts(currentDetail = detail.copy(videos = listOf(episode.copy(episode = 9)))))
    }

    @Test fun unknownReleaseRemainsEligibleAndKnownFutureIsRejectedBeforePlay() {
        assertTrue(accepts(currentDetail = detail.copy(videos = listOf(episode.copy(released = null)))))
        assertTrue(accepts(currentDetail = detail.copy(videos = listOf(episode.copy(released = "unparseable")))))
        assertFalse(accepts(currentDetail = detail.copy(videos = listOf(episode.copy(released = "2027-01-01T00:00:00Z")))))
    }

    private fun accepts(
        currentOwner: Owner? = owner,
        currentRequest: Any? = request,
        selected: String? = episode.id,
        currentDetail: MetaDetail? = detail,
    ): Boolean = lease.accepts(currentOwner, currentRequest, selected, currentDetail, now)

    private data class Owner(
        val profile: String,
        val principal: String,
        val revision: Int,
        val kids: Boolean,
        val pin: String,
        val locked: Boolean,
    )
}
