package com.vortx.android.player.mpv

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.vortx.android.model.Playable
import com.vortx.android.player.AudioOutputMode
import com.vortx.android.player.DiskCacheSetting
import com.vortx.android.player.PerformanceMode
import com.vortx.android.player.PlayerChapter
import com.vortx.android.player.PlayerEngine
import com.vortx.android.player.PlayerState
import com.vortx.android.player.PlayerTrack
import com.vortx.android.player.SubtitleStyle
import com.vortx.android.player.VideoScaleMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.UUID

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
    private val appContext: Context,
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
        // Persisted player-settings applied pre-init (mirrors Apple applying SubtitleStyle/AudioOutputMode
        // options and the disk-cache toggle during setupMpv). All default to a no-op / today's behavior:
        // SubtitleStyle -> Modern defaults, AudioOutputMode -> Auto, DiskCacheSetting -> OFF (empty list).
        for ((name, value) in MpvConfig.diskCacheOptions(appContext)) {
            mpv.setOptionString(name, value)
        }
        for ((name, value) in SubtitleStyle.current(appContext).mpvOptions()) {
            mpv.setOptionString(name, value)
        }
        for ((name, value) in AudioOutputMode.current(appContext).mpvOptions()) {
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

        // Trailer UA/URL lockstep (mirrors Apple loadFile's googlevideo branch). A client-resolved YouTube
        // trailer's [url]/[audioUrl] were minted by a specific InnerTube client (ANDROID_VR / ANDROID / IOS /
        // TVHTML5); googlevideo 403s a replay with any other UA. So OVERRIDE mpv's default UA with the minting
        // UA BEFORE loadfile (it applies to the video URL AND the audio-add sidecar this load opens), and clear
        // any per-stream header set so a reused engine instance never bleeds a prior stream's UA/Referer onto
        // the trailer. Non-trailer streams (userAgent == null) keep the base [MpvConfig.USER_AGENT]. When the
        // legs are already proxied to 127.0.0.1 this UA simply will not match that host (the proxy replays the
        // real UA upstream itself), exactly as on Apple; it is the fallback for an unproxied raw googlevideo URL.
        playable.userAgent?.let { ua ->
            mpv.setPropertyString(PROP_USER_AGENT, ua)
            mpv.setPropertyString(OPT_HTTP_HEADER_FIELDS, "")
        }

        // Device-scaled forward cache cap, applied per file as a property (the Apple loadFile split).
        //   - Disk cache ON: hand mpv the large, free-disk-clamped budget so the on-disk cache actually
        //     fills (the cache-on-disk/cache-dir options are already armed pre-init). Recomputed per file
        //     so it always reflects CURRENT free space (DiskCacheSetting's UNLIMITED safety).
        //   - Disk cache OFF: a LOCAL (torrent/loopback) stream buffers in the streaming server's own
        //     cache, so keep mpv's read-ahead tight; a remote debrid/CDN link keeps the larger buffer for
        //     network resilience; a constrained device stays tight even for remote (PerformanceMode hook).
        val reduced = PerformanceMode.isReduced(appContext)
        val readAhead = when {
            DiskCacheSetting.diskCacheEnabled(appContext) ->
                DiskCacheSetting.resolvedMaxBytes(appContext, reduced).toString()
            // A trailer is a short clip (proxied to 127.0.0.1, or the small remote worker host), so it takes
            // the tight local read-ahead too -- the big remote buffer just wastes RAM on it. Mirrors Apple
            // loadFile giving the trailer host the small read-ahead.
            playable.isTorrent || playable.viaStreamingServer || playable.isTrailer -> READ_AHEAD_LOCAL
            reduced -> READ_AHEAD_LOCAL
            else -> READ_AHEAD_REMOTE
        }
        mpv.setPropertyString(OPT_DEMUXER_MAX_BYTES, readAhead)

        // loadfile as an argv array so a URL containing mpv's list/escape chars is one argument.
        mpv.command(arrayOf("loadfile", playable.url, "replace"))

        // yt-direct adaptive trailer: mount the separate audio-only leg so mpv merges it with the video-only
        // file (the Android analogue of Apple's `--audio-files`/`change-list append`). argv form so a URL with
        // mpv's list/escape chars stays ONE argument. `audio-add` defaults to selecting the added track. Only a
        // client-resolved adaptive trailer carries [audioUrl]; a muxed trailer / worker fallback / any other
        // stream has none and plays as a single file.
        playable.audioUrl?.let { audio ->
            mpv.command(arrayOf("audio-add", audio))
        }

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

    override fun setAudioDelay(seconds: Double) { mpv.setPropertyString(PROP_AUDIO_DELAY, seconds.toString()) }

    override fun setVolume(volume0to100: Double) {
        mpv.setPropertyString(PROP_VOLUME, volume0to100.coerceIn(0.0, 100.0).toString())
    }

    override fun setMuted(muted: Boolean) { mpv.setPropertyString(PROP_MUTE, if (muted) "yes" else "no") }

    /// Re-apply the persisted subtitle appearance live (mpv `sub-*` properties). The same values are set as
    /// options pre-init; this overwrites them for a live Settings change. Mirrors Apple `applySubtitleStyle`.
    override fun applySubtitleStyle() {
        for ((name, value) in SubtitleStyle.current(appContext).mpvOptions()) {
            mpv.setPropertyString(name, value)
        }
    }

    /// Apply the device audio-output mode live. `audio-channels` / `audio-spdif` are best-effort mid-file
    /// (mpv may only fully honor them on the next AO (re)open); applied as options pre-init for the reliable
    /// path. Mirrors Apple `setAudioOutputMode`.
    override fun setAudioOutputMode(mode: AudioOutputMode) {
        for ((name, value) in mode.mpvOptions()) {
            mpv.setPropertyString(name, value)
        }
    }

    /// The container's chapters, read from mpv's `chapter-list` (count + per-index title/time). Empty when
    /// the file carries no chapters. Mirrors Apple `chapters()`.
    override fun chapters(): List<PlayerChapter> {
        val count = mpv.getPropertyInt(PROP_CHAPTER_COUNT) ?: return emptyList()
        val out = ArrayList<PlayerChapter>(count)
        for (i in 0 until count) {
            val timeSec = mpv.getPropertyDouble("chapter-list/$i/time") ?: continue
            val title = mpv.getPropertyString("chapter-list/$i/title")?.takeIf { it.isNotEmpty() }
                ?: "Chapter ${i + 1}"
            out += PlayerChapter(title = title, startMs = (timeSec * 1000).toLong().coerceAtLeast(0L))
        }
        return out
    }

    /// A label -> value list of live playback stats read off mpv properties (the Android analogue of Apple
    /// `playbackStats()`). Absent/blank properties are dropped so the overlay shows only what mpv knows.
    override fun playbackStats(): List<Pair<String, String>> {
        val stats = mutableListOf<Pair<String, String>>()
        val w = mpv.getPropertyInt("video-params/w") ?: mpv.getPropertyInt("width")
        val h = mpv.getPropertyInt("video-params/h") ?: mpv.getPropertyInt("height")
        if (w != null && h != null && w > 0 && h > 0) stats += "Resolution" to "${w}x$h"
        mpv.getPropertyString("video-codec")?.takeIf { it.isNotEmpty() }?.let { stats += "Video codec" to it }
        mpv.getPropertyString("hwdec-current")?.takeIf { it.isNotEmpty() && it != "no" }
            ?.let { stats += "Hardware decode" to it }
        mpv.getPropertyDouble("container-fps")?.takeIf { it > 0 }
            ?.let { stats += "Frame rate" to String.format("%.3f fps", it) }
        mpv.getPropertyString("audio-codec")?.takeIf { it.isNotEmpty() }?.let { stats += "Audio codec" to it }
        mpv.getPropertyString("audio-params/hr-channels")?.takeIf { it.isNotEmpty() }
            ?.let { stats += "Channels" to it }
        return stats
    }

    override fun onEnterBackground() {
        // Drop video decode off-screen (matches Apple enterBackground: `vid=no`) and pause.
        pause()
        mpv.setPropertyString(PROP_VID, "no")
    }

    override fun onEnterForeground() {
        mpv.setPropertyString(PROP_VID, "auto")
        play()
    }

    /// Grab the current frame as JPEG, downscaled to at most [maxWidth] wide. The libmpv half of the
    /// community-trickplay capture pipeline; mirrors the INTENT of Apple's Metal-blit
    /// `MPVMetalViewController.captureFrameJPEGData`, by a necessarily different mechanism.
    ///
    /// MECHANISM, and why it is not the Apple one. Apple blits mpv's rendered Metal texture straight out
    /// of the VO. The Android JNI seam offers no equivalent: [MPVLib.command] returns Unit (it wraps
    /// `mpv_command`, not `mpv_command_ret`), so mpv's `screenshot-raw` -- the only command that hands
    /// pixel data BACK to the caller -- cannot deliver its `mpv_node` result through this artifact. The
    /// reachable route is therefore `screenshot-to-file`, which writes the frame to a path we choose and
    /// we then read back. Flag `video` takes the decoded video frame WITHOUT OSD or subtitles, which is
    /// exactly what a scrub thumbnail wants (subtitles burned into a shared community sheet would be a
    /// bug, since the pool is language-agnostic).
    ///
    /// HONEST CAVEAT -- this is the ONE step of the trickplay chain that cannot be verified without a
    /// device, so it is designed to fail CLOSED rather than to fail wrong. [MpvConfig.HWDEC] is plain
    /// `mediacodec` (surface-direct), deliberately NOT `mediacodec-copy`, because the direct path is what
    /// carries HDR/DV to the panel. Surface-direct mediacodec hands decoded frames to the Android Surface
    /// without ever staging them in CPU-addressable memory, so mpv may hold no readable copy and the
    /// screenshot can come back missing, empty, or unrendered. We do NOT "fix" that by switching to
    /// `mediacodec-copy`: that would trade the DV mandate for the trickplay mandate. Instead every
    /// failure mode degrades to null (no file / empty file / undecodable), and the near-black guard in
    /// [com.vortx.android.trickplay.TrickplaySession] drops an unrendered frame BEFORE it can reach the
    /// shared pool. A device test decides whether this yields real frames on `mediacodec`; if it does
    /// not, the fix is a capture-only software-decode path, never a change to the DV pipeline.
    ///
    /// Fail-soft on every step; never throws. The temp file is always cleaned up.
    override suspend fun captureFrameJpeg(maxWidth: Int): ByteArray? = withContext(Dispatchers.IO) {
        // Write into the app cache dir: mpv needs a real filesystem path it can open for writing, and the
        // frame is transient (it is re-encoded below and the file is deleted in the same call).
        val file = File(appContext.cacheDir, "vortx-tp-grab-${UUID.randomUUID()}.jpg")
        try {
            // mpv guesses the encoder from the extension (.jpg -> JPEG), so pin the quality knob first.
            // This is the full-resolution intermediate; the real downscale happens on decode below.
            mpv.setPropertyString(PROP_SCREENSHOT_JPEG_QUALITY, SCREENSHOT_INTERMEDIATE_QUALITY)
            // argv form (never a joined string) so a path containing mpv's list/escape chars stays one
            // argument, the same reason `loadfile` above uses the array form.
            mpv.command(arrayOf("screenshot-to-file", file.absolutePath, "video"))
            // `command` wraps the synchronous `mpv_command`, but it returns Unit so mpv's status code is
            // not observable here: the file's own existence + size IS the success signal. A VO that never
            // serviced the grab (or a surface-direct frame mpv could not read) leaves no file, or an empty
            // one -> null, and the caller simply skips this capture tick.
            if (!file.exists() || file.length() <= 0L) return@withContext null

            // Decode DOWNSCALED. inSampleSize keeps a 4K grab from ever being fully realised in memory:
            // this runs on a jetsam-bound device alongside mpv's own decode buffers, so a full-size ARGB
            // bitmap (4K = ~33 MB) is exactly the allocation to avoid. Two passes: bounds-only to learn
            // the real size, then a subsampled decode.
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            val srcWidth = bounds.outWidth
            if (srcWidth <= 0 || bounds.outHeight <= 0) return@withContext null
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sampleSizeFor(srcWidth, maxWidth)
            }
            val decoded = BitmapFactory.decodeFile(file.absolutePath, opts) ?: return@withContext null

            // inSampleSize only halves, so the subsampled bitmap is >= maxWidth; scale the remainder
            // exactly. Never upscale a frame that is already narrower than maxWidth.
            val scaled = if (decoded.width > maxWidth) {
                val height = (decoded.height.toDouble() * maxWidth / decoded.width).toInt().coerceAtLeast(1)
                Bitmap.createScaledBitmap(decoded, maxWidth, height, true)
                    .also { if (it !== decoded) decoded.recycle() }
            } else {
                decoded
            }

            val out = ByteArrayOutputStream()
            val ok = scaled.compress(Bitmap.CompressFormat.JPEG, CAPTURE_JPEG_QUALITY, out)
            scaled.recycle()
            if (ok) out.toByteArray() else null
        } catch (_: IOException) {
            null
        } finally {
            runCatching { file.delete() }
        }
    }

    /// Largest power-of-two subsample that still leaves the frame at least [maxWidth] wide, so the exact
    /// scale afterwards only ever shrinks. Mirrors the standard Android decode-bounds idiom.
    private fun sampleSizeFor(srcWidth: Int, maxWidth: Int): Int {
        if (maxWidth <= 0) return 1
        var sample = 1
        while (srcWidth / (sample * 2) >= maxWidth) sample *= 2
        return sample
    }

    override fun release() {
        mpv.removeObserver(observer)
        mpv.detachSurface()
        mpv.destroy()
        // A finished title must not leave a large on-disk cache behind (DiskCacheSetting's second owner
        // guardrail: the cache is wiped on a genuine playback exit). No-op when the disk cache is OFF.
        if (DiskCacheSetting.diskCacheEnabled(appContext)) {
            DiskCacheSetting.clearCache(appContext)
        }
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
                    // mpv track-list carries the container's forced disposition; carry it so TrackSelector's
                    // forced-subtitle policy keys off the flag, matching the ExoPlayer engine.
                    forced = t.optBoolean("forced", false),
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
        private const val PROP_AUDIO_DELAY = "audio-delay"
        private const val PROP_VID = "vid"
        private const val PROP_SPEED = "speed"
        private const val PROP_PANSCAN = "panscan"
        private const val PROP_VOLUME = "volume"
        private const val PROP_MUTE = "mute"
        // Per-file User-Agent override (the trailer UA/URL lockstep); the base UA is a pre-init option.
        private const val PROP_USER_AGENT = "user-agent"
        private const val PROP_CHAPTER_COUNT = "chapter-list/count"
        private const val PROP_SCREENSHOT_JPEG_QUALITY = "screenshot-jpeg-quality"
        private const val OPT_HTTP_HEADER_FIELDS = "http-header-fields"
        private const val OPT_DEMUXER_MAX_BYTES = "demuxer-max-bytes"

        /// Quality of mpv's full-resolution INTERMEDIATE grab. High on purpose: it is re-encoded below at
        /// [CAPTURE_JPEG_QUALITY] after downscaling, and compressing twice at the final quality would
        /// stack artifacts. The file is deleted in the same call, so its size never matters on disk.
        private const val SCREENSHOT_INTERMEDIATE_QUALITY = "90"

        /// Final tile quality, 0.7 == Apple's `kCGImageDestinationLossyCompressionQuality: 0.7` on both of
        /// its capture paths. Kept identical so an Android-contributed tile matches an Apple one.
        private const val CAPTURE_JPEG_QUALITY = 70

        // Per-file read-ahead: local torrent/loopback vs remote debrid/CDN (mirrors Apple loadFile).
        private const val READ_AHEAD_LOCAL = "96MiB"
        private const val READ_AHEAD_REMOTE = "128MiB"

        /// Build an [MpvPlayer], applying config + init. Returns null if [MPVLib.create] fails (missing
        /// native `.so` for the running ABI / OOM), so [com.vortx.android.player.MpvEngineFactory]
        /// can fall back to ExoPlayer. Never throws.
        fun create(context: Context): MpvPlayer? {
            val lib = MPVLib.create(context) ?: return null
            return runCatching { MpvPlayer(lib, context.applicationContext) }.getOrElse {
                runCatching { lib.destroy() }
                null
            }
        }
    }
}
