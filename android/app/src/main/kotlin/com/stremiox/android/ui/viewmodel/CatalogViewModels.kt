package com.stremiox.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.stremiox.android.data.CatalogRepository
import com.stremiox.android.model.Catalog
import com.stremiox.android.model.MediaType
import com.stremiox.android.model.MetaItem
import com.stremiox.android.ui.UiState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/// Maps a repository [Result] to a [UiState], turning a thrown/failed add-on call into a visible
/// error instead of an empty screen. Shared by every catalog ViewModel.
private fun <T> Result<T>.toUiState(): UiState<T> = fold(
    onSuccess = { UiState.Success(it) },
    onFailure = { UiState.Error(it.message ?: "Something went wrong loading your add-ons.") },
)

/// Home: Continue Watching + add-on catalog rails. Loads once on construction.
class HomeViewModel(private val repo: CatalogRepository) : ViewModel() {
    private val _state = MutableStateFlow<UiState<List<Catalog>>>(UiState.Loading)
    val state: StateFlow<UiState<List<Catalog>>> = _state.asStateFlow()

    init {
        load()
    }

    fun load() {
        _state.value = UiState.Loading
        viewModelScope.launch { _state.value = repo.home().toUiState() }
    }
}

/// Discover: add-on catalog rails for the selected [MediaType]. Re-loads when the type changes.
@OptIn(ExperimentalCoroutinesApi::class)
class DiscoverViewModel(private val repo: CatalogRepository) : ViewModel() {
    private val _type = MutableStateFlow(MediaType.MOVIE)
    val type: StateFlow<MediaType> = _type.asStateFlow()

    val state: StateFlow<UiState<List<Catalog>>> = _type
        .flatMapLatest { t -> flow { emit(repo.discover(t).toUiState()) } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState.Loading)

    fun selectType(type: MediaType) {
        _type.value = type
    }
}

/// Library: the user's saved titles.
class LibraryViewModel(private val repo: CatalogRepository) : ViewModel() {
    private val _state = MutableStateFlow<UiState<List<MetaItem>>>(UiState.Loading)
    val state: StateFlow<UiState<List<MetaItem>>> = _state.asStateFlow()

    init {
        viewModelScope.launch { _state.value = repo.library().toUiState() }
    }
}

/// Search: debounced full-text query across every installed add-on. An empty query is a calm idle
/// state, never an error.
@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
class SearchViewModel(private val repo: CatalogRepository) : ViewModel() {
    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    val state: StateFlow<UiState<List<MetaItem>>> = _query
        .debounce { if (it.isBlank()) 0L else SEARCH_DEBOUNCE_MS }
        .distinctUntilChanged()
        .flatMapLatest { q ->
            flow {
                if (q.isNotBlank()) emit(UiState.Loading)
                emit(repo.search(q).toUiState())
            }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState.Success(emptyList()))

    fun onQueryChange(value: String) {
        _query.value = value
    }

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 350L
    }
}
