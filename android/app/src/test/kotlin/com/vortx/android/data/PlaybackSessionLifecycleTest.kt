package com.vortx.android.data

import com.vortx.android.model.PlaybackContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlaybackSessionLifecycleTest {
    @Test
    fun `outgoing end completes before replacement begin`() = runTest {
        val events = mutableListOf<String>()
        val allowEnd = CompletableDeferred<Unit>()
        var generation = 0L
        val lifecycle = PlaybackSessionLifecycle(
            scope = this,
            beginSession = { _, _ ->
                val token = PlaybackSessionToken(++generation)
                events += "begin-${token.generation}"
                token
            },
            reportSession = { _, _, _ -> },
            endSession = { token, _, _ ->
                events += "end-${token.generation}-start"
                allowEnd.await()
                events += "end-${token.generation}-finish"
            },
        )
        val first = lifecycle.newHandle()
        lifecycle.begin(first)
        runCurrent()

        lifecycle.end(first, 1_000L, 10_000L)
        val second = lifecycle.newHandle()
        lifecycle.begin(second)
        runCurrent()
        assertEquals(listOf("begin-1", "end-1-start"), events)

        allowEnd.complete(Unit)
        advanceUntilIdle()
        assertEquals(listOf("begin-1", "end-1-start", "end-1-finish", "begin-2"), events)
    }

    @Test
    fun `local context is captured once and later shell changes cannot retarget the session`() = runTest {
        val received = mutableListOf<PlaybackContext?>()
        var generation = 0L
        val lifecycle = PlaybackSessionLifecycle(
            scope = this,
            beginSession = { context, _ ->
                received += context
                PlaybackSessionToken(++generation)
            },
            reportSession = { _, _, _ -> },
            endSession = { _, _, _ -> },
        )

        val streamedHandle = lifecycle.newHandle()
        lifecycle.begin(streamedHandle)
        runCurrent()

        val localContext = localPlaybackContext("imdb:tt0108778")
        val localHandle = lifecycle.newHandle()
        lifecycle.begin(localHandle, localContext)
        runCurrent()
        assertSame(localContext, received.last())

        // While the local session is live, the resident world moves on: progress + end flow through
        // the token alone (no context re-read), and a LATER play binds its own fresh context instead
        // of touching the running session's identity.
        lifecycle.report(localHandle, 40_000L, 100_000L)
        lifecycle.end(localHandle, 95_000L, 100_000L)

        val nextContext = localPlaybackContext("imdb:tt0114369")
        val nextHandle = lifecycle.newHandle()
        lifecycle.begin(nextHandle, nextContext)
        advanceUntilIdle()

        assertEquals(3, received.size)
        assertNull("streaming begin passes a null context", received.first())
        assertSame(localContext, received[1])
        assertSame(nextContext, received[2])
    }

    @Test
    fun `owner token is captured once alongside context and later begins cannot retarget it`() = runTest {
        val received = mutableListOf<Pair<PlaybackContext?, ContinueWatchingOwner?>>()
        var generation = 0L
        val lifecycle = PlaybackSessionLifecycle(
            scope = this,
            beginSession = { context, ownerToken ->
                received += context to ownerToken
                PlaybackSessionToken(++generation)
            },
            reportSession = { _, _, _ -> },
            endSession = { _, _, _ -> },
        )

        val localToken = fixedOwner(revision = 1L)
        val localHandle = lifecycle.newHandle()
        lifecycle.begin(localHandle, localPlaybackContext("imdb:tt0108778"), localToken)
        runCurrent()

        // While the session is live, progress/end carry only the bound token; a replacement play then
        // binds its OWN fresh token instead of touching the running session's identity.
        lifecycle.report(localHandle, 40_000L, 100_000L)
        lifecycle.end(localHandle, 95_000L, 100_000L)
        val nextToken = fixedOwner(revision = 2L)
        lifecycle.begin(lifecycle.newHandle(), null, nextToken)
        advanceUntilIdle()

        assertEquals(2, received.size)
        assertEquals(localPlaybackContext("imdb:tt0108778"), received.first().first)
        assertEquals(localToken, received.first().second)
        assertEquals(null, received.last().first)
        assertEquals(nextToken, received.last().second)
    }

    private fun fixedOwner(revision: Long): ContinueWatchingOwner = ContinueWatchingOwner(
        profileId = "owner-profile",
        accountSlot = "primary",
        principal = "principal-a",
        usesEngineHistory = true,
        revision = revision,
    )

    private fun localPlaybackContext(contentId: String): PlaybackContext = PlaybackContext(
        owner = PlaybackContext.Owner("owner-profile", usesEngineHistory = true),
        contentId = contentId,
        videoId = contentId,
        type = "movie",
        season = null,
        episode = null,
        title = "Local Title",
        poster = null,
        provenance = PlaybackContext.Provenance(
            sourceName = null,
            qualityText = null,
            torrentFetched = false,
            debridOwnerIdentity = null,
            debridOwnerGeneration = null,
        ),
    )
}
