package com.vortx.android.player

import android.content.Context
import android.graphics.Color as AndroidColor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
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

        // Surface an unrecoverable decode/network error so the chrome can fall back to the ranked source
        // list instead of leaving a dead black frame (error-to-sources fallback).
        override fun onPlayerError(error: PlaybackException) {
            _state.value = _state.value.copy(hasError = true)
        }
    }

    // ExoPlayer pushes position only on discrete callbacks, never per second, so a 1s ticker republishes
    // while playing -- keeps the chrome scrubber live AND gives the progress reporter a fresh position.
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ticker = object : Runnable {
        override fun run() {
            if (player.isPlaying) publish()
            mainHandler.postDelayed(this, POSITION_POLL_MS)
        }
    }

    init {
        player.addListener(listener)
        mainHandler.postDelayed(ticker, POSITION_POLL_MS)
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
                    // Carry the container's forced disposition so TrackSelector's forced-subtitle policy
                    // can key off the flag (not the title text), matching the mpv engine.
                    forced = (format.selectionFlags and C.SELECTION_FLAG_FORCED) != 0,
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
    override fun setPlaybackSpeed(speed: Float) { player.setPlaybackSpeed(speed.coerceIn(MIN_SPEED, MAX_SPEED)) }

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

    // The hosted PlayerView, kept so [applySubtitleStyle] can restyle its SubtitleView after creation.
    private var playerView: PlayerView? = null

    // Volume level saved across a mute so unmute restores it (ExoPlayer has one volume, no separate mute).
    private var preMuteVolume: Float = 1f

    override fun addExternalSubtitle(url: String) {
        val base = lastPlayable ?: return
        val updated = base.copy(externalSubtitles = base.externalSubtitles + url)
        lastPlayable = updated
        val resume = player.currentPosition
        load(updated)
        if (resume > 0L) player.seekTo(resume)
    }

    override fun setSubtitleDelay(seconds: Double) { /* not supported on ExoPlayer; mpv-only control */ }

    // Documented no-op: ExoPlayer exposes no live audio-delay (audio/video sync is the renderer's job),
    // so there is nothing to drive here. The mpv engine implements this via `audio-delay`.
    override fun setAudioDelay(seconds: Double) { /* not supported on ExoPlayer; mpv-only control */ }

    // Documented no-op: DefaultAudioSink negotiates channel layout / Atmos passthrough against the device's
    // AudioCapabilities on its own and offers no runtime force. The router already routes Atmos/passthrough
    // streams here precisely for that auto-negotiation, so there is nothing to override. The mpv engine
    // implements the manual auto/stereo/surround/passthrough control.
    override fun setAudioOutputMode(mode: AudioOutputMode) { /* auto-negotiated by DefaultAudioSink */ }

    // Documented no-op: Media3 has no generic container-chapter API, so there are no chapters to expose.
    // The mpv engine reads `chapter-list`.
    override fun chapters(): List<PlayerChapter> = emptyList()

    override fun setVolume(volume0to100: Double) {
        player.volume = (volume0to100 / 100.0).toFloat().coerceIn(0f, 1f)
    }

    override fun setMuted(muted: Boolean) {
        if (muted) {
            preMuteVolume = player.volume
            player.volume = 0f
        } else {
            player.volume = preMuteVolume
        }
    }

    // Apply the persisted subtitle appearance to the hosted SubtitleView. `setApplyEmbeddedStyles(false)`
    // makes our style win over the file's own cue styling, matching mpv where VortX's sub-* options
    // override. No-op until the surface exists (re-applied from the AndroidView factory on creation).
    override fun applySubtitleStyle() {
        val view = playerView?.subtitleView ?: return
        val style = SubtitleStyle.current(appContext)
        val edgeType =
            if (style.isModern) CaptionStyleCompat.EDGE_TYPE_DROP_SHADOW else CaptionStyleCompat.EDGE_TYPE_OUTLINE
        view.setApplyEmbeddedStyles(false)
        view.setStyle(
            CaptionStyleCompat(
                style.foregroundColorArgb,
                style.backgroundColorArgb,
                AndroidColor.TRANSPARENT, // window (full-width) background stays clear; box is the text bg
                edgeType,
                AndroidColor.BLACK,
                null,
            ),
        )
        view.setFractionalTextSize(style.exoTextSizeFraction)
    }

    // Live playback stats from the current formats (ExoPlayer's equivalent of mpv's property reads): only
    // the fields Media3 surfaces. Empty entries are dropped so the overlay shows just what is known.
    override fun playbackStats(): List<Pair<String, String>> {
        val stats = mutableListOf<Pair<String, String>>()
        player.videoFormat?.let { v: Format ->
            if (v.width > 0 && v.height > 0) stats += "Resolution" to "${v.width}x${v.height}"
            v.codecs?.let { stats += "Video codec" to it }
            if (v.frameRate > 0f) stats += "Frame rate" to String.format("%.3f fps", v.frameRate)
            if (v.bitrate != Format.NO_VALUE) stats += "Video bitrate" to "${v.bitrate / 1000} kbps"
        }
        player.audioFormat?.let { a: Format ->
            a.codecs?.let { stats += "Audio codec" to it }
            if (a.channelCount != Format.NO_VALUE) stats += "Channels" to a.channelCount.toString()
            if (a.sampleRate != Format.NO_VALUE) stats += "Sample rate" to "${a.sampleRate} Hz"
        }
        return stats
    }

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
        mainHandler.removeCallbacks(ticker)
        player.removeListener(listener)
        player.release()
    }

    @Composable
    override fun VideoSurface(modifier: Modifier, emberArgb: Int, scaleMode: VideoScaleMode) {
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
                    resizeMode = scaleMode.toResizeMode()
                    setKeepContentOnPlayerReset(true)
                    // Hold the screen awake while the surface is attached (keep-screen-on during playback).
                    keepScreenOn = true
                    this@ExoPlayerEngine.playerView = this
                    // Apply the persisted subtitle appearance now the SubtitleView exists.
                    this@ExoPlayerEngine.applySubtitleStyle()
                }
            },
            update = { view ->
                view.applyEmberScrubber(emberArgb)
                view.resizeMode = scaleMode.toResizeMode()
            },
            onRelease = { view ->
                view.player = null
                if (playerView === view) playerView = null
            },
        )
    }

    private fun VideoScaleMode.toResizeMode(): Int = when (this) {
        VideoScaleMode.FIT -> AspectRatioFrameLayout.RESIZE_MODE_FIT
        VideoScaleMode.ZOOM -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
    }

    private companion object {
        const val POSITION_POLL_MS = 1_000L
        const val MIN_SPEED = 0.25f
        const val MAX_SPEED = 4.0f
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
