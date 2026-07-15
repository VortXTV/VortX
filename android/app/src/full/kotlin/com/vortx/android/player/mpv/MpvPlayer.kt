package com.vortx.android.player.mpv

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.vortx.android.model.Playable
import com.vortx.android.player.PlayerEngine
import com.vortx.android.player.PlayerState
import com.vortx.android.player.PlayerTrack
import com.vortx.android.player.VideoScaleMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray

/// The libmpv [PlayerEngine] (PRIMARY player, `full` flavor only). Owns one [MPVLib] for its lifetime,
/// renders into an Android [SurfaceView] (the Android analogue of Apple's Metal `wid` layer), applies
/// [MpvConfig.baseOptions] BEFORE `init`, then `loadfile`s the stream. State the chrome needs
/// (position / duration / paused / tracks) is republished from mpv property observers into [state].
///
/// This is the Android mirror of `app/Sources/Player/MPVMetalViewController.swift`: same option set
/// (via [MpvConfig]), same observed properties (`time-pos` / `duration` / `pause` / `track-list`), same
/// per-file header handling (`http-header-fields`), same external-subtitle mount (`sub-add`).
///
/// Fail-soft: constructed only through [com.vortx.android.player.MpvEngineFactory], which returns
/// null when [MPVLib.create] fails; a surface-attach failure additionally flips [surfaceFailed], which
/// the caller reads to demote to ExoPlayer. mpv callbacks arrive on a native worker thread, so [state]
/// is updated with a plain volatile write to a [MutableStateFlow] (thread-safe).
class MpvPlayer private constructor(
    private val mpv: MPVLib,
) : PlayerEngine {

    private val _state = MutableStateFlow(PlayerState())
    override val state: StateFlow<PlayerState> = _state.asStateFlow()

    /// Set true if attaching the render surface ever throws. The caller can consult it to fall back to
    /// ExoPlayer on a hard surface failure instead of showing a black frame.
    @Volatile
    var surfaceFailed: Boolean = false
        private set

    private val observer = object : MPVLib.EventObserver {
        override fun eventProperty(name: String) {
            // Format-less "changed" signal. track-list has no scalar value, so re-read it here.
            if (name == PROP_TRACK_LIST) refreshTracks()
        }

        override fun eventProperty(name: String, value: Long) {
            // No Long-format properties observed today; kept for contract completeness.
        }

        override fun eventProperty(name: String, value: Double) {
            when (name) {
                PROP_TIME_POS -> _state.value = _state.value.copy(positionMs = (value * 1000).toLong().coerceAtLeast(0L))
                PROP_DURATION -> _state.value = _state.value.copy(durationMs = (value * 1000).toLong().coerceAtLeast(0L))
            }
        }

        override fun eventProperty(name: String, value: Boolean) {
            when (name) {
                PROP_PAUSE -> _state.value = _state.value.copy(isPaused = value)
                PROP_PAUSED_FOR_CACHE -> _state.value = _state.value.copy(isBuffering = value)
            }
        }

        override fun eventProperty(name: String, value: String) {
            // track-list is read via the property API (refreshTracks), not delivered as a string here.
        }

        override fun event(id: Int) {
            when (id) {
                MPVLib.Event.END_FILE -> _state.value = _state.value.copy(hasEnded = true)
                MPVLib.Event.FILE_LOADED -> refreshTracks()
                MPVLib.Event.VIDEO_RECONFIG -> refreshTracks()
            }
        }
    }

    init {
        // Apply the shared option set BEFORE init (mpv options are pre-init, exactly like the Swift side
        // sets them before mpv_initialize). Then initialize + observe + register the observer.
        for ((name, value) in MpvConfig.baseOptions) {
            mpv.setOptionString(name, value)
        }
        mpv.init()

        mpv.observeProperty(PROP_TIME_POS, MPVLib.Format.DOUBLE)
        mpv.observeProperty(PROP_DURATION, MPVLib.Format.DOUBLE)
        mpv.observeProperty(PROP_PAUSE, MPVLib.Format.FLAG)
        mpv.observeProperty(PROP_PAUSED_FOR_CACHE, MPVLib.Format.FLAG)
        mpv.observeProperty(PROP_TRACK_LIST, MPVLib.Format.NONE)
        mpv.addObserver(observer)
    }

    override fun load(playable: Playable) {
        _state.value = _state.value.copy(hasEnded = false)

        // Per-stream HTTP headers (behaviorHints.proxyHeaders). Set http-header-fields as a comma-joined
        // "Name: value" list, exactly like the Apple loadFile splits UA/Referer out and joins the rest.
        // Set as a property before loadfile so the request that opens the stream carries them.
        if (playable.headers.isNotEmpty()) {
            val fields = playable.headers.entries.joinToString(",") { "${it.key}: ${it.value}" }
            mpv.setOptionString(OPT_HTTP_HEADER_FIELDS, fields)
        }

        // Device-scaled forward cache cap, applied per file as a property (the Apple loadFile split).
        // A LOCAL (torrent/loopback) stream buffers in the streaming server's own cache, so keep mpv's
        // read-ahead tight; a remote debrid/CDN link keeps the larger buffer for network resilience.
        val readAhead = if (playable.isTorrent || playable.viaStreamingServer) READ_AHEAD_LOCAL else READ_AHEAD_REMOTE
        mpv.setPropertyString(OPT_DEMUXER_MAX_BYTES, readAhead)

        // loadfile as an argv array so a URL containing mpv's list/escape chars is one argument.
        mpv.command(arrayOf("loadfile", playable.url, "replace"))

        // Mount external sidecar subtitles after load (sub-add takes effect on the loaded file).
        for (sub in playable.externalSubtitles) {
            mpv.command(arrayOf("sub-add", sub))
        }

        // Resume position: seek after load. mpv seeks accept an absolute time in seconds.
        if (playable.startPositionMs > 0L) {
            mpv.command(arrayOf("seek", (playable.startPositionMs / 1000.0).toString(), "absolute"))
        }
    }

    override fun play() { mpv.setPropertyString(PROP_PAUSE, "no") }
    override fun pause() { mpv.setPropertyString(PROP_PAUSE, "yes") }
    override fun togglePause() {
        val paused = mpv.getPropertyString(PROP_PAUSE) == "yes"
        mpv.setPropertyString(PROP_PAUSE, if (paused) "no" else "yes")
    }

    override fun seekTo(positionMs: Long) {
        mpv.command(arrayOf("seek", (positionMs.coerceAtLeast(0L) / 1000.0).toString(), "absolute"))
    }

    override fun setPlaybackSpeed(speed: Float) { mpv.setPropertyString(PROP_SPEED, speed.toString()) }

    override fun selectAudioTrack(id: Int) { mpv.setPropertyString(PROP_AID, id.toString()) }

    override fun selectSubtitleTrack(id: Int?) {
        mpv.setPropertyString(PROP_SID, id?.toString() ?: "no")
    }

    override fun addExternalSubtitle(url: String) { mpv.command(arrayOf("sub-add", url)) }

    override fun setSubtitleDelay(seconds: Double) { mpv.setPropertyString(PROP_SUB_DELAY, seconds.toString()) }

    override fun onEnterBackground() {
        // Drop video decode off-screen (matches Apple enterBackground: `vid=no`) and pause.
        pause()
        mpv.setPropertyString(PROP_VID, "no")
    }

    override fun onEnterForeground() {
        mpv.setPropertyString(PROP_VID, "auto")
        play()
    }

    override fun release() {
        mpv.removeObserver(observer)
        mpv.detachSurface()
        mpv.destroy()
    }

    /// Re-read `track-list` (a JSON array of track objects) and republish the audio + subtitle tracks.
    /// Called on file-loaded / video-reconfig / track-list change, mirroring the Apple track observer.
    private fun refreshTracks() {
        val json = mpv.getPropertyString(PROP_TRACK_LIST) ?: return
        val audio = mutableListOf<PlayerTrack>()
        val subs = mutableListOf<PlayerTrack>()
        runCatching {
            val arr = JSONArray(json)
            for (i in 0 until arr.length()) {
                val t = arr.getJSONObject(i)
                val type = t.optString("type")
                val trackId = t.optInt("id", -1)
                if (trackId < 0) continue
                val entry = PlayerTrack(
                    id = trackId,
                    title = t.optString("title").ifEmpty { t.optString("lang").ifEmpty { "$type $trackId" } },
                    lang = t.optString("lang").ifEmpty { null },
                    selected = t.optBoolean("selected", false),
                )
                when (type) {
                    "audio" -> audio.add(entry)
                    "sub" -> subs.add(entry)
                }
            }
        }
        _state.value = _state.value.copy(audioTracks = audio, subtitleTracks = subs)
    }

    @Composable
    override fun VideoSurface(modifier: Modifier, emberArgb: Int, scaleMode: VideoScaleMode) {
        // Host a SurfaceView; attach the Surface to mpv on surfaceCreated, detach on destroyed. This is
        // the Android analogue of Apple pinning the Metal layer as mpv's wid.
        AndroidView(
            modifier = modifier,
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    // Hold the screen awake while the surface is attached (keep-screen-on during playback).
                    keepScreenOn = true
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            runCatching { mpv.attachSurface(holder.surface) }
                                .onFailure { surfaceFailed = true }
                        }

                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                            // mpv reads the new size off the attached Surface; nothing to re-set here.
                        }

                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            runCatching { mpv.detachSurface() }
                        }
                    })
                }
            },
            // Aspect/zoom toggle: FIT keeps the whole frame (panscan 0), ZOOM crops to fill (panscan 1).
            // Re-applied on recompose so the chrome's toggle takes effect without rebuilding the surface.
            update = {
                mpv.setPropertyString(PROP_PANSCAN, if (scaleMode == VideoScaleMode.ZOOM) "1.0" else "0.0")
            },
        )
    }

    companion object {
        // Observed property names (Apple MPVMetalViewController parity).
        private const val PROP_TIME_POS = "time-pos"
        private const val PROP_DURATION = "duration"
        private const val PROP_PAUSE = "pause"
        private const val PROP_PAUSED_FOR_CACHE = "paused-for-cache"
        private const val PROP_TRACK_LIST = "track-list"

        // Runtime property names.
        private const val PROP_AID = "aid"
        private const val PROP_SID = "sid"
        private const val PROP_SUB_DELAY = "sub-delay"
        private const val PROP_VID = "vid"
        private const val PROP_SPEED = "speed"
        private const val PROP_PANSCAN = "panscan"
        private const val OPT_HTTP_HEADER_FIELDS = "http-header-fields"
        private const val OPT_DEMUXER_MAX_BYTES = "demuxer-max-bytes"

        // Per-file read-ahead: local torrent/loopback vs remote debrid/CDN (mirrors Apple loadFile).
        private const val READ_AHEAD_LOCAL = "96MiB"
        private const val READ_AHEAD_REMOTE = "128MiB"

        /// Build an [MpvPlayer], applying config + init. Returns null if [MPVLib.create] fails (missing
        /// native `.so` for the running ABI / OOM), so [com.vortx.android.player.MpvEngineFactory]
        /// can fall back to ExoPlayer. Never throws.
        fun create(context: Context): MpvPlayer? {
            val lib = MPVLib.create(context) ?: return null
            return runCatching { MpvPlayer(lib) }.getOrElse {
                runCatching { lib.destroy() }
                null
            }
        }
    }
}
