package com.vortx.android.ui.viewmodel

import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.ContinueWatchingDismissal
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.ContinueWatchingSnapshot
import com.vortx.android.data.HomeSnapshot
import com.vortx.android.data.HomeUpdate
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import com.vortx.android.ui.components.PosterCardMenu
import com.vortx.android.ui.components.posterMenuFor
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.coroutines.ContinuationInterceptor

@OptIn(ExperimentalCoroutinesApi::class)
class HomeContinueWatchingDismissTest {
    private val one = MetaItem("tt1", MediaType.MOVIE, "One")
    private val two = MetaItem("tt2", MediaType.SERIES, "Two")
    private val ownerA = owner("profile-a", revision = 1L)
    private val ownerB = owner("profile-b", revision = 2L)

    @Test
    fun `late old-owner emission cannot replace a newer owner snapshot`() = runTest {
        val fixture = fixture(ownerA, rows(one, two))
        runCurrent()

        val ownerBItem = MetaItem("tt-b", MediaType.MOVIE, "Owner B")
        fixture.repo.emit(HomeSnapshot(ownerB, rows(ownerBItem)), makeCurrent = true)
        runCurrent()
        fixture.repo.emit(HomeSnapshot(ownerA, rows(one)), makeCurrent = false)
        runCurrent()

        assertEquals(listOf(ownerBItem), fixture.viewModel.successRows().single().items)
        fixture.close()
    }

    @Test
    fun `profile switch while mutation is suspended never mutates or rolls back the new owner`() = runTest {
        val fixture = fixture(ownerA, rows(one, two))
        val removeStarted = CompletableDeferred<Unit>()
        val releaseRemove = CompletableDeferred<Unit>()
        fixture.repo.removeBehavior = { target ->
            removeStarted.complete(Unit)
            releaseRemove.await()
            if (fixture.repo.currentOwner == target.owner) {
                fixture.repo.mutatedTargets += target
                Result.success(Unit)
            } else {
                Result.failure(IllegalStateException("owner changed"))
            }
        }
        runCurrent()

        fixture.viewModel.removeFromContinueWatching(one)
        runCurrent()
        assertTrue(removeStarted.isCompleted)
        assertEquals(listOf(two), fixture.viewModel.successRows().single().items)

        val ownerBItem = MetaItem("tt-b", MediaType.SERIES, "Owner B")
        fixture.repo.emit(HomeSnapshot(ownerB, rows(ownerBItem)), makeCurrent = true)
        runCurrent()
        releaseRemove.complete(Unit)
        runCurrent()

        assertTrue(fixture.repo.mutatedTargets.isEmpty())
        assertEquals(ownerA, fixture.repo.attemptedTargets.single().owner)
        assertEquals(MediaType.MOVIE, fixture.repo.attemptedTargets.single().type)
        assertEquals("tt1", fixture.repo.attemptedTargets.single().id)
        assertEquals(listOf(ownerBItem), fixture.viewModel.successRows().single().items)
        fixture.close()
    }

    @Test
    fun `dismissal carries media type and preserves same-id title of another type`() = runTest {
        val sameIdSeries = MetaItem("tt1", MediaType.SERIES, "Series One")
        val fixture = fixture(ownerA, rows(one, sameIdSeries))
        runCurrent()

        fixture.viewModel.removeFromContinueWatching(one)
        runCurrent()

        assertEquals(listOf(sameIdSeries), fixture.viewModel.successRows().single().items)
        assertEquals(MediaType.MOVIE, fixture.repo.attemptedTargets.single().type)
        assertEquals("tt1", fixture.repo.attemptedTargets.single().id)
        fixture.close()
    }

    @Test
    fun `native no-op times out and rolls optimistic card back`() = runTest {
        val fixture = fixture(ownerA, rows(one, two), confirmationTimeoutMs = 10L)
        fixture.repo.snapshotBehavior = {
            Result.success(ContinueWatchingSnapshot(ownerA, listOf(one, two)))
        }
        runCurrent()

        fixture.viewModel.removeFromContinueWatching(one)
        runCurrent()
        assertEquals(listOf(two), fixture.viewModel.successRows().single().items)
        advanceTimeBy(11L)
        runCurrent()

        assertEquals(listOf(one, two), fixture.viewModel.successRows().single().items)
        fixture.close()
    }

    @Test
    fun `literal-null native confirmation failure rolls optimistic card back`() = runTest {
        val fixture = fixture(ownerA, rows(one, two))
        val readStarted = CompletableDeferred<Unit>()
        val releaseRead = CompletableDeferred<Unit>()
        fixture.repo.snapshotBehavior = {
            readStarted.complete(Unit)
            releaseRead.await()
            Result.failure(IllegalStateException("native returned literal null"))
        }
        runCurrent()

        fixture.viewModel.removeFromContinueWatching(one)
        runCurrent()
        assertTrue(readStarted.isCompleted)
        // The ordinary Home decoder is fail-soft and may temporarily omit the rail on native null. That
        // emission must not become confirmation or erase the rollback copy.
        fixture.repo.emit(HomeSnapshot(ownerA, rows(two)), makeCurrent = true)
        runCurrent()
        releaseRead.complete(Unit)
        runCurrent()

        assertEquals(listOf(one, two), fixture.viewModel.successRows().single().items)
        fixture.close()
    }

    @Test
    fun `native read exception rolls optimistic card back`() = runTest {
        val fixture = fixture(ownerA, rows(one, two))
        fixture.repo.snapshotBehavior = { Result.failure(IllegalStateException("JNI read failed")) }
        runCurrent()

        fixture.viewModel.removeFromContinueWatching(one)
        runCurrent()

        assertEquals(listOf(one, two), fixture.viewModel.successRows().single().items)
        fixture.close()
    }

    @Test
    fun `collection stays on Main dispatcher and cancellation reaches background mutation`() = runTest {
        val fixture = fixture(ownerA, rows(one, two))
        val removeStarted = CompletableDeferred<Unit>()
        var removalCancelled = false
        fixture.repo.removeBehavior = {
            removeStarted.complete(Unit)
            try {
                awaitCancellation()
            } finally {
                removalCancelled = true
            }
        }
        runCurrent()

        fixture.viewModel.removeFromContinueWatching(one)
        runCurrent()
        assertTrue(removeStarted.isCompleted)
        assertSame(fixture.mainDispatcher, fixture.repo.collectionDispatcher)
        assertSame(fixture.backgroundDispatcher, fixture.repo.removalDispatcher)

        fixture.close()
        runCurrent()
        assertTrue(removalCancelled)
        assertEquals(0, fixture.repo.confirmationReads)
    }

    @Test
    fun `local Continue Watching has dismiss menu and remote read only does not`() {
        assertEquals(
            PosterCardMenu.CONTINUE_WATCHING,
            posterMenuFor(Catalog("continue", "Continue Watching", listOf(one))),
        )
        assertEquals(
            PosterCardMenu.NONE,
            posterMenuFor(Catalog("continue", "Continue Watching", listOf(one), readOnly = true)),
        )
        assertFalse(posterMenuFor(Catalog("popular", "Popular", listOf(one))) == PosterCardMenu.NONE)
    }

    private fun TestScope.fixture(
        owner: ContinueWatchingOwner,
        rows: List<Catalog>,
        confirmationTimeoutMs: Long = 100L,
    ): Fixture {
        val main = StandardTestDispatcher(testScheduler, "home-main")
        val background = StandardTestDispatcher(testScheduler, "dismiss-background")
        val scope = CoroutineScope(SupervisorJob() + main)
        val repo = ControlledRepository(HomeSnapshot(owner, rows))
        val viewModel = HomeViewModel(
            repo = repo,
            dismissalDispatcher = background,
            scopeOverride = scope,
            confirmationTimeoutMs = confirmationTimeoutMs,
            confirmationPollMs = 1L,
        )
        return Fixture(viewModel, repo, scope, main, background)
    }

    private data class Fixture(
        val viewModel: HomeViewModel,
        val repo: ControlledRepository,
        val scope: CoroutineScope,
        val mainDispatcher: CoroutineDispatcher,
        val backgroundDispatcher: CoroutineDispatcher,
    ) {
        fun close() = scope.cancel()
    }

    private class ControlledRepository(initial: HomeSnapshot) :
        CatalogRepository by PreviewCatalogRepository(latencyMs = 0L) {
        private var sequence = 0L
        private val updates = MutableSharedFlow<HomeUpdate>(replay = 1, extraBufferCapacity = 8).apply {
            tryEmit(initial.asUpdate(sequence))
        }

        var currentOwner: ContinueWatchingOwner = initial.owner
        var collectionDispatcher: ContinuationInterceptor? = null
        var removalDispatcher: ContinuationInterceptor? = null
        var confirmationReads = 0
        val attemptedTargets = mutableListOf<ContinueWatchingDismissal>()
        val mutatedTargets = mutableListOf<ContinueWatchingDismissal>()
        var removeBehavior: suspend (ContinueWatchingDismissal) -> Result<Unit> = {
            mutatedTargets += it
            Result.success(Unit)
        }
        var snapshotBehavior: suspend () -> Result<ContinueWatchingSnapshot> = {
            Result.success(ContinueWatchingSnapshot(currentOwner, emptyList()))
        }

        override fun continueWatchingOwner(): ContinueWatchingOwner = currentOwner

        override fun homeUpdates(): Flow<HomeUpdate> = flow {
            collectionDispatcher = currentCoroutineContext()[ContinuationInterceptor]
            updates.collect { emit(it) }
        }

        override suspend fun removeFromContinueWatching(target: ContinueWatchingDismissal): Result<Unit> {
            removalDispatcher = currentCoroutineContext()[ContinuationInterceptor]
            attemptedTargets += target
            return removeBehavior(target)
        }

        override suspend fun continueWatchingSnapshot(
            expectedOwner: ContinueWatchingOwner,
        ): Result<ContinueWatchingSnapshot> {
            confirmationReads++
            return snapshotBehavior()
        }

        suspend fun emit(snapshot: HomeSnapshot, makeCurrent: Boolean) {
            if (makeCurrent) currentOwner = snapshot.owner
            sequence += 1
            updates.emit(snapshot.asUpdate(sequence))
        }

        private fun HomeSnapshot.asUpdate(sequence: Long) = HomeUpdate(
            rows = rows,
            generation = owner.revision,
            sequence = sequence,
            profileId = owner.profileId,
            owner = owner,
        )
    }

    private fun HomeViewModel.successRows(): List<Catalog> =
        (state.value as UiState.Success<List<Catalog>>).data

    private fun rows(vararg items: MetaItem): List<Catalog> =
        listOf(Catalog("continue", "Continue Watching", items.toList()))

    private fun owner(profileId: String, revision: Long) = ContinueWatchingOwner(
        profileId = profileId,
        accountSlot = "account.$profileId",
        principal = "principal.$profileId",
        usesEngineHistory = true,
        revision = revision,
    )
}
