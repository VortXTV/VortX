package com.vortx.android.ui.viewmodel

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.SourcePreparation
import com.vortx.android.data.SourcePreparationAdoption
import com.vortx.android.data.StreamLoadUpdate
import com.vortx.android.engine.SourceListModel
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.player.PlayerSourceSwitchCommitGate
import com.vortx.android.singularity.SourceIndexClient
import com.vortx.android.sources.SourceRequestFence
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure source-publication fixtures: no native engine, HTTP requests, Android context, or live accounts. */
class SourceIndexPublicationBridgeTest {
    private val ordinary = group("ordinary-1", "Configured add-on", "https://addon.invalid/manifest.json")
    private val ordinaryNamedSingularity = group("own-1", "Singularity", "https://own-addon.invalid/manifest.json")
    private val pooled = group("pooled-1", "Singularity", SourceIndexClient.GROUP_ID)

    @Test fun replayBeforeFirstSnapshotStripsOnlyPoolAndKeepsLaterOrdinaryPartials() {
        val bridge = SourceIndexPublicationBridge()
        val request = SourceRequestFence("profile").begin("profile", "episode-1")
        assertNull(bridge.revoke("context-1"))
        val initial = StreamLoadUpdate(listOf(ordinary, ordinaryNamedSingularity, pooled), 1, 2,
            terminal = false, sourcePublicationId = "context-1")
        val shown = bridge.accept(request, initial.sourcePublicationId, initial.groups)
        assertEquals(listOf(ordinary, ordinaryNamedSingularity), shown)
        assertSame(ordinaryNamedSingularity, shown.last())

        val newerOrdinary = ordinary.copy(streams = ordinary.streams + source("ordinary-2", ordinary.addon))
        val terminal = initial.copy(groups = listOf(newerOrdinary, ordinaryNamedSingularity, pooled),
            loaded = 2, terminal = true)
        assertEquals(listOf(newerOrdinary, ordinaryNamedSingularity),
            bridge.accept(request, terminal.sourcePublicationId, terminal.groups))
        assertSame(newerOrdinary, requireNotNull(bridge.currentGroups(request)).first())
    }

    @Test fun invalidationAfterTerminalUsesNewestRawAndRejectsCoalescerAndCacheReappearance() {
        val bridge = SourceIndexPublicationBridge()
        val request = SourceRequestFence("profile").begin("profile", "episode-1")
        bridge.accept(request, "context-1", listOf(ordinary, pooled))
        val newerOrdinary = ordinary.copy(streams = ordinary.streams + source("ordinary-2", ordinary.addon))
        val latest = listOf(newerOrdinary, ordinaryNamedSingularity, pooled)
        bridge.recordDecoration(request, latest)

        assertSame(request, bridge.revoke("context-1"))
        assertEquals(listOf(newerOrdinary, ordinaryNamedSingularity), bridge.currentGroups(request))
        assertEquals(listOf(newerOrdinary, ordinaryNamedSingularity), bridge.visibleGroups(request, latest))
        assertEquals(listOf(newerOrdinary, ordinaryNamedSingularity), bridge.recordDecoration(request, latest))
        assertTrue(bridge.isRevoked(request))
    }

    @Test fun revokedUuidCannotAttachToAnotherRequestProfileOrTarget() {
        val fence = SourceRequestFence("profile")
        val bridge = SourceIndexPublicationBridge()
        val first = fence.begin("profile", "episode-1")
        bridge.accept(first, "context-1", listOf(ordinary, pooled))
        val rankingOnly = fence.begin("profile", "episode-1")
        bridge.transferRankingRequest(first, rankingOnly)
        assertEquals("context-1", bridge.publicationId(rankingOnly))
        assertSame(rankingOnly, bridge.revoke("context-1"))

        val otherTarget = fence.begin("profile", "episode-2")
        bridge.transferRankingRequest(rankingOnly, otherTarget)
        assertNull(bridge.publicationId(otherTarget))
        assertNull(bridge.revoke("context-1"))
        val newRows = listOf(ordinary, pooled)
        assertSame(newRows, bridge.accept(otherTarget, "context-2", newRows))
        assertFalse(bridge.isRevoked(otherTarget))

        val otherProfile = fence.begin("other-profile", "episode-2")
        bridge.transferRankingRequest(otherTarget, otherProfile)
        assertNull(bridge.publicationId(otherProfile))
        bridge.clear()
        assertNull(bridge.currentGroups(otherProfile))
        // Clearing accepted ownership does not erase an early revocation that may precede adoption.
        assertEquals(listOf(ordinary), bridge.accept(otherProfile, "context-1", listOf(ordinary, pooled)))
    }

    @Test fun exactPreparedAuthoritySeedsIdBeforeRowsAndStillObservesPostAdoptionRevocation() {
        for (replayedBeforeAdoption in listOf(false, true)) {
            val bridge = SourceIndexPublicationBridge()
            val fence = SourceRequestFence("profile")
            val request = fence.begin("profile", "episode-2")
            val preparation = FixturePreparation(listOf(ordinary, pooled), "prepared-context")
            val prepared = PreparedEpisode("episode-2", ordinary.streams.first(),
                Playable("https://fixture.invalid/playable", "Prepared"), preparation)
            if (replayedBeforeAdoption) assertNull(bridge.revoke(preparation.sourcePublicationId))
            var shown = emptyList<StreamGroup>()
            val handoff = preparedEpisodeHandoff(prepared, commitGate = PlayerSourceSwitchCommitGate(),
                isCurrent = { true }, install = {
                    assertEquals(1, preparation.adoptions)
                    shown = bridge.accept(request, preparation.sourcePublicationId, preparation.groups)
                }, rollback = {})

            assertTrue(handoff.commitIfCurrent { true })
            assertEquals("prepared-context", bridge.publicationId(request))
            if (replayedBeforeAdoption) assertEquals(listOf(ordinary), shown)
            assertSame(request, bridge.revoke("prepared-context"))
            assertEquals(listOf(ordinary), bridge.currentGroups(request))
            assertEquals(1, preparation.adoptions)
        }
    }

    @Test fun retiredPreparationGetterBeatsCachedHandoffRowsBeforeInvalidationOrIoCleanup() {
        val bridge = SourceIndexPublicationBridge()
        val request = SourceRequestFence("profile").begin("profile", "episode-2")
        val cached = listOf(ordinary, pooled)
        val preparation = FixturePreparation(cached, "prepared-context")
        val prepared = PreparedEpisode("episode-2", ordinary.streams.first(),
            Playable("https://fixture.invalid/playable", "Prepared ordinary source"), preparation)
        // The scalar witness retires immediately. Cache cleanup and the replayed invalidation remain queued.
        preparation.poolRetired = true
        var shown = emptyList<StreamGroup>()
        val handoff = preparedEpisodeHandoff(prepared, commitGate = PlayerSourceSwitchCommitGate(),
            isCurrent = { true }, install = { staleHandoffRows ->
                assertSame(cached, staleHandoffRows)
                val publicationId = preparation.sourcePublicationId
                shown = bridge.accept(request, publicationId, preparation.groups)
            }, rollback = {})

        assertTrue(handoff.commitIfCurrent { true })
        assertEquals(listOf(ordinary), shown)
        assertEquals(listOf(ordinary), bridge.currentGroups(request))
        assertFalse(bridge.isRevoked(request))
        assertEquals(1, preparation.adoptions)
    }

    @Test fun rejectedPreparedBRestoresCachedAThroughCurrentScalarWitnessBeforeQueuedCleanup() {
        val currentIds = mutableSetOf("context-A", "context-B")
        val bridge = SourceIndexPublicationBridge { it in currentIds }
        val fence = SourceRequestFence("profile")
        var displayedRequest = fence.begin("profile", "episode-A")
        val cachedPreviousRows = listOf(ordinary, ordinaryNamedSingularity, pooled)
        var shown = bridge.accept(displayedRequest, "context-A", cachedPreviousRows)
        val previousId = bridge.publicationId(displayedRequest)
        val preparation = FixturePreparation(listOf(ordinary, pooled), "context-B")
        val prepared = PreparedEpisode("episode-B", ordinary.streams.first(),
            Playable("https://fixture.invalid/prepared-B", "Prepared ordinary B"), preparation)
        val rejection = IllegalStateException("B rejected before host acknowledgment")
        val handoff = preparedEpisodeHandoff(prepared, commitGate = PlayerSourceSwitchCommitGate(),
            isCurrent = { true }, install = {
                displayedRequest = fence.begin("profile", "episode-B")
                shown = bridge.accept(displayedRequest, preparation.sourcePublicationId, preparation.groups)
            }, rollback = {
                displayedRequest = fence.begin("profile", "episode-A")
                shown = bridge.accept(displayedRequest, previousId, cachedPreviousRows)
            })

        val result = runCatching {
            handoff.commitIfCurrent(hostAuthorityIsCurrent = { true }) {
                // A's epoch is retired synchronously; its cached rows and invalidation are still queued.
                currentIds.remove("context-A")
                throw rejection
            }
        }
        assertSame(rejection, result.exceptionOrNull())
        assertEquals("context-A", bridge.publicationId(displayedRequest))
        assertEquals(listOf(ordinary, ordinaryNamedSingularity), shown)
        assertEquals(shown, bridge.currentGroups(displayedRequest))
        assertTrue(bridge.isRevoked(displayedRequest))
        assertSame(ordinaryNamedSingularity, shown.last())
    }

    @Test fun boundedPendingEventsCannotEraseCurrentRevocationAndUnknownContextsStayPoolFree() {
        val validIds = setOf("current-context", "last-pending", "fresh-context")
        val bridge = SourceIndexPublicationBridge { it in validIds }
        val fence = SourceRequestFence("profile")
        val request = fence.begin("profile", "episode-1")
        val groups = listOf(ordinary, ordinaryNamedSingularity, pooled)
        bridge.accept(request, "current-context", groups)
        assertSame(request, bridge.revoke("current-context"))
        // Only the latest pending id is retained. The current publication's own revoked bit survives.
        repeat(512) { bridge.revoke("unrelated-old-context-$it") }
        assertEquals(listOf(ordinary, ordinaryNamedSingularity),
            bridge.accept(request, "current-context", groups))
        assertEquals(listOf(ordinary, ordinaryNamedSingularity), bridge.visibleGroups(request, groups))
        assertEquals(listOf(ordinary, ordinaryNamedSingularity), bridge.recordDecoration(request, groups))

        bridge.clear()
        assertNull(bridge.revoke("last-pending"))
        val next = fence.begin("profile", "episode-2")
        assertEquals(listOf(ordinary, ordinaryNamedSingularity), bridge.accept(next, "last-pending", groups))
        assertSame(groups, bridge.accept(next, "fresh-context", groups))
        assertEquals(listOf(ordinary, ordinaryNamedSingularity), bridge.accept(next, "unknown-context", groups))
        assertEquals(listOf(ordinary, ordinaryNamedSingularity), bridge.accept(next, null, groups))
    }

    @Test fun repositoryPoolBaseNeverRecontributesButConfiguredSingularityAddonDoes() {
        val captured = SourceListModel.contributionGroups(
            listOf(ordinary, ordinaryNamedSingularity, pooled), emptyList(), emptySet())
        assertEquals(listOf(ordinary, ordinaryNamedSingularity), captured)
        assertSame(ordinaryNamedSingularity, captured.last())
        val displayed = SourceListModel.assemble(listOf(ordinary, ordinaryNamedSingularity, pooled),
            emptyList(), emptyList(), emptyList(), emptyList(), SourceListModel.Context()).groups
        assertTrue(displayed.any { it.base == SourceIndexClient.GROUP_ID })
        assertTrue(displayed.any { it.base == ordinaryNamedSingularity.base })
    }

    private fun source(id: String, addon: String) =
        StreamSource(id, addon, "Fixture", url = "https://fixture.invalid/$id")

    private fun group(id: String, addon: String, base: String) =
        StreamGroup(addon, listOf(source(id, addon)), base = base)

    private class FixturePreparation(
        private val cachedGroups: List<StreamGroup>,
        override val sourcePublicationId: String,
    ) : SourcePreparation {
        override val owner = ContinueWatchingOwner("profile", "account", "principal", true, 1)
        var poolRetired = false
        override val groups: List<StreamGroup>
            get() = if (poolRetired) cachedGroups.filterNot { it.base == SourceIndexClient.GROUP_ID } else cachedGroups
        var adoptions = 0
        override fun isCurrent() = true
        override fun updates(): Flow<StreamLoadUpdate> = flowOf(StreamLoadUpdate(groups, 1, 1,
            terminal = true, sourcePublicationId = sourcePublicationId))
        override suspend fun resolve(source: StreamSource): Result<Playable> =
            Result.failure(IllegalStateException("No resolve is needed for this handoff fixture"))
        override fun adopt(): SourcePreparationAdoption? {
            if (adoptions != 0) return null
            adoptions++
            return object : SourcePreparationAdoption {
                // Deliberately stale fixture: install must reread the preparation after actual adoption.
                override val groups = cachedGroups
                override val sourcePublicationId = this@FixturePreparation.sourcePublicationId
                override fun rollback() = Unit
            }
        }
        override fun close() = Unit
    }
}
