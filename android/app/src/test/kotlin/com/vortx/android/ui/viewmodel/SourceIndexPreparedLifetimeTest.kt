package com.vortx.android.ui.viewmodel

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.SourcePreparation
import com.vortx.android.data.SourcePreparationAdoption
import com.vortx.android.data.StreamLoadUpdate
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.player.PlayerSourceSwitchCommitGate
import com.vortx.android.player.PlayerSourceSwitchResolution
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Source-only lifetime fixtures for the real prepared handoff and host acknowledgment path. */
class SourceIndexPreparedLifetimeTest {
    @Test fun rejectionBeforeAcknowledgmentRollsBackAndClosesIncomingWithoutPublicationCleanup() {
        val fixture = Preparation()
        val failure = IllegalStateException("Host rejected before publication")
        var producerRollbacks = 0
        val resolution = preparedEpisodeHandoff(fixture.prepared,
            commitGate = PlayerSourceSwitchCommitGate(), isCurrent = { true },
            install = {}, rollback = { producerRollbacks++ })

        val rejected = runCatching {
            resolution.commitIfCurrent(hostAuthorityIsCurrent = { true }) { throw failure }
        }
        assertSame(failure, rejected.exceptionOrNull())
        assertEquals(1, fixture.adoptions)
        assertEquals(1, fixture.adoptionRollbacks)
        assertEquals(1, producerRollbacks)
        assertEquals(0, fixture.publicationCleanups)
        assertEquals(1, fixture.incomingCloses)
        assertEquals(1, fixture.preparationCloses)
        resolution.discard()
        assertEquals(1, fixture.adoptionRollbacks)
        assertEquals(1, fixture.incomingCloses)
    }

    @Test fun hostFailureAfterAcknowledgmentCleansPreviousOnceAndLeavesIncomingMounted() {
        val fixture = Preparation()
        val failure = IllegalStateException("Host notification failed after publication")
        var producerRollbacks = 0
        val resolution = preparedEpisodeHandoff(fixture.prepared,
            commitGate = PlayerSourceSwitchCommitGate(), isCurrent = { true },
            install = {}, rollback = { producerRollbacks++ })

        val published = runCatching {
            resolution.commitIfCurrent(hostAuthorityIsCurrent = { true }) { acknowledge ->
                acknowledge()
                throw failure
            }
        }
        assertSame(failure, published.exceptionOrNull())
        assertEquals(1, fixture.adoptions)
        assertEquals(1, fixture.publicationCleanups)
        assertEquals(0, fixture.adoptionRollbacks)
        assertEquals(0, producerRollbacks)
        assertEquals(0, fixture.preparationCloses)
        assertEquals(0, fixture.incomingCloses)
        resolution.discard()
        assertEquals(0, fixture.incomingCloses)
        assertFalse(resolution.commitIfCurrent { true })
        assertEquals(1, fixture.publicationCleanups)
        // Only the mounted host's eventual teardown closes the acknowledged incoming lease.
        resolution.playable.playbackLease?.close()
        assertEquals(1, fixture.incomingCloses)
    }

    @Test fun duplicateAndReentrantAcknowledgmentPublishesOnceOutsideOwnershipLockDespiteCleanupFailure() {
        val fixture = Preparation()
        val cleanupFailure = IllegalStateException("Previous pool cleanup failed")
        val observerFinished = CountDownLatch(1)
        var observedOwnershipLockReleased = false
        var reentrantAccepted = true
        var observer: Thread? = null
        lateinit var resolution: PlayerSourceSwitchResolution
        fixture.afterPublished = {
            // discard() must enter the resolution's private ownership lock. Completion before this
            // callback returns proves cleanup runs outside that lock, without inspecting private fields.
            observer = Thread {
                resolution.discard()
                observerFinished.countDown()
            }.apply { isDaemon = true; start() }
            observedOwnershipLockReleased = observerFinished.await(2, TimeUnit.SECONDS)
            throw cleanupFailure
        }
        resolution = preparedEpisodeHandoff(fixture.prepared,
            commitGate = PlayerSourceSwitchCommitGate(), isCurrent = { true },
            install = {}, rollback = {})

        val published = try {
            runCatching {
                resolution.commitIfCurrent(hostAuthorityIsCurrent = { true }) { acknowledge ->
                    acknowledge()
                    acknowledge()
                    resolution.discard()
                    reentrantAccepted = resolution.commitIfCurrent { true }
                }
            }
        } finally {
            observer?.join(2_000)
        }
        assertTrue(published.getOrThrow())
        assertTrue(observedOwnershipLockReleased)
        assertFalse(observer?.isAlive == true)
        assertFalse(reentrantAccepted)
        assertEquals(1, fixture.publicationCleanups)
        assertEquals(0, fixture.adoptionRollbacks)
        assertEquals(0, fixture.incomingCloses)
        assertEquals(0, fixture.preparationCloses)
        resolution.discard()
        assertFalse(resolution.commitIfCurrent { true })
        assertEquals(1, fixture.publicationCleanups)
        resolution.playable.playbackLease?.close()
        assertEquals(1, fixture.incomingCloses)
    }

    private class Preparation : SourcePreparation {
        override val owner = ContinueWatchingOwner("profile", "account", "principal", true, 1)
        override val sourcePublicationId = "prepared-context"
        val source = StreamSource("ordinary-prepared", "Configured add-on", "Prepared ordinary source",
            url = "https://fixture.invalid/prepared")
        override val groups = listOf(StreamGroup("Configured add-on", listOf(source)))
        var adoptions = 0
        var adoptionRollbacks = 0
        var publicationCleanups = 0
        var incomingCloses = 0
        var preparationCloses = 0
        var afterPublished: () -> Unit = {}
        val prepared = PreparedEpisode("episode-2", source,
            Playable("https://fixture.invalid/prepared", "Prepared ordinary source",
                playbackLease = AutoCloseable { incomingCloses++ }), this)

        override fun isCurrent() = true
        override fun updates(): Flow<StreamLoadUpdate> = flowOf(StreamLoadUpdate(groups, 1, 1,
            terminal = true, sourcePublicationId = sourcePublicationId))
        override suspend fun resolve(source: StreamSource): Result<Playable> =
            Result.failure(IllegalStateException("No resolver is needed for this lifetime fixture"))
        override fun adopt(): SourcePreparationAdoption? {
            if (adoptions != 0) return null
            adoptions++
            return object : SourcePreparationAdoption {
                override val groups = this@Preparation.groups
                override val sourcePublicationId = this@Preparation.sourcePublicationId
                override fun rollback() { adoptionRollbacks++ }
                override fun commitPublished() { publicationCleanups++; afterPublished() }
            }
        }
        override fun close() { preparationCloses++ }
    }
}
