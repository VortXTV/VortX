package com.vortx.android.player

import android.content.Context
import android.net.Uri
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.vortx.android.model.Playable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/// The Media3/ExoPlayer [PlayerEngine]: the DV/Atmos-preferred engine AND the runtime fallback when
/// libmpv is unavailable. This is the same ExoPlayer setup the original [PlayerScreen] carried (one
/// [ExoPlayer] built with [DefaultRenderersFactory], rendered through a [PlayerView] as a SurfaceView),
/// now behind the engine-agnostic seam so the chrome does not care which engine is live.
///
/// DV / Atmos: we do NOT hand-pick codecs. [DefaultRenderersFactory] already does the DV -> HEVC/AVC/AV1
/// fallback against the device's real decoders, and [androidx.media3.exoplayer.audio.DefaultAudioSink]
/// negotiates Atmos/E-AC3-JOC/TrueHD passthrough against the device's AudioCapabilities. That is exactly
/// why the router sends DV/Atmos here.
@UnstableApi
class ExoPlayerEngine(context: Context) : PlayerEngine {

    private val appContext = context.applicationContext

    // Built once, survives the engine's lifetime. DefaultRenderersFactory carries the built-in DV codec
    // fallback; we add nothing on top of it (mirrors the original PlayerScreen).
    private val player: ExoPlayer =
        ExoPlayer.Builder(appContext, DefaultRenderersFactory(appContext)).build()

    private val _state = MutableStateFlow(PlayerState())
    override val state: StateFlow<PlayerState> = _state.asStateFlow()

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            publish(
                buffering = playbackState == Player.STATE_BUFFERING,
                ended = playbackState == Player.STATE_ENDED,
            )
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) = publish()
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = publish()
        override fun onTracksChanged(tracks: Tracks) = publish(tracks = tracks)
    }

    init {
        player.addListener(listener)
    }

    /// Snapshot the current player state into an immutable [PlayerState] and republish. `buffering` /
    /// `ended` are passed from the callback that knows them (they aren't cheap to derive otherwise);
    /// tracks are re-read from [player] when a track callback fires.
    private fun publish(
        buffering: Boolean = _state.value.isBuffering,
        ended: Boolean = _state.value.hasEnded,
        tracks: Tracks? = null,
    ) {
        val current = _state.value
        val (audio, subs) = if (tracks != null) mapTracks(tracks) else current.audioTracks to current.subtitleTracks
        _state.value = current.copy(
            positionMs = player.currentPosition.coerceAtLeast(0L),
            durationMs = player.duration.let { if (it == C.TIME_UNSET) 0L else it },
            isPaused = !player.playWhenReady,
            isBuffering = buffering,
            hasEnded = ended,
            audioTracks = audio,
            subtitleTracks = subs,
        )
    }

    /// Map Media3 [Tracks] to the chrome's [PlayerTrack] lists. The engine-native id is the group index
    /// encoded with the track index inside it, so [selectAudioTrack] / [selectSubtitleTrack] can rebuild
    /// the override. Kept simple: one entry per selectable format.
    private fun mapTracks(tracks: Tracks): Pair<List<PlayerTrack>, List<PlayerTrack>> {
        val audio = mutableListOf<PlayerTrack>()
        val subs = mutableListOf<PlayerTrack>()
        tracks.groups.forEachIndexed { groupIndex, group ->
            for (trackIndex in 0 until group.length) {
                val format = group.getTrackFormat(trackIndex)
                val id = encodeTrackId(groupIndex, trackIndex)
                val entry = PlayerTrack(
                    id = id,
                    title = format.label ?: format.language ?: "Track ${audio.size + subs.size + 1}",
                    lang = format.language,
                    selected = group.isTrackSelected(trackIndex),
                )
                when (group.type) {
                    C.TRACK_TYPE_AUDIO -> audio.add(entry)
                    C.TRACK_TYPE_TEXT -> subs.add(entry)
                    else -> Unit
                }
            }
        }
        return audio to subs
    }

    private fun encodeTrackId(group: Int, track: Int): Int = group * 1000 + track

    override fun load(playable: Playable) {
        // Per-stream HTTP headers: some add-ons front CDNs needing a Referer / browser UA. Applied via a
        // DefaultHttpDataSource factory so both the manifest and media requests carry them.
        val mediaSourceFactory = if (playable.headers.isNotEmpty()) {
            val http = DefaultHttpDataSource.Factory().apply {
                setDefaultRequestProperties(playable.headers)
                setAllowCrossProtocolRedirects(true)
            }
            DefaultMediaSourceFactory(appContext).setDataSourceFactory(http)
        } else {
            DefaultMediaSourceFactory(appContext)
        }

        // External sidecar subtitles as side-loaded text tracks on the MediaItem. ExoPlayer needs a
        // concrete, parseable subtitle MIME (unlike mpv, which sniffs the file), so infer it from the
        // URL extension and SKIP a sidecar whose type we can't identify rather than attach an
        // unparseable TEXT_UNKNOWN track. The mpv engine is the primary external-subs path; this is the
        // fallback engine.
        val subtitleConfigs = playable.externalSubtitles.mapNotNull { subUrl ->
            val mime = subtitleMimeFromUrl(subUrl) ?: return@mapNotNull null
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(subUrl))
                .setMimeType(mime)
                .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                .build()
        }
        val item = MediaItem.Builder()
            .setUri(playable.url)
            .setSubtitleConfigurations(subtitleConfigs)
            .build()

        // ExoPlayer has no runtime setMediaSourceFactory (that is a Builder-only API); the factory is
        // applied per-load by creating the MediaSource here. DefaultMediaSourceFactory still handles the
        // sidecar SubtitleConfigurations on the MediaItem (it merges them as side-loaded text tracks).
        player.setMediaSource(mediaSourceFactory.createMediaSource(item))
        player.playWhenReady = true
        if (playable.startPositionMs > 0L) player.seekTo(playable.startPositionMs)
        player.prepare()
    }

    override fun play() { player.play() }
    override fun pause() { player.pause() }
    override fun togglePause() { if (player.isPlaying) player.pause() else player.play() }
    override fun seekTo(positionMs: Long) { player.seekTo(positionMs.coerceAtLeast(0L)) }

    override fun selectAudioTrack(id: Int) = selectTrack(id, C.TRACK_TYPE_AUDIO)

    override fun selectSubtitleTrack(id: Int?) {
        if (id == null) {
            // Disable text rendering entirely (subtitles off).
            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                .build()
            return
        }
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .build()
        selectTrack(id, C.TRACK_TYPE_TEXT)
    }

    private fun selectTrack(id: Int, type: Int) {
        val groupIndex = id / 1000
        val trackIndex = id % 1000
        val group = player.currentTracks.groups.getOrNull(groupIndex) ?: return
        if (group.type != type) return
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, trackIndex))
            .build()
    }

    // External subtitle add + delay: ExoPlayer has no live sub-delay knob equivalent to mpv's, so delay
    // is a no-op on this engine (the chrome hides the control when the mpv engine is not live). Adding a
    // subtitle at runtime re-issues the media item with the extra sidecar appended.
    private var lastPlayable: Playable? = null

    override fun addExternalSubtitle(url: String) {
        val base = lastPlayable ?: return
        val updated = base.copy(externalSubtitles = base.externalSubtitles + url)
        lastPlayable = updated
        val resume = player.currentPosition
        load(updated)
        if (resume > 0L) player.seekTo(resume)
    }

    override fun setSubtitleDelay(seconds: Double) { /* not supported on ExoPlayer; mpv-only control */ }

    /// Map a sidecar subtitle URL to a Media3-parseable MIME by extension, or null when unknown (skip it).
    private fun subtitleMimeFromUrl(url: String): String? {
        val lower = url.substringBefore('?').lowercase()
        return when {
            lower.endsWith(".srt") -> MimeTypes.APPLICATION_SUBRIP
            lower.endsWith(".vtt") -> MimeTypes.TEXT_VTT
            lower.endsWith(".ssa") || lower.endsWith(".ass") -> MimeTypes.TEXT_SSA
            lower.endsWith(".ttml") || lower.endsWith(".dfxp") || lower.endsWith(".xml") -> MimeTypes.APPLICATION_TTML
            else -> null
        }
    }

    override fun onEnterBackground() { player.pause() }
    override fun onEnterForeground() { /* resume is the chrome's choice; keep paused-on-return conservative */ }

    override fun release() {
        player.removeListener(listener)
        player.release()
    }

    @Composable
    override fun VideoSurface(modifier: Modifier, emberArgb: Int) {
        AndroidView(
            modifier = modifier,
            factory = { ctx ->
                PlayerView(ctx).apply {
                    // PlayerView defaults to SURFACE_TYPE_SURFACE_VIEW when built in code (no TextureView
                    // attr): SurfaceView is required for HDR/DV passthrough and avoids TextureView's extra
                    // GPU copy. We hide the built-in controller because VortX draws its own chrome.
                    this.player = this@ExoPlayerEngine.player
                    useController = false
                    setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                    setKeepContentOnPlayerReset(true)
                }
            },
            update = { view -> view.applyEmberScrubber(emberArgb) },
            onRelease = { view -> view.player = null },
        )
    }
}

/// Tint the Media3 controller's scrubber to the ember accent, if the built-in controller is present.
/// Harmless when `useController = false` (the view is absent), so callers can always apply it.
@UnstableApi
private fun PlayerView.applyEmberScrubber(argb: Int) {
    val bar = findViewById<View>(androidx.media3.ui.R.id.exo_progress)
    if (bar is androidx.media3.ui.DefaultTimeBar) {
        bar.setPlayedColor(argb)
        bar.setScrubberColor(argb)
    }
}
