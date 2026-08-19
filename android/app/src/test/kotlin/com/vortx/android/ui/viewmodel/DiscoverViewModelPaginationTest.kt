package com.vortx.android.ui.viewmodel

import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.CatalogPreferencesStore
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.model.AdvancedDiscoverFilters
import com.vortx.android.model.DiscoverFilters
import com.vortx.android.model.DiscoverResult
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DiscoverViewModelPaginationTest {
    @Test
    fun `cursorless nonempty catalog exposes count driven next page`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val repo = RecordingDiscoverRepository(result(count = 1, hasCursor = false))
            val viewModel = DiscoverViewModel(repo)

            advanceUntilIdle()

            val result = (viewModel.state.value as UiState.Success).data
            assertTrue(result.filters.hasNextPage)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `cursorless pagination continues on growth then latches exhausted on no growth`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val repo = RecordingDiscoverRepository(result(count = 1, hasCursor = false)).apply {
                nextResults += result(count = 2, hasCursor = false)
                nextResults += result(count = 2, hasCursor = false)
            }
            val viewModel = DiscoverViewModel(repo)
            advanceUntilIdle()

            viewModel.loadMore()
            advanceUntilIdle()
            assertTrue(success(viewModel).filters.hasNextPage)

            viewModel.loadMore()
            advanceUntilIdle()
            assertFalse(success(viewModel).filters.hasNextPage)
            assertEquals(2, repo.nextPageCalls)

            viewModel.loadMore()
            advanceUntilIdle()
            assertEquals(2, repo.nextPageCalls)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `real cursor remains authoritative after a settled no growth page`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val repo = RecordingDiscoverRepository(result(count = 1, hasCursor = true)).apply {
                nextResults += result(count = 1, hasCursor = true)
                nextResults += result(count = 2, hasCursor = true)
            }
            val viewModel = DiscoverViewModel(repo)
            advanceUntilIdle()

            viewModel.loadMore()
            advanceUntilIdle()
            assertTrue(success(viewModel).filters.hasNextPage)
            viewModel.loadMore()
            advanceUntilIdle()

            assertEquals(2, repo.nextPageCalls)
            assertTrue(success(viewModel).filters.hasNextPage)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `select resets cursorless exhaustion`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val repo = RecordingDiscoverRepository(result(count = 1, hasCursor = false)).apply {
                nextResults += result(count = 1, hasCursor = false)
            }
            val viewModel = DiscoverViewModel(repo)
            advanceUntilIdle()
            viewModel.loadMore()
            advanceUntilIdle()
            assertFalse(success(viewModel).filters.hasNextPage)

            repo.discoverResult = result(count = 1, hasCursor = false, prefix = "new")
            viewModel.select("new-selection")
            advanceUntilIdle()

            assertTrue(success(viewModel).filters.hasNextPage)
            assertEquals("new-1", success(viewModel).items.single().id)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `context reconcile resets cursorless exhaustion`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val repo = RecordingDiscoverRepository(result(count = 1, hasCursor = false)).apply {
                nextResults += result(count = 1, hasCursor = false)
            }
            val viewModel = DiscoverViewModel(repo)
            advanceUntilIdle()
            viewModel.loadMore()
            advanceUntilIdle()
            assertFalse(success(viewModel).filters.hasNextPage)

            repo.discoverResult = result(count = 1, hasCursor = false, prefix = "ctx")
            repo.emitContextChange()
            advanceUntilIdle()

            assertTrue(success(viewModel).filters.hasNextPage)
            assertEquals("ctx-1", success(viewModel).items.single().id)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `duplicate load more calls dispatch once and stale page cannot overwrite selection`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val repo = RecordingDiscoverRepository(result(count = 1, hasCursor = false))
            val viewModel = DiscoverViewModel(repo)
            advanceUntilIdle()
            val pending = CompletableDeferred<Result<DiscoverResult>>()
            repo.pendingNextPage = pending

            viewModel.loadMore()
            viewModel.loadMore()
            runCurrent()
            assertEquals(1, repo.nextPageCalls)

            repo.discoverResult = result(count = 1, hasCursor = false, prefix = "selected")
            viewModel.select("selected")
            runCurrent()
            pending.complete(Result.success(result(count = 2, hasCursor = false, prefix = "stale")))
            advanceUntilIdle()

            assertEquals("selected-1", success(viewModel).items.single().id)
            assertFalse(viewModel.loadingMore.value)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `late context reconcile cannot publish over a newer manual selection`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val repo = RacingDiscoverRepository()
            val viewModel = DiscoverViewModel(repo)
            advanceUntilIdle()

            val contextResult = CompletableDeferred<Result<DiscoverResult>>()
            repo.contextDefault = contextResult
            repo.emitContextChange()
            runCurrent()

            val manualResult = CompletableDeferred<Result<DiscoverResult>>()
            repo.manualSelection = manualResult
            viewModel.select("manual")
            runCurrent()

            manualResult.complete(Result.success(result(count = 1, hasCursor = false, prefix = "manual")))
            advanceUntilIdle()
            assertEquals("manual-1", success(viewModel).items.single().id)

            contextResult.complete(Result.success(result(count = 1, hasCursor = false, prefix = "context")))
            advanceUntilIdle()

            assertEquals("manual-1", success(viewModel).items.single().id)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `active thin filter automatically fills until matches reach floor or pagination exhausts`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val repo = RecordingDiscoverRepository(
                DiscoverResult(
                    items = listOf(MetaItem("movie-1", MediaType.MOVIE, "One", genres = listOf("Comedy"))),
                    filters = DiscoverFilters(hasNextPage = false),
                ),
            ).apply {
                nextResults += DiscoverResult(
                    items = listOf(
                        MetaItem("movie-1", MediaType.MOVIE, "One", genres = listOf("Comedy")),
                        MetaItem("movie-2", MediaType.MOVIE, "Two", genres = listOf("Drama")),
                    ),
                    filters = DiscoverFilters(hasNextPage = false),
                )
                nextResults += DiscoverResult(
                    items = listOf(
                        MetaItem("movie-1", MediaType.MOVIE, "One", genres = listOf("Comedy")),
                        MetaItem("movie-2", MediaType.MOVIE, "Two", genres = listOf("Drama")),
                    ),
                    filters = DiscoverFilters(hasNextPage = false),
                )
            }
            val preferences = CatalogPreferencesStore.inMemory()
            val viewModel = DiscoverViewModel(repo, preferences, filterFillFloor = 2)
            advanceUntilIdle()

            viewModel.setAdvancedFilters(AdvancedDiscoverFilters(includedGenres = setOf("Drama")))
            advanceUntilIdle()

            assertEquals(listOf("movie-2"), viewModel.filteredItems(success(viewModel)).map(MetaItem::id))
            assertEquals(2, repo.nextPageCalls)
            assertFalse(success(viewModel).filters.hasNextPage)
        } finally {
            Dispatchers.resetMain()
        }
    }

    private fun success(viewModel: DiscoverViewModel): DiscoverResult =
        (viewModel.state.value as UiState.Success).data

    private class RecordingDiscoverRepository(
        var discoverResult: DiscoverResult,
    ) : CatalogRepository by PreviewCatalogRepository(latencyMs = 0L) {
        private val ctx = MutableSharedFlow<Unit>(replay = 1).apply { tryEmit(Unit) }
        val nextResults = ArrayDeque<DiscoverResult>()
        var nextPageCalls = 0
        var pendingNextPage: CompletableDeferred<Result<DiscoverResult>>? = null

        override fun ctxUpdates(): Flow<Unit> = ctx

        override suspend fun discover(requestJson: String?): Result<DiscoverResult> = Result.success(discoverResult)

        override suspend fun discoverNextPage(): Result<DiscoverResult> {
            nextPageCalls += 1
            return pendingNextPage?.await() ?: Result.success(nextResults.removeFirst())
        }

        fun emitContextChange() {
            check(ctx.tryEmit(Unit))
        }
    }

    private class RacingDiscoverRepository : CatalogRepository by PreviewCatalogRepository(latencyMs = 0L) {
        private val ctx = MutableSharedFlow<Unit>(replay = 1).apply { tryEmit(Unit) }
        var contextDefault: CompletableDeferred<Result<DiscoverResult>>? = null
        var manualSelection: CompletableDeferred<Result<DiscoverResult>>? = null

        override fun ctxUpdates(): Flow<Unit> = ctx

        override suspend fun discover(requestJson: String?): Result<DiscoverResult> = when {
            requestJson == null && contextDefault != null -> withContext(NonCancellable) {
                contextDefault!!.await()
            }
            requestJson != null && manualSelection != null -> manualSelection!!.await()
            else -> Result.success(result(count = 1, hasCursor = false, prefix = "initial"))
        }

        fun emitContextChange() {
            check(ctx.tryEmit(Unit))
        }
    }

    private companion object {
        fun result(count: Int, hasCursor: Boolean, prefix: String = "movie"): DiscoverResult =
            DiscoverResult(
                items = (1..count).map { MetaItem("$prefix-$it", MediaType.MOVIE, "$prefix $it") },
                filters = DiscoverFilters(hasNextPage = hasCursor),
            )
    }
}
