package com.vortx.android.ui.viewmodel

import com.vortx.android.sources.SourceRequestFence
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackResolveFenceTest {
    @Test
    fun `play then re-find revokes old resolver before refreshed source generation begins`() {
        val sources = SourceRequestFence("profile-a")
        val resolving = sources.begin("profile-a", "episode-10")
        val playback = PlaybackResolveFence()
        val resolveLease = playback.begin(resolving)

        assertTrue(playback.invalidateForSourceRequest(resolving))
        val refreshed = sources.beginRefresh("profile-a", "episode-10")!!

        assertFalse("The stale pre-refresh resolver cannot publish Ready after it returns", playback.accepts(resolveLease))
        assertFalse("The resolver belongs to the old generation", sources.accepts(resolving, "profile-a"))
        assertFalse(playback.invalidateForSourceRequest(refreshed))
    }

    @Test
    fun `play then episode switch revokes episode A resolver before episode B begins`() {
        val sources = SourceRequestFence("profile-a")
        val episodeA = sources.begin("profile-a", "episode-10")
        val playback = PlaybackResolveFence()
        val episodeALease = playback.begin(episodeA)

        assertTrue(playback.invalidateForSourceRequest(episodeA))
        val episodeB = sources.begin("profile-a", "episode-11")

        assertFalse("A late episode A completion must not replace the new target", playback.accepts(episodeALease))
        assertTrue("Episode B owns the current source request", sources.accepts(episodeB, "profile-a"))
        assertFalse("No resolver is accidentally granted episode B authority", playback.invalidateForSourceRequest(episodeB))
    }

    @Test
    fun `abandoned resolve result has no publication authority`() {
        val sources = SourceRequestFence("profile-a")
        val request = sources.begin("profile-a", "episode-10")
        val playback = PlaybackResolveFence()
        val resolveLease = playback.begin(request)
        val delayedResult = Result.success("resolved-url")

        assertTrue(playback.invalidateForSourceRequest(request))
        val mayPublish = delayedResult.isSuccess && playback.accepts(resolveLease)

        assertFalse("A cancelled resolver result must not reopen the player", mayPublish)
    }

    @Test
    fun `same source token does not reauthorize an abandoned attempt`() {
        val sources = SourceRequestFence("profile-a")
        val request = sources.begin("profile-a", "episode-10")
        val playback = PlaybackResolveFence()
        val attemptA = playback.begin(request)

        assertTrue(playback.invalidateForSourceRequest(request))
        val attemptB = playback.begin(request)

        assertFalse("Attempt A stays revoked after attempt B starts on the same source token", playback.accepts(attemptA))
        assertTrue("Attempt B alone owns publication", playback.accepts(attemptB))
        playback.finish(attemptA)
        assertTrue("Finishing stale A cannot revoke active B", playback.accepts(attemptB))
        playback.finish(attemptB)
        assertFalse("A completed active attempt releases its own authority", playback.accepts(attemptB))
    }
}
