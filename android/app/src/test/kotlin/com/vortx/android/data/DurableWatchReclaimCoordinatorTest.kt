package com.vortx.android.data

import com.vortx.android.downloads.WatchedDownloadReclaimRequest
import com.vortx.android.model.PlaybackContext
import org.junit.Assert.assertEquals
import org.junit.Test

class DurableWatchReclaimCoordinatorTest {
    @Test
    fun `reclaims when durable watch arrives before released resources`() {
        val fixture = Fixture()
        fixture.coordinator.onDurableWatch(fixture.receipt)
        assertEquals(0, fixture.reclaims)

        fixture.coordinator.onResourcesReleased()
        assertEquals(1, fixture.reclaims)
    }

    @Test
    fun `reclaims when released resources arrive before durable watch`() {
        val fixture = Fixture()
        fixture.coordinator.onResourcesReleased()
        assertEquals(0, fixture.reclaims)

        fixture.coordinator.onDurableWatch(fixture.receipt)
        assertEquals(1, fixture.reclaims)
    }

    @Test
    fun `mismatched context owner and absent receipt never reclaim`() {
        val fixture = Fixture()
        fixture.coordinator.onResourcesReleased()
        fixture.coordinator.onDurableWatch(fixture.receipt.copy(context = fixture.context.copy(videoId = "other")))
        fixture.coordinator.onDurableWatch(fixture.receipt.copy(owner = fixture.owner.copy(revision = 2L)))
        // A failed commit creates no receipt at all; resource release by itself remains harmless.
        assertEquals(0, fixture.reclaims)
    }

    @Test
    fun `profile change explicit unwatch and off toggle each fail closed at flush`() {
        val profileChanged = Fixture()
        profileChanged.ownerCurrent = false
        profileChanged.coordinator.onDurableWatch(profileChanged.receipt)
        profileChanged.coordinator.onResourcesReleased()
        assertEquals(0, profileChanged.reclaims)

        val unwatched = Fixture()
        unwatched.exactWatch = false
        unwatched.coordinator.onResourcesReleased()
        unwatched.coordinator.onDurableWatch(unwatched.receipt)
        assertEquals(0, unwatched.reclaims)

        val disabled = Fixture()
        disabled.enabled = false
        disabled.coordinator.onDurableWatch(disabled.receipt)
        disabled.coordinator.onResourcesReleased()
        assertEquals(0, disabled.reclaims)
    }

    @Test
    fun `resource gate ignores destroy dispose races and waits for every decoder and lease`() {
        var released = 0
        val gate = PlayerResourceReleaseGate { released += 1 }
        gate.decoderBound()
        gate.leaseBound()

        // Destroy can release a decoder before composition disposes; that alone cannot reclaim bytes.
        gate.decoderReleased()
        gate.sessionDisposed()
        assertEquals(0, released)
        gate.leaseReleased()
        assertEquals(1, released)

        // The duplicate dispose/destroy calls and a stale release cannot fire a second cleanup.
        gate.decoderReleased()
        gate.leaseReleased()
        gate.sessionDisposed()
        assertEquals(1, released)
    }

    private class Fixture {
        val context = PlaybackContext(
            owner = PlaybackContext.Owner("overlay", usesEngineHistory = false),
            contentId = "imdb:tt0108778",
            videoId = "imdb:tt0108778:3:1",
            type = "series",
            season = 3,
            episode = 1,
            title = "Friends",
            poster = "poster",
            provenance = PlaybackContext.Provenance("offline", "1080p", false, null, null),
        )
        val owner = ContinueWatchingOwner("overlay", "primary", "principal", false, 1L)
        val request = WatchedDownloadReclaimRequest.from(context, "file:///offline/friends-s3e1.mp4")
        val receipt = DurableWatchedPlaybackReceipt(context, owner)
        var ownerCurrent = true
        var exactWatch = true
        var enabled = true
        var reclaims = 0
        val coordinator = DurableWatchReclaimCoordinator(
            request = request,
            capturedOwner = owner,
            verifyAndReclaim = { _, _ ->
                if (!ownerCurrent || !exactWatch || !enabled) false else {
                    reclaims += 1
                    true
                }
            },
        )
    }
}
