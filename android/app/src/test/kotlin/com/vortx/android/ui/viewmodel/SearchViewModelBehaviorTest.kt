package com.vortx.android.ui.viewmodel

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.search.SearchHistoryStore
import com.vortx.android.ui.UiState
import java.lang.reflect.Proxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SearchViewModelBehaviorTest {
    @Test
    fun `trimmed queries below two characters stay idle without repository dispatch`() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        val scope = CoroutineScope(SupervisorJob() + main)
        Dispatchers.setMain(main)
        try {
            val repo = RecordingSearchRepository()
            val viewModel = SearchViewModel(repo, SearchHistoryStore(SearchTestContext()), scope)
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { viewModel.state.collect() }
            runCurrent()

            viewModel.onQueryChange("  x  ")
            advanceUntilIdle()

            assertTrue(repo.queries.isEmpty())
            assertEquals(UiState.Success(emptyList<MetaItem>()), viewModel.state.value)
        } finally {
            scope.cancel()
            runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `eligible query enters loading immediately then dispatches the trimmed value after debounce`() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        val scope = CoroutineScope(SupervisorJob() + main)
        Dispatchers.setMain(main)
        try {
            val repo = RecordingSearchRepository()
            val viewModel = SearchViewModel(repo, SearchHistoryStore(SearchTestContext()), scope)
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { viewModel.state.collect() }
            runCurrent()
            repo.queries.clear()

            viewModel.onQueryChange("  dune  ")
            runCurrent()

            assertEquals(UiState.Loading, viewModel.state.value)
            assertEquals(
                SearchScreenState("  dune  ", UiState.Loading, isLoading = true),
                viewModel.screenState.value,
            )
            assertTrue(repo.queries.isEmpty())

            advanceTimeBy(349)
            runCurrent()
            assertTrue(repo.queries.isEmpty())

            advanceTimeBy(1)
            runCurrent()
            assertEquals(listOf("dune"), repo.queries)
            assertEquals(
                UiState.Success(listOf(MetaItem("dune", MediaType.MOVIE, "dune"))),
                viewModel.state.value,
            )
        } finally {
            scope.cancel()
            runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `slow addon results publish incrementally until search settles`() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        val scope = CoroutineScope(SupervisorJob() + main)
        Dispatchers.setMain(main)
        try {
            val repo = ReactiveSearchRepository()
            val viewModel = SearchViewModel(repo, SearchHistoryStore(SearchTestContext()), scope)
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { viewModel.state.collect() }
            runCurrent()
            repo.updateQueries.clear()

            viewModel.onQueryChange("  dune  ")
            runCurrent()
            assertEquals(UiState.Loading, viewModel.state.value)

            advanceTimeBy(350)
            runCurrent()
            assertEquals(listOf("dune"), repo.updateQueries)

            repo.emit("dune", emptyList(), isLoading = true)
            runCurrent()
            assertEquals(UiState.Loading, viewModel.state.value)

            val movie = MetaItem("shared", MediaType.MOVIE, "Movie")
            repo.emit("dune", listOf(movie), isLoading = true)
            runCurrent()
            assertEquals(UiState.Success(listOf(movie)), viewModel.state.value)
            assertTrue(viewModel.screenState.value.isLoading)

            val series = MetaItem("shared", MediaType.SERIES, "Series")
            repo.emit("dune", listOf(movie, series), isLoading = false)
            runCurrent()
            assertEquals(UiState.Success(listOf(movie, series)), viewModel.state.value)
            assertTrue(!viewModel.screenState.value.isLoading)
        } finally {
            scope.cancel()
            runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `clearing to an ineligible query reaches unload stream without running one shot search`() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        val scope = CoroutineScope(SupervisorJob() + main)
        Dispatchers.setMain(main)
        try {
            val repo = ReactiveSearchRepository()
            val viewModel = SearchViewModel(repo, SearchHistoryStore(SearchTestContext()), scope)
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { viewModel.state.collect() }
            runCurrent()
            repo.updateQueries.clear()

            viewModel.onQueryChange("dune")
            advanceTimeBy(350)
            runCurrent()
            viewModel.onQueryChange(" x ")
            runCurrent()

            assertEquals(listOf("dune", "x"), repo.updateQueries)
            assertEquals(0, repo.oneShotSearchCalls)
            assertEquals(UiState.Success(emptyList<MetaItem>()), viewModel.state.value)
            assertTrue(!viewModel.screenState.value.isLoading)
        } finally {
            scope.cancel()
            runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `superseded query cannot republish stale addon results`() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        val scope = CoroutineScope(SupervisorJob() + main)
        Dispatchers.setMain(main)
        try {
            val repo = ReactiveSearchRepository()
            val viewModel = SearchViewModel(repo, SearchHistoryStore(SearchTestContext()), scope)
            backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { viewModel.state.collect() }
            runCurrent()

            viewModel.onQueryChange("dune")
            advanceTimeBy(350)
            runCurrent()
            viewModel.onQueryChange("blade")
            runCurrent()
            advanceTimeBy(350)
            runCurrent()

            repo.emit("dune", listOf(MetaItem("old", MediaType.MOVIE, "Old")), isLoading = false)
            runCurrent()
            assertEquals(UiState.Loading, viewModel.state.value)

            val current = MetaItem("new", MediaType.MOVIE, "New")
            repo.emit("blade", listOf(current), isLoading = false)
            runCurrent()
            assertEquals(UiState.Success(listOf(current)), viewModel.state.value)
        } finally {
            scope.cancel()
            runCurrent()
            Dispatchers.resetMain()
        }
    }

    private class RecordingSearchRepository : CatalogRepository by PreviewCatalogRepository(latencyMs = 0L) {
        val queries = mutableListOf<String>()

        override fun searchUpdates(query: String): Flow<Pair<List<MetaItem>, Boolean>> = flow {
            if (query.length < 2) {
                emit(emptyList<MetaItem>() to false)
                return@flow
            }
            emit(emptyList<MetaItem>() to true)
            emit(search(query).getOrThrow() to false)
        }

        override suspend fun search(query: String): Result<List<MetaItem>> {
            queries += query
            return Result.success(listOf(MetaItem(query, MediaType.MOVIE, query)))
        }
    }

    private class ReactiveSearchRepository : CatalogRepository by PreviewCatalogRepository(latencyMs = 0L) {
        val updateQueries = mutableListOf<String>()
        var oneShotSearchCalls = 0
        private val updates = mutableMapOf<String, MutableSharedFlow<Pair<List<MetaItem>, Boolean>>>()

        override suspend fun search(query: String): Result<List<MetaItem>> {
            oneShotSearchCalls += 1
            return Result.success(emptyList())
        }

        override fun searchUpdates(query: String): Flow<Pair<List<MetaItem>, Boolean>> = flow {
            updateQueries += query
            if (query.length < 2) {
                emit(emptyList<MetaItem>() to false)
            } else {
                emitAll(updates.getOrPut(query) { MutableSharedFlow(extraBufferCapacity = 4) })
            }
        }

        fun emit(query: String, items: List<MetaItem>, isLoading: Boolean) {
            check(updates.getOrPut(query) { MutableSharedFlow(extraBufferCapacity = 4) }.tryEmit(items to isLoading))
        }
    }

    private class SearchTestContext : ContextWrapper(null) {
        private val preferences = Proxy.newProxyInstance(
            SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java),
        ) { _, method, args ->
            when (method.name) {
                "getString", "getStringSet" -> args?.get(1)
                "getAll" -> emptyMap<String, Any>()
                "contains" -> false
                "toString" -> "SearchTestSharedPreferences"
                "hashCode" -> System.identityHashCode(this)
                "equals" -> this === args?.firstOrNull()
                else -> error("Unexpected SharedPreferences call: ${method.name}")
            }
        } as SharedPreferences

        override fun getApplicationContext(): Context = this

        override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = preferences
    }
}
