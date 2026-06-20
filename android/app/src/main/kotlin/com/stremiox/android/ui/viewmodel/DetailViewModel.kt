package com.stremiox.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.stremiox.android.data.CatalogRepository
import com.stremiox.android.model.MediaType
import com.stremiox.android.model.MetaDetail
import com.stremiox.android.model.Playable
import com.stremiox.android.model.StreamGroup
import com.stremiox.android.model.StreamSource
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

    /// The current playback request. null means "not playing"; a [Playable] means the player should be
    /// shown. The screen observes this and routes to the player; [clearPlayback] returns here on back.
    private val _playback = MutableStateFlow<Playback>(Playback.Idle)
    val playback: StateFlow<Playback> = _playback.asStateFlow()

    init {
        viewModelScope.launch {
            // Fan out both add-on calls together; the hero appears the moment meta lands.
            val metaJob = async { repo.meta(type, id) }
            val streamsJob = async { repo.streams(type, id) }
            _meta.value = metaJob.await().toUiState()
            _streams.value = streamsJob.await().toUiState()
        }
    }

    /// Resolve a chosen source to a [Playable] and request playback. Drives a Resolving -> Ready /
    /// Failed transition so the row can show progress and a resolve failure surfaces instead of
    /// silently doing nothing.
    fun play(source: StreamSource) {
        if (_playback.value is Playback.Resolving) return
        _playback.value = Playback.Resolving
        viewModelScope.launch {
            _playback.value = repo.resolve(source).fold(
                onSuccess = { Playback.Ready(it) },
                onFailure = { Playback.Failed(it.message ?: "Could not start this source.") },
            )
        }
    }

    /// The best source (first stream of the first group, which the engine returns best-first), for the
    /// hero Watch button. Returns null when no sources resolved yet.
    fun bestSource(): StreamSource? =
        (_streams.value as? UiState.Success)?.data?.firstOrNull()?.streams?.firstOrNull()

    fun clearPlayback() {
        _playback.value = Playback.Idle
    }
}

/// Playback request state for the detail page. Resolving covers the engine round-trip (streaming
/// server hand-off / debrid unlock) so the UI shows progress rather than freezing.
sealed interface Playback {
    data object Idle : Playback
    data object Resolving : Playback
    data class Ready(val playable: Playable) : Playback
    data class Failed(val message: String) : Playback
}

private fun <T> Result<T>.toUiState(): UiState<T> = fold(
    onSuccess = { UiState.Success(it) },
    onFailure = { UiState.Error(it.message ?: "Something went wrong loading your add-ons.") },
)
