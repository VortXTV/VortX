package com.vortx.android.player

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import kotlinx.coroutines.flow.StateFlow

/// The engine-agnostic seam the Compose chrome drives. Both players (libmpv and ExoPlayer) implement
/// this, so [PlayerChrome] and [PlayerScreen] talk to ONE interface and never branch on which engine is
/// live. It mirrors the Apple player's split: the SwiftUI chrome renders [PlayerState] and calls
/// transport methods, while the concrete engine owns the surface + decode.
///
/// Contract:
///   - [state] is a hot [StateFlow] the chrome collects (position/duration/paused/tracks/ended). The
///     engine republishes it from its own property observers on its own thread; the chrome never reads
///     the engine directly.
///   - [VideoSurface] is the engine's render surface, hosted via Compose `AndroidView`. mpv attaches an
///     Android `Surface` from a `SurfaceView`; ExoPlayer hosts a Media3 `PlayerView` (SurfaceView mode).
///   - transport methods are idempotent and safe to call before the first frame; the engine buffers or
///     no-ops until it is ready.
///
/// Fail-soft: [MpvEngineFactory] can return null (mpv init/attach failure, or the `play` flavor that
/// ships no libmpv), and [PlayerEngineRouter] then hands the stream to the ExoPlayer engine so playback
/// degrades to Media3 instead of a black crash.
interface PlayerEngine {

    /// The transport + track state the chrome renders. Cold-start value is [PlayerState] defaults
    /// (position 0, duration 0, paused false, no tracks) until the engine loads the file.
    val state: StateFlow<PlayerState>

    /// Begin (or replace) playback of [playable]. Applies per-stream headers and mounts external
    /// subtitles. Safe to call once per engine instance for the player's lifetime.
    fun load(playable: com.vortx.android.model.Playable)

    /// Toggle / set transport. [seekTo] takes an absolute position in milliseconds.
    fun play()
    fun pause()
    fun togglePause()
    fun seekTo(positionMs: Long)

    /// Set the playback speed multiplier (1.0 = normal). Both engines support this natively (ExoPlayer's
    /// `setPlaybackSpeed`, mpv's `speed` property); the chrome offers a small set of presets.
    fun setPlaybackSpeed(speed: Float)

    /// Select a track by its engine-native id (from [PlayerState.audioTracks] / [subtitleTracks]).
    /// `null` disables the track (subtitles off). No-op for an unknown id.
    fun selectAudioTrack(id: Int)
    fun selectSubtitleTrack(id: Int?)

    /// Mount an additional external subtitle file at runtime and offset its timing (seconds, +/-).
    fun addExternalSubtitle(url: String)
    fun setSubtitleDelay(seconds: Double)

    /// Offset the AUDIO track's timing relative to video (seconds, +/-) to fix a lip-sync drift. mpv's
    /// `audio-delay`. ExoPlayer has no live audio-delay knob, so its implementation is a documented no-op
    /// (the chrome hides the control when the mpv engine is not live). Mirrors Apple `setAudioDelay`.
    fun setAudioDelay(seconds: Double) {}

    /// Apply the persisted [SubtitleStyle] to the live engine (mpv `sub-*` properties / ExoPlayer
    /// `SubtitleView` style). Both concrete engines override; the default is a no-op for any future engine
    /// that renders no subtitles. Mirrors Apple `applySubtitleStyle`.
    fun applySubtitleStyle() {}

    /// Apply the device's [AudioOutputMode] (auto/stereo/surround/passthrough). The libmpv engine drives
    /// its AO channel/passthrough policy; ExoPlayer's `DefaultAudioSink` self-negotiates and exposes no
    /// runtime force, so its implementation is a documented no-op. Mirrors Apple `setAudioOutputMode`.
    fun setAudioOutputMode(mode: AudioOutputMode) {}

    /// Live audio volume, 0..100, and mute without losing the level. Both engines override (mpv `volume`/
    /// `mute`; ExoPlayer `player.volume` 0..1). Mirrors Apple `setVolume` / `setMuted`.
    fun setVolume(volume0to100: Double) {}
    fun setMuted(muted: Boolean) {}

    /// The container's chapter markers, for a chapter picker. mpv reads `chapter-list`; ExoPlayer has no
    /// generic chapter API, so it returns empty (a documented no-op). Mirrors Apple `chapters`.
    fun chapters(): List<PlayerChapter> = emptyList()

    /// A label -> value list of live playback stats (resolution, codecs, bitrate, hwdec) for a stats
    /// overlay. Both engines override with what their API exposes. Mirrors Apple `playbackStats`.
    fun playbackStats(): List<Pair<String, String>> = emptyList()

    /// Grab the CURRENT video frame as JPEG bytes, downscaled so its width is at most [maxWidth]. This is
    /// the capture primitive the community-trickplay pipeline feeds
    /// ([com.vortx.android.trickplay.TrickplaySession]); it is the Android analogue of Apple's
    /// `PlayerEngine.captureFrameJPEGData(maxWidth:completion:)`, re-shaped as a `suspend` function
    /// because every Android caller is already a coroutine (Apple needs a completion handler only because
    /// its libmpv grab is serviced asynchronously on the Metal VO thread).
    ///
    /// Returns null when this engine cannot read the frame back, which is NOT an error and must stay
    /// fail-soft: the session simply captures nothing and the title stays a fetch-only consumer of the
    /// community pool. The default is null so any future engine is safe by construction.
    ///
    /// PLATFORM REALITY, and why this is not symmetric with Apple. Apple reads pixels back in-process on
    /// BOTH engines (a Metal texture blit off mpv's VO; `AVPlayerItemVideoOutput.copyPixelBuffer` off
    /// AVPlayer). Neither Android engine has an equivalent that survives the DV mandate:
    ///   - [ExoPlayerEngine] renders through a Media3 `PlayerView` in SURFACE_TYPE_SURFACE_VIEW mode. A
    ///     `SurfaceView`'s buffers are owned by the compositor and are NOT readable by the app; the only
    ///     readback route is `TextureView`, which the DV/HDR passthrough path explicitly rules out. So it
    ///     returns null (a documented no-op, like its `setAudioDelay` / `setAudioOutputMode`).
    ///   - The libmpv engine CAN ask mpv to write a screenshot, so it implements this. See
    ///     `MpvPlayer.captureFrameJpeg` for the `hwdec=mediacodec` caveat that governs whether the grab
    ///     actually yields a real frame on a given device.
    suspend fun captureFrameJpeg(maxWidth: Int): ByteArray? = null

    /// Lifecycle. [onEnterBackground] drops video decode (and, per policy, pauses); [onEnterForeground]
    /// resumes. [release] tears the engine down; the instance is unusable afterward.
    fun onEnterBackground()
    fun onEnterForeground()
    fun release()

    /// The engine's video surface, hosted by the caller's `AndroidView`. Implementations own surface
    /// attach/detach against their lifecycle. [emberArgb] lets an engine tint any built-in chrome
    /// (ExoPlayer's scrubber) to the VortX accent; mpv ignores it (VortX draws its own chrome).
    /// [scaleMode] is re-applied on recomposition (ExoPlayer's `resizeMode`, mpv's `panscan`) so the
    /// chrome's aspect/zoom toggle takes effect without rebuilding the surface.
    @Composable
    fun VideoSurface(modifier: Modifier, emberArgb: Int, scaleMode: VideoScaleMode)
}

/// How the video fills the surface: [FIT] letterboxes to preserve the whole frame (default), [ZOOM]
/// crops to fill the screen (fill/zoom). The chrome's aspect toggle cycles between them.
enum class VideoScaleMode { FIT, ZOOM }

/// A single audio or subtitle track the chrome can offer. `id` is the engine-native selector passed
/// back to [PlayerEngine.selectAudioTrack] / [selectSubtitleTrack]; `title` / `lang` are for display.
data class PlayerTrack(
    val id: Int,
    val title: String,
    val lang: String? = null,
    val selected: Boolean = false,
    /// The container's FORCED disposition (mpv track-list `forced` / ExoPlayer `SELECTION_FLAG_FORCED`).
    /// [TrackSelector] keys the forced-subtitle policy off this flag, not the title text, so real forced
    /// tracks auto-enable even when they carry no "forced" label. Mirrors Apple `MPVTrack.forced`.
    val forced: Boolean = false,
)

/// A single chapter marker from the container, for the chrome's chapter picker. `startMs` is the chapter
/// start in milliseconds. Mirrors Apple `MPVChapter`.
data class PlayerChapter(
    val title: String,
    val startMs: Long,
)

/// The immutable transport + track snapshot the chrome renders. The engine copies-on-write and
/// republishes through [PlayerEngine.state]; the chrome never mutates it.
data class PlayerState(
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val isPaused: Boolean = false,
    val isBuffering: Boolean = false,
    val hasEnded: Boolean = false,
    /// Set when the live engine reports an unrecoverable playback error (ExoPlayer's `onPlayerError`),
    /// so the chrome can offer a return-to-sources fallback instead of a dead black frame.
    val hasError: Boolean = false,
    val audioTracks: List<PlayerTrack> = emptyList(),
    val subtitleTracks: List<PlayerTrack> = emptyList(),
)

/// Builds the libmpv [PlayerEngine], or returns null when mpv is unavailable. This is the FLAVOR SEAM,
/// declared PER FLAVOR (never in `src/main`) so exactly one definition is on the classpath per variant
/// and the two never collide:
///   - `src/full/.../MpvEngineFactory.kt` builds the real `MpvPlayer`, catching any native create /
///     surface-attach failure and returning null so the router falls back to ExoPlayer.
///   - `src/play/.../MpvEngineFactory.kt` always returns null (that flavor ships no libmpv AAR), so the
///     `play` build compiles and always runs on ExoPlayer.
/// Kotlin resolves the flavor-specific copy at compile time, the JVM analogue of Apple's `#if` engine
/// gating. The contract both copies satisfy:
///
///     object MpvEngineFactory { fun create(context: android.content.Context): PlayerEngine? }
///
/// It intentionally does NOT live here: a `src/main` copy plus a flavor copy is a duplicate-class build
/// error (the flavor source set is additive to main, not an override of a same-named declaration).
