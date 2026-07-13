package com.stremiox.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.stremiox.android.data.CatalogRepository
import com.stremiox.android.model.Episode
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
///
/// S05: for a series, the sources fan-out is scoped to the RESUME/PLAY target episode from the
/// start (ported from `SourcesTV/DetailView.swift`'s `seriesPrimaryEpisode` -- see [primaryEpisode]),
/// not a bare "first episode" guess, so the hero Watch/Resume button plays the right thing on first
/// load. Watched-state and library mutations dispatch through [repo] and swap [meta] with the
/// engine's freshly re-pulled snapshot, so ticks/progress/the library chip flip live with no
/// separate reload.
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

    /// The episode whose sources are currently shown (series only). null = title-level sources (a movie,
    /// or before meta/episodes have loaded). The screen highlights the selected episode and passes
    /// its id back through [selectEpisode].
    private val _selectedEpisodeId = MutableStateFlow<String?>(null)
    val selectedEpisodeId: StateFlow<String?> = _selectedEpisodeId.asStateFlow()

    /// The season the episode list is currently browsing (series only). Seeded once from
    /// [primaryEpisode]'s season on first load (mirrors tvOS `applyPreferredSeason`'s `initialSeason ??
    /// firstUnwatchedSeason ?? …`); a manual tap on a season chip overrides it via [selectSeason] and is
    /// never clobbered afterward (no re-seed-on-data-arrival here since Android loads the full episode
    /// list in one meta response, unlike tvOS's late-streaming videos array).
    private val _selectedSeason = MutableStateFlow<Int?>(null)
    val selectedSeason: StateFlow<Int?> = _selectedSeason.asStateFlow()

    /// Set (briefly) when a watched/library mutation fails, so the screen can surface it without a
    /// second [UiState.Error] layer over the whole page. The screen is expected to read-and-clear it
    /// (call [clearMutationError]) once shown.
    private val _mutationError = MutableStateFlow<String?>(null)
    val mutationError: StateFlow<String?> = _mutationError.asStateFlow()

    /// Group-1 reactivity (see [CatalogRepository.ctxUpdates]): the Saved chip and per-episode ticks
    /// must reflect a library/watched change made ANYWHERE -- the Library grid's trash badge, a poster
    /// long-press elsewhere, another Detail instance in the backstack -- not only this ViewModel's own
    /// [toggleLibrary]/[setWatched] calls (device finding 1b: "Detail's Saved chip stays stale until an
    /// app restart"). [repo.peekMeta] is a pure local snapshot (no re-dispatch), so this is cheap enough
    /// to run on every tick; it only replaces [_meta] once the initial load (below) has already
    /// succeeded, so it can never race ahead of or clobber the first load.
    init {
        viewModelScope.launch {
            repo.ctxUpdates().collect {
                if (_meta.value !is UiState.Success) return@collect
                repo.peekMeta(type, id)?.let { fresh -> _meta.value = UiState.Success(fresh) }
            }
        }
        viewModelScope.launch {
            if (type == MediaType.SERIES) {
                // A series' hero Watch/Resume target depends on which episode + watched state the meta
                // carries, so meta must land before the sources fan-out is scoped -- unlike a movie,
                // this can't run in parallel with the (title-level) streams call.
                _meta.value = repo.meta(type, id).toUiState()
                val detail = (_meta.value as? UiState.Success)?.data
                val primary = detail?.let { primaryEpisodeOf(it) }
                if (primary != null) {
                    _selectedSeason.value = primary.first.season
                    selectEpisode(primary.first.id)
                } else {
                    _streams.value = repo.streams(type, id).toUiState()
                }
            } else {
                // Movie: meta and title-level sources are independent, so fan them out together --
                // the hero appears the moment meta lands, exactly as before.
                val metaJob = async { repo.meta(type, id) }
                val streamsJob = async { repo.streams(type, id) }
                _meta.value = metaJob.await().toUiState()
                _streams.value = streamsJob.await().toUiState()
            }
        }
    }

    /// Reload sources scoped to a series [episodeId] (the engine `CoreVideo.id`). Re-drives the sources
    /// list into Loading then its result, so the section shows progress while the chosen episode's
    /// stream add-ons fan out. A no-op if the same episode is re-selected. Movies never call this.
    fun selectEpisode(episodeId: String) {
        if (_selectedEpisodeId.value == episodeId) return
        _selectedEpisodeId.value = episodeId
        _streams.value = UiState.Loading
        viewModelScope.launch {
            _streams.value = repo.streams(type, id, episodeId).toUiState()
        }
    }

    /// Browse a different season's episode list (does NOT touch the sources selection -- the hero keeps
    /// showing whichever episode's sources were last chosen via [selectEpisode]).
    fun selectSeason(season: Int) {
        _selectedSeason.value = season
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

    fun clearMutationError() {
        _mutationError.value = null
    }

    // ---- S05: resume targeting ----

    /// The hero Watch/Resume target for a series -- the in-progress episode (a saved position, not yet
    /// watched) if one exists, else the first unwatched episode, else the first episode. Ported from
    /// `SourcesTV/DetailView.swift`'s `seriesPrimaryEpisode`. Returns null for a movie or before meta
    /// has loaded. The `Boolean` is true for a genuine RESUME (append the saved timecode / label
    /// "Resume"), false for a fresh "Play".
    fun primaryEpisode(): Pair<Episode, Boolean>? {
        val detail = (_meta.value as? UiState.Success)?.data ?: return null
        return primaryEpisodeOf(detail)
    }

    private fun primaryEpisodeOf(detail: MetaDetail): Pair<Episode, Boolean>? {
        if (detail.videos.isEmpty()) return null
        val sorted = sortedEpisodes(detail.videos)
        val lib = detail.libraryItem
        if (lib != null && lib.timeOffsetMs > 0 && lib.videoId != null) {
            val resumeVideo = sorted.firstOrNull { it.id == lib.videoId }
            if (resumeVideo != null && resumeVideo.id !in detail.watchedVideoIds) return resumeVideo to true
        }
        val next = sorted.firstOrNull { it.id !in detail.watchedVideoIds }
        if (next != null) return next to false
        return sorted.first() to false
    }

    // ---- S05: watched-state + library mutations ----
    //
    // Every mutation swaps [_meta] with the engine's freshly re-pulled [MetaDetail]
    // (see [CatalogRepository]'s S05 doc comment) so ticks/progress/the library chip update live; a
    // failure is surfaced via [mutationError] instead of clobbering the loaded page with [UiState.Error].

    /// Mark the whole title (movie, or every episode of a series) watched/unwatched.
    ///
    /// ROOT CAUSE of the device-round "first invocation did nothing" bug: the engine's aggregate
    /// `MarkAsWatched(bool)` action (see `LibraryItem::mark_as_watched` in the vendored stremio-core
    /// crate, `types/library/library_item.rs`) only flips `timesWatched`/`lastWatched` on the library
    /// item -- it NEVER touches the per-video `WatchedBitField` a series' episode ticks
    /// ([MetaDetail.watchedVideoIds]) are derived from. That bitfield is written ONLY by
    /// `MarkVideoAsWatched`/`MarkSeasonAsWatched`. So dispatching `MarkAsWatched(true)` on a series
    /// silently updated the (invisible) aggregate flag while every episode tick stayed exactly as it
    /// was -- indistinguishable from "did nothing" to the user watching the episode list. Unwatching
    /// already iterated per-video (see the loop below) for the same reason Apple's `CoreBridge.markWatched`
    /// documents, so only the `true` branch was affected.
    ///
    /// Fix: BOTH directions iterate every video, every season (sorted, deterministic order -- not the
    /// engine's raw JSON order, which is not guaranteed stable) via `MarkVideoAsWatched`, so every tick
    /// updates the instant this returns; then re-dispatch the aggregate `MarkAsWatched` too (best-effort)
    /// so the movie-style `timesWatched`/resume-target metadata the hero button reads stays in sync. Each
    /// dispatch is a synchronous engine call immediately re-read (see [CatalogRepository]'s S05 doc
    /// comment), so the loop can never race itself -- the final [applyMutation] snapshot already reflects
    /// every prior step in the same sequence.
    fun setWatched(isWatched: Boolean) {
        val current = (_meta.value as? UiState.Success)?.data ?: return
        viewModelScope.launch {
            val result = if (current.videos.isEmpty()) {
                repo.setWatched(type, id, isWatched)
            } else {
                var last: Result<MetaDetail> = Result.success(current)
                for (video in sortedEpisodes(current.videos)) {
                    last = repo.setVideoWatched(
                        type = type,
                        id = id,
                        videoId = video.id,
                        season = video.season.takeIf { it > 0 },
                        episode = video.episode.takeIf { it > 0 },
                        isWatched = isWatched,
                    )
                    if (last.isFailure) break
                }
                if (last.isSuccess) last = repo.setWatched(type, id, isWatched)
                last
            }
            applyMutation(result)
        }
    }

    /// Mark every episode of [season] watched/unwatched.
    fun setSeasonWatched(season: Int, isWatched: Boolean) {
        viewModelScope.launch {
            applyMutation(repo.setSeasonWatched(type, id, season, isWatched))
        }
    }

    /// Mark one episode watched/unwatched (the per-episode long-press menu / checkmark toggle).
    fun setVideoWatched(episode: Episode, isWatched: Boolean) {
        viewModelScope.launch {
            applyMutation(
                repo.setVideoWatched(
                    type = type,
                    id = id,
                    videoId = episode.id,
                    season = episode.season.takeIf { it > 0 },
                    episode = episode.episode.takeIf { it > 0 },
                    isWatched = isWatched,
                ),
            )
        }
    }

    /// Toggle the open title's Add-to-Library state, reading the current state off the just-loaded
    /// [MetaDetail.libraryItem] so the chip always reflects the engine's own truth.
    fun toggleLibrary() {
        val current = (_meta.value as? UiState.Success)?.data ?: return
        val inLibrary = current.libraryItem?.savedToLibrary == true
        viewModelScope.launch {
            val result = if (inLibrary) {
                repo.removeFromLibrary(type, id)
            } else {
                repo.addToLibrary(type, id, current.name, current.poster)
            }
            applyMutation(result)
        }
    }

    private fun applyMutation(result: Result<MetaDetail>) {
        result.fold(
            onSuccess = { _meta.value = UiState.Success(it) },
            onFailure = { _mutationError.value = it.message ?: "Couldn't save that change." },
        )
    }

    private fun sortedEpisodes(videos: List<Episode>): List<Episode> =
        videos.sortedWith(compareBy({ it.season }, { it.episode }, { it.id }))
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
