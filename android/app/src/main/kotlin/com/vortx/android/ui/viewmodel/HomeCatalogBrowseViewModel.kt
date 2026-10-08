package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.Catalog
import com.vortx.android.ui.UiState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Stable route identity for a full-grid view of an already-published Home catalog. */
data class HomeCatalogTarget(val id: String, val title: String)

/**
 * Projects one existing Home board row into a full grid. It deliberately observes [CatalogRepository.homeUpdates]
 * rather than issuing a second catalog request: the rail and grid therefore share add-on ordering, partial
 * settlement, and paging truth. HomeViewModel remains the owner of Home composition and is not mutated here.
 */
class HomeCatalogBrowseViewModel(
    private val repo: CatalogRepository,
    private val target: HomeCatalogTarget,
) : ViewModel() {
    private val _state = MutableStateFlow<UiState<Catalog>>(UiState.Loading)
    val state: StateFlow<UiState<Catalog>> = _state.asStateFlow()
    private var current: Catalog? = null

    init {
        viewModelScope.launch {
            repo.homeUpdates().collect { update ->
                val catalog = update.rows.firstOrNull { it.id == target.id }
                if (catalog != null) {
                    current = catalog
                    _state.value = UiState.Success(catalog)
                } else if (update.authoritative) {
                    _state.value = UiState.Error("${target.title} is no longer available.")
                }
            }
        }
    }

    fun retry() = reloadBoard()

    fun loadNextPage() {
        val catalog = current ?: return
        viewModelScope.launch { repo.loadHomeRowNextPage(catalog) }
    }

    private fun reloadBoard() {
        viewModelScope.launch {
            _state.value = UiState.Loading
            repo.loadMoreHomeRows()
        }
    }

    class Creator(
        private val repo: CatalogRepository,
        private val target: HomeCatalogTarget,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass.isAssignableFrom(HomeCatalogBrowseViewModel::class.java))
            return HomeCatalogBrowseViewModel(repo, target) as T
        }
    }
}
