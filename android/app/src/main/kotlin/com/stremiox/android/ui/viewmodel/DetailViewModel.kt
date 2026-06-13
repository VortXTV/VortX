package com.stremiox.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.stremiox.android.data.CatalogRepository
import com.stremiox.android.model.MediaType
import com.stremiox.android.model.MetaDetail
import com.stremiox.android.model.StreamGroup
import com.stremiox.android.ui.UiState
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/// Detail page state: the meta (hero + metadata) and the sources list load independently, mirroring
/// tvOS where the page renders the hero as soon as `meta_details.meta` is ready and the stream
/// groups stream in behind it. Both are [UiState] so a meta-add-on failure and a stream-add-on
/// failure surface separately, exactly as the engine reports them.
class DetailViewModel(
    private val repo: CatalogRepository,
    private val type: MediaType,
    private val id: String,
) : ViewModel() {

    private val _meta = MutableStateFlow<UiState<MetaDetail>>(UiState.Loading)
    val meta: StateFlow<UiState<MetaDetail>> = _meta.asStateFlow()

    private val _streams = MutableStateFlow<UiState<List<StreamGroup>>>(UiState.Loading)
    val streams: StateFlow<UiState<List<StreamGroup>>> = _streams.asStateFlow()

    init {
        viewModelScope.launch {
            // Fan out both add-on calls together; the hero appears the moment meta lands.
            val metaJob = async { repo.meta(type, id) }
            val streamsJob = async { repo.streams(type, id) }
            _meta.value = metaJob.await().toUiState()
            _streams.value = streamsJob.await().toUiState()
        }
    }
}

private fun <T> Result<T>.toUiState(): UiState<T> = fold(
    onSuccess = { UiState.Success(it) },
    onFailure = { UiState.Error(it.message ?: "Something went wrong loading your add-ons.") },
)
