package com.vortx.android.ui.viewmodel

import com.vortx.android.debrid.DebridOwnerScope
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.Episode
import com.vortx.android.data.*
import com.vortx.android.player.*
import com.vortx.android.sources.SourceRequestFence
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PreparedEpisodeSlotTest {
    private class Preparation : SourcePreparation {
        override val owner = ContinueWatchingOwner("native", "account", "profile", true, 1)
        val source = StreamSource("source", "Fixture", "Prepared", url = "https://fixture.invalid/video")
        override val groups = listOf(StreamGroup("Fixture", listOf(source)))
        var fetches = 0
        var resolves = 0
        var closes = 0
        var leaseCloses = 0
        var adoptions = 0
        var rollbacks = 0
        var current = true
        var adopted = false
        var resolveAction: suspend () -> Playable = {
            Playable("https://fixture.invalid/video", "Prepared", startPositionMs = 999,
                playbackLease = AutoCloseable { leaseCloses++ })
        }
        override fun isCurrent() = current
        override fun updates(): Flow<StreamLoadUpdate> = flow {
            fetches++
            emit(StreamLoadUpdate(groups, 1, 1, terminal = true))
        }
        override suspend fun resolve(source: StreamSource): Result<Playable> {
            resolves++
            return Result.success(resolveAction())
        }
        override fun adopt(): SourcePreparationAdoption? {
            if (!current || adopted) return null
            adopted = true; adoptions++
            return object : SourcePreparationAdoption {
                override val groups = this@Preparation.groups
                override fun rollback() { rollbacks++; current = false }
            }
        }
        override fun close() { if (!adopted && current) { current = false; closes++ } }
    }

    @Test fun automaticAndManualPreparedHandoffsConsumeOnceWithoutNewProviderOrResolverCalls() = runBlocking {
        for (automatic in listOf(false, true)) {
            val slot = PreparedEpisodeSlot<Long>({ it == 1L })
            val preparation = Preparation()
            val ticket = slot.begin(1L)
            assertTrue(slot.prepare(ticket, "episode-2", preparation, { it.first().streams.first() }))
            val claim = requireNotNull(slot.claim("episode-2"))
            assertNull(slot.claim("episode-2"))
            var installedGroups = emptyList<StreamGroup>()
            var history = 0
            var outgoingCloses = 0
            val coordinator = PlayerSourceSwitchCoordinator()
            val outer = coordinator.replaceOuterSession()
            val pendingState = beginPlayerEpisodeSwitch(PlayerSourceSwitchState(outer,
                Playable("https://fixture.invalid/old", "Old", playbackLease = AutoCloseable { outgoingCloses++ }), null),
                Episode("episode-2", "Second", 1, 2), requireNotNull(coordinator.beginRequest(outer)))
            var host = pendingState
            val resolution = preparedEpisodeHandoff(claim.episode, commitGate = PlayerSourceSwitchCommitGate(),
                isCurrent = { slot.accepts(ticket) }, install = { installedGroups = it }, rollback = {})
            resolveAndApplyPlayerEpisodeSwitch(coordinator, requireNotNull(host.pendingEpisodeSwitch),
                resolver = { Result.success(resolution) }, currentState = { host }, publishState = { accepted, acknowledge ->
                    assertEquals("Outgoing intact for automatic=$automatic", 0, outgoingCloses)
                    host = accepted
                    acknowledge()
                    history++
                })
            assertEquals(1L, host.revision)
            assertEquals(0L, host.playable.startPositionMs)
            assertEquals(1, history)
            assertEquals(preparation.groups, installedGroups)
            assertEquals(1, preparation.fetches)
            assertEquals(1, preparation.resolves)
            assertEquals(1, preparation.adoptions)
            slot.invalidate(); preparation.close(); resolution.discard()
            assertEquals(0, preparation.leaseCloses)
            host.playable.playbackLease!!.close()
            assertEquals(1, preparation.leaseCloses)
        }
    }

    @Test fun rejectedPreparedHandoffRetainsOutgoingAndClosesItsOwnLeaseOnce() = runBlocking {
        val slot = PreparedEpisodeSlot<Long>({ it == 1L })
        val preparation = Preparation()
        val ticket = slot.begin(1L)
        slot.prepare(ticket, "episode-2", preparation, { it.first().streams.first() })
        val claim = requireNotNull(slot.claim("episode-2"))
        val gate = PlayerSourceSwitchCommitGate().also { it.invalidate() }
        var installs = 0
        val resolution = preparedEpisodeHandoff(claim.episode, commitGate = gate, isCurrent = { slot.accepts(ticket) },
            install = { installs++ }, rollback = {})
        assertFalse(resolution.commitIfCurrent { true })
        resolution.discard(); claim.episode.close(); slot.invalidate()
        assertEquals(0, installs)
        assertEquals(0, preparation.adoptions)
        assertEquals(1, preparation.leaseCloses)
        assertEquals(1, preparation.closes)
    }

    @Test fun ownerSourceAudioAndCredentialABARejectLatePreparedPublication() = runBlocking {
        for (dimension in listOf("owner", "profile", "source", "audio", "credential", "debrid", "generation")) {
            val fence = SourceRequestFence("profile-a")
            val initial = PreparedEpisodeAuthority("episode-2", "profile-a",
                ContinueWatchingOwner("profile-a", "account-a", "principal-a", true, 1),
                fence.begin("profile-a", "episode-1"), 1,
                DebridOwnerToken(DebridOwnerScope.Account("account-a"), 1), 1, 1)
            var current = initial
            val slot = PreparedEpisodeSlot<PreparedEpisodeAuthority>({ it.accepts(current) })
            val preparation = Preparation()
            preparation.resolveAction = {
                current = when (dimension) {
                    "owner" -> initial.copy(owner = initial.owner.copy(accountSlot = "account-b", revision = 2))
                    "profile" -> initial.copy(profileId = "profile-b", owner = initial.owner.copy(profileId = "profile-b", revision = 2))
                    "source" -> initial.copy(sourceRequest = fence.begin("profile-a", "episode-9"))
                    "audio" -> initial.copy(audioRevision = 2)
                    "credential" -> initial.copy(credentialRevision = 2)
                    "debrid" -> initial.copy(debridOwner = initial.debridOwner!!.copy(generation = 2))
                    else -> initial.copy(prewarmGeneration = 2)
                }
                assertFalse(initial.accepts(current))
                current = when (dimension) {
                    "owner", "profile" -> initial.copy(owner = initial.owner.copy(revision = 3))
                    "source" -> initial.copy(sourceRequest = fence.begin("profile-a", "episode-1"))
                    "audio" -> initial.copy(audioRevision = 3)
                    "credential" -> initial.copy(credentialRevision = 3)
                    "debrid" -> initial.copy(debridOwner = initial.debridOwner!!.copy(generation = 3))
                    else -> initial.copy(prewarmGeneration = 3)
                }
                Playable("https://fixture.invalid/late", dimension, playbackLease = AutoCloseable { preparation.leaseCloses++ })
            }
            assertFalse(slot.prepare(slot.begin(initial), "episode-2", preparation, { it.first().streams.first() }))
            assertFalse(slot.hasReady("episode-2"))
            assertEquals(dimension, 1, preparation.leaseCloses)
        }
    }

    @Test fun rejectedPlayableMappingDiscardsWithoutReplacingOriginalFailure() {
        var closes = 0
        val rejection = IllegalStateException("blank URL")
        val result = Result.success(Playable("", "Malformed", playbackLease = AutoCloseable { closes++ }))
            .mapOwnedPlayable<Any> { throw rejection }
        assertSame(rejection, result.exceptionOrNull())
        assertEquals(1, closes)
    }

    @Test fun realAttemptTimerExpiresWithoutAnyPlaybackTicksAndFreshnessCannotExtendIt() = runTest {
        val slot = PreparedEpisodeSlot<Long>({ true }, nowMs = { testScheduler.currentTime }, freshnessMs = 100)
        val stalled = Preparation().also { it.resolveAction = { awaitCancellation() } }
        var complete = false
        val pending = launch { assertFalse(slot.prepare(slot.begin(1), "episode-2", stalled, { it.first().streams.first() })); complete = true }
        runCurrent(); advanceTimeBy(15_000); runCurrent()
        assertTrue(complete); assertTrue(pending.isCompleted); assertEquals(1, stalled.closes)
        val ready = Preparation()
        assertTrue(slot.prepare(slot.begin(2), "episode-2", ready, { it.first().streams.first() }))
        advanceTimeBy(100)
        assertNull(slot.claim("episode-2"))
        assertEquals(1, ready.leaseCloses)
    }
    @Test fun ownerBoundResultDiscardsSuccessfulResourceAfterOwnerChanges() = runBlocking {
        val owner = DebridOwnerToken(DebridOwnerScope.Account("fixture"), 1)
        var current = owner
        var closes = 0
        val result = ownerBoundResult(expectedOwner = owner, currentOwner = { current }, discard = { value: Playable -> value.playbackLease?.close() }) {
            current = owner.copy(generation = 2)
            Result.success(Playable("https://fixture.invalid/prepared", "Prepared", playbackLease = AutoCloseable { closes++ }))
        }
        assertTrue(result.isFailure)
        assertEquals(1, closes)
    }

    @Test fun ownerBoundResultDiscardsNonCooperativeSuccessAfterCancellation() = runBlocking {
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var closes = 0
        val job = launch {
            ownerBoundResult(expectedOwner = null, currentOwner = { null }, discard = { value: Playable -> value.playbackLease?.close() }) {
                withContext(NonCancellable) { entered.complete(Unit); release.await() }
                Result.success(Playable("https://fixture.invalid/prepared", "Prepared", playbackLease = AutoCloseable { closes++ }))
            }
        }
        entered.await(); job.cancel(); release.complete(Unit); job.cancelAndJoin()
        assertEquals(1, closes)
    }
}
