package com.vortx.android.ui.viewmodel

import com.vortx.android.sources.SourceRequestFence
import java.io.File
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

    @Test
    fun `trailer resolver publishes only through its own playback lease`() {
        val trailer = resolverBody("fun playTrailer()", "/// The hero Watch/Resume action")

        assertResolverUsesItsOwnLease(trailer, expectedPublicationCount = 1)
    }

    @Test
    fun `best source resolver publishes only through its own playback lease`() {
        val best = resolverBody(
            "private fun playBest(fromStart: Boolean, startPositionOverrideMs: Long?)",
            "/// Race the account-confirmed-cached",
        )

        assertResolverUsesItsOwnLease(best, expectedPublicationCount = 6)
    }

    @Test
    fun `best source resolver rejects a publication through a different lease`() {
        val best = resolverBody(
            "private fun playBest(fromStart: Boolean, startPositionOverrideMs: Long?)",
            "/// Race the account-confirmed-cached",
        )
        val oneDifferentLease = best.replaceFirst(
            "publishPlaybackResolve(resolveLease",
            "publishPlaybackResolve(differentLease",
        )

        assertFalse(publicationsUseExactLease(oneDifferentLease, expectedPublicationCount = 6))
    }

    private fun assertResolverUsesItsOwnLease(body: String, expectedPublicationCount: Int) {
        val cancel = body.indexOf("playbackResolveJob?.cancel()")
        val begin = body.indexOf("val resolveLease = playbackResolveFence.begin(request)")
        val launch = body.indexOf("playbackResolveJob = viewModelScope.launch")
        val publisher = detailViewModelSource()
            .substringAfter("private fun publishPlaybackResolve(lease: PlaybackResolveFence.Lease, state: Playback): Boolean")
            .substringBefore("/// Re-find sources")
        val publicationGuard = publisher.indexOf("if (!canPublishPlaybackResolve(lease)) return false")
        val publication = publisher.indexOf("_playback.value = state")
        val finish = publisher.indexOf("playbackResolveFence.finish(lease)")

        assertTrue("The prior resolver must be cancelled before replacing its lease", cancel >= 0)
        assertTrue("Every resolver must capture a new lease", begin > cancel)
        assertTrue("The resolver coroutine must close over its captured lease", launch > begin)
        assertTrue(
            "Every Ready or Failed result must publish through the resolver's exact lease",
            publicationsUseExactLease(body, expectedPublicationCount),
        )
        assertFalse("Resolver bodies may not bypass the lease for Ready", body.contains("_playback.value = Playback.Ready"))
        assertFalse("Resolver bodies may not bypass the lease for Failed", body.contains("_playback.value = Playback.Failed"))
        assertTrue("Publication must first validate its exact lease", publicationGuard >= 0)
        assertTrue("Publication must mutate only after that exact lease validates", publication > publicationGuard)
        assertTrue("Publication must finish that same lease after mutation", finish > publication)
    }

    private fun publicationsUseExactLease(body: String, expectedPublicationCount: Int): Boolean {
        val publicationLeases = Regex("publishPlaybackResolve\\(\\s*([^,]+)\\s*,")
            .findAll(body)
            .map { it.groupValues[1].trim() }
            .toList()
        return publicationLeases.size == expectedPublicationCount && publicationLeases.all { it == "resolveLease" }
    }

    private fun resolverBody(start: String, end: String): String =
        detailViewModelSource().substringAfter(start).substringBefore(end)

    private fun detailViewModelSource(): String {
        val relativePath = "src/main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt"
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
