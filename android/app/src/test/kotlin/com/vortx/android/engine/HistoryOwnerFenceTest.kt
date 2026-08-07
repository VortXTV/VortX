package com.vortx.android.engine

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.PlaybackSessionToken
import com.vortx.android.profile.ContinueWatchingOwnerGate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class HistoryOwnerFenceTest {
    @Test
    fun `playback session refuses progress after profile owner revision changes`() {
        val state = OwnerState()
        val fence = state.fence()
        val permit = requireNotNull(fence.captureRead())
        val session = PlaybackHistorySession(
            token = PlaybackSessionToken(1L),
            owner = permit.owner,
            enginePlayerLoaded = false,
            type = "series",
            videoId = "tt1:1:1",
            overlayMetaId = "tt1",
            name = "Title",
            poster = null,
        )
        var wroteProgress = false

        ContinueWatchingOwnerGate.transition(capture = { Unit }) {
            state.profileId = "profile-b"
            state.accountSlot = "primary.profile-b"
        }

        assertThrows(IllegalStateException::class.java) {
            fence.mutate(expectedOwner = session.owner) { wroteProgress = true }
        }
        assertFalse(wroteProgress)
    }

    @Test
    fun `delayed progress from replaced session cannot write into replacement`() {
        val sessions = PlaybackHistorySessions()
        val owner = owner("profile-a")
        val tokenA = sessions.replace(unloadPrevious = {}) { token -> session(token, owner, "episode-a") }
        val callbackWaiting = CountDownLatch(1)
        val releaseCallback = CountDownLatch(1)
        val wrote = AtomicBoolean(false)
        val accepted = AtomicBoolean(true)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val delayed = executor.submit {
                callbackWaiting.countDown()
                assertTrue(releaseCallback.await(2, TimeUnit.SECONDS))
                accepted.set(sessions.withCurrent(tokenA) { wrote.set(true) })
            }
            assertTrue(callbackWaiting.await(1, TimeUnit.SECONDS))

            val tokenB = sessions.replace(unloadPrevious = {}) { token -> session(token, owner, "episode-b") }
            releaseCallback.countDown()
            delayed.get(1, TimeUnit.SECONDS)

            assertFalse(accepted.get())
            assertFalse(wrote.get())
            assertTrue(sessions.withCurrent(tokenB) { active ->
                assertEquals("episode-b", active.videoId)
            })
        } finally {
            releaseCallback.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `delayed end from replaced session cannot unload replacement`() {
        val sessions = PlaybackHistorySessions()
        val owner = owner("profile-a")
        val unloaded = mutableListOf<String?>()
        val tokenA = sessions.replace(unloadPrevious = { unloaded += it.videoId }) { token ->
            session(token, owner, "episode-a", enginePlayerLoaded = true)
        }
        val callbackWaiting = CountDownLatch(1)
        val releaseCallback = CountDownLatch(1)
        val staleEndAccepted = AtomicBoolean(true)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val delayed = executor.submit {
                callbackWaiting.countDown()
                assertTrue(releaseCallback.await(2, TimeUnit.SECONDS))
                staleEndAccepted.set(
                    sessions.finish(tokenA) { stale ->
                        if (stale.enginePlayerLoaded) unloaded += stale.videoId
                    },
                )
            }
            assertTrue(callbackWaiting.await(1, TimeUnit.SECONDS))

            val tokenB = sessions.replace(unloadPrevious = { unloaded += it.videoId }) { token ->
                session(token, owner, "episode-b", enginePlayerLoaded = true)
            }
            releaseCallback.countDown()
            delayed.get(1, TimeUnit.SECONDS)

            assertFalse(staleEndAccepted.get())
            assertEquals(listOf("episode-a"), unloaded)
            assertTrue(sessions.withCurrent(tokenB) { active ->
                assertEquals("episode-b", active.videoId)
            })
            assertTrue(sessions.finish(tokenB) { current ->
                if (current.enginePlayerLoaded) unloaded += current.videoId
            })
            assertEquals(listOf("episode-a", "episode-b"), unloaded)
        } finally {
            releaseCallback.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `profile switch cannot enter between mutation route selection and final validation`() {
        val state = OwnerState()
        val fence = state.fence()
        val mutationEntered = CountDownLatch(1)
        val releaseMutation = CountDownLatch(1)
        val switchAttempted = CountDownLatch(1)
        val switchEntered = AtomicBoolean(false)
        val writtenProfile = AtomicReference<String>()
        val executor = Executors.newFixedThreadPool(2)
        try {
            val mutation = executor.submit {
                fence.mutate { owner ->
                    mutationEntered.countDown()
                    assertTrue(releaseMutation.await(2, TimeUnit.SECONDS))
                    writtenProfile.set(owner.profileId)
                }
            }
            assertTrue(mutationEntered.await(1, TimeUnit.SECONDS))
            val switching = executor.submit {
                switchAttempted.countDown()
                ContinueWatchingOwnerGate.transition(capture = { Unit }) {
                    switchEntered.set(true)
                    state.profileId = "profile-b"
                    state.accountSlot = "primary.profile-b"
                }
            }
            assertTrue(switchAttempted.await(1, TimeUnit.SECONDS))
            assertFalse(switchEntered.get())

            releaseMutation.countDown()
            mutation.get(1, TimeUnit.SECONDS)
            switching.get(1, TimeUnit.SECONDS)
            assertEquals("profile-a", writtenProfile.get())
            assertTrue(switchEntered.get())
        } finally {
            releaseMutation.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `library read drops rows when profile switches before post read validation`() {
        val state = OwnerState()
        val fence = state.fence()
        val permit = requireNotNull(fence.captureRead())
        val readStarted = CountDownLatch(1)
        val allowValidation = CountDownLatch(1)
        val exposed = AtomicReference<List<String>>(emptyList())
        val executor = Executors.newFixedThreadPool(2)
        try {
            val read = executor.submit {
                val rows = listOf("private-row")
                readStarted.countDown()
                assertTrue(allowValidation.await(2, TimeUnit.SECONDS))
                exposed.set(if (fence.readIsCurrent(permit)) rows else emptyList())
            }
            assertTrue(readStarted.await(1, TimeUnit.SECONDS))
            val switching = executor.submit {
                ContinueWatchingOwnerGate.transition(capture = { Unit }) {
                    state.profileId = "profile-b"
                    state.accountSlot = "primary.profile-b"
                }
                allowValidation.countDown()
            }

            switching.get(1, TimeUnit.SECONDS)
            read.get(1, TimeUnit.SECONDS)
            assertTrue(exposed.get().isEmpty())
        } finally {
            allowValidation.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `library read drops rows when native principal changes without a profile mutation`() {
        val state = OwnerState(usesEngineHistory = true, principal = "account-a")
        val fence = state.fence()
        val permit = requireNotNull(fence.captureRead())

        state.principal = "account-b"

        assertFalse(fence.readIsCurrent(permit))
    }

    @Test
    fun `overlay read uses one captured profile and drops snapshot after concurrent switch`() {
        data class OverlayRow(val resumeMs: Long, val watchedIds: Set<String>)
        data class OverlaySnapshot(val profileId: String, val resumeMs: Long, val watchedIds: Set<String>)

        val state = OwnerState()
        val fence = state.fence()
        val overlays = mapOf(
            "profile-a" to OverlayRow(11_000L, setOf("a-episode")),
            "profile-b" to OverlayRow(22_000L, setOf("b-episode")),
        )
        val permit = requireNotNull(fence.captureRead())
        val overlayReadComplete = CountDownLatch(1)
        val allowValidation = CountDownLatch(1)
        val switchEntered = AtomicBoolean(false)
        val raw = AtomicReference<OverlaySnapshot>()
        val exposed = AtomicReference<OverlaySnapshot?>()
        val executor = Executors.newFixedThreadPool(2)
        try {
            val read = executor.submit {
                val snapshot = ContinueWatchingOwnerGate.serialized {
                    assertEquals(permit.owner.profileId, state.profileId)
                    val entry = overlays.getValue(permit.owner.profileId)
                    OverlaySnapshot(permit.owner.profileId, entry.resumeMs, entry.watchedIds)
                }
                raw.set(snapshot)
                overlayReadComplete.countDown()
                assertTrue(allowValidation.await(2, TimeUnit.SECONDS))
                exposed.set(snapshot.takeIf { fence.readIsCurrent(permit) })
            }
            assertTrue(overlayReadComplete.await(1, TimeUnit.SECONDS))
            val switching = executor.submit {
                ContinueWatchingOwnerGate.transition(capture = { Unit }) {
                    state.profileId = "profile-b"
                    state.accountSlot = "primary.profile-b"
                    switchEntered.set(true)
                }
                allowValidation.countDown()
            }

            switching.get(1, TimeUnit.SECONDS)
            read.get(1, TimeUnit.SECONDS)
            assertTrue(switchEntered.get())
            assertEquals(OverlaySnapshot("profile-a", 11_000L, setOf("a-episode")), raw.get())
            assertEquals(null, exposed.get())
        } finally {
            allowValidation.countDown()
            executor.shutdownNow()
        }
    }

    private fun owner(profileId: String): ContinueWatchingOwner = ContinueWatchingOwner(
        profileId = profileId,
        accountSlot = "primary.$profileId",
        principal = "account-a",
        usesEngineHistory = false,
        revision = 0L,
    )

    private fun session(
        token: PlaybackSessionToken,
        owner: ContinueWatchingOwner,
        videoId: String,
        enginePlayerLoaded: Boolean = false,
    ): PlaybackHistorySession = PlaybackHistorySession(
        token = token,
        owner = owner,
        enginePlayerLoaded = enginePlayerLoaded,
        type = "series",
        videoId = videoId,
        overlayMetaId = "tt1",
        name = "Title",
        poster = null,
    )

    private class OwnerState(
        @Volatile var profileId: String = "profile-a",
        @Volatile var accountSlot: String = "primary.profile-a",
        @Volatile var usesEngineHistory: Boolean = false,
        @Volatile var principal: String = "account-a",
    ) {
        fun fence(): HistoryOwnerFence = HistoryOwnerFence(
            captureOwner = { revision ->
                ContinueWatchingOwner(
                    profileId = profileId,
                    accountSlot = accountSlot,
                    principal = principal,
                    usesEngineHistory = usesEngineHistory,
                    revision = revision,
                )
            },
            ownerRouteMatches = { owner ->
                owner.profileId == profileId &&
                    owner.accountSlot == accountSlot &&
                    owner.usesEngineHistory == usesEngineHistory &&
                    owner.principal == principal
            },
            transitionInProgress = { false },
        )
    }
}
