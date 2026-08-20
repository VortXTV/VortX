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
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.player.AudioOutputMode
import com.vortx.android.player.DiskCacheSetting
import com.vortx.android.player.PerformanceMode
import com.vortx.android.player.PlayerChapter
import com.vortx.android.player.PlayerEngine
import com.vortx.android.player.PlayerState
import com.vortx.android.player.PlayerTrack
import com.vortx.android.player.SubtitleStyle
import com.vortx.android.player.VideoScaleMode
import com.vortx.android.player.tuning.AdaptiveTuning
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
    caBundlePath: String,
) : PlayerEngine {

    private val _state = MutableStateFlow(PlayerState())
    override val state: StateFlow<PlayerState> = _state.asStateFlow()
    override val subtitleDelayAvailable: Boolean = true
    override val audioDelayAvailable: Boolean = true
    override val audioOutputModeAvailable: Boolean = true
    override val secondarySubtitleAvailable: Boolean = true
    override val hardwareDecodingAvailable: Boolean = true

    /// The live primary / secondary subtitle track ids, read from mpv (`sid` / `secondary-sid`). Both read
    /// -1 when their slot is off (mpv reports the property as `no`, which [MPVLib.getPropertyInt] surfaces
    /// as null). The chrome uses [primarySubtitleId] to key the primary checkmark once a second subtitle
    /// makes mpv flag BOTH tracks `selected`. Mirrors Apple `primarySubtitleID` / `secondarySubtitleID`.
    override val primarySubtitleId: Int get() = mpv.getPropertyInt(PROP_SID) ?: -1
    override val secondarySubtitleId: Int get() = mpv.getPropertyInt(PROP_SECONDARY_SID) ?: -1

    /// Set true if attaching the render surface ever throws. The caller can consult it to fall back to
    /// ExoPlayer on a hard surface failure instead of showing a black frame.
    @Volatile
    var surfaceFailed: Boolean = false
        private set

    /// True once REAL playback happened for the current file: set on MPV_EVENT_PLAYBACK_RESTART (mpv's
    /// "playback started, first frame is on its way" signal, also fired after each seek) or on the first
    /// observed `time-pos` advance past zero. This is the error-vs-ended discriminator for END_FILE:
    /// the jdtech JNI seam delivers `event(id)` with NO payload, so mpv's `mpv_event_end_file.reason`
    /// (ERROR vs EOF) is unreachable from Kotlin -- an END_FILE that arrives BEFORE any real playback
    /// (dead debrid link, exhausted reconnects, nothing decodable) can only be a failed open, never a
    /// watched-through end, and maps to [PlayerState.hasError]; an END_FILE after real playback is the
    /// genuine end-of-content and maps to [PlayerState.hasEnded]. Volatile: written on the mpv event
    /// thread, reset on [load].
    @Volatile
    private var playbackStarted: Boolean = false

    /// The resume position (ms) to seek to ONCE the pipeline is warm, or 0 for none. A pre-first-frame
    /// absolute seek on a cold libmpv pipeline arms mpv's cache-emptying hold and wedges video output
    /// (a blank frame + a frozen timer), so [load] stashes the resume here instead of seeking inline and
    /// [consumePendingResumeSeek] applies it at the first rendered frame. Volatile: written on [load] and
    /// read/cleared on the mpv event thread. Mirrors Apple `pendingLibmpvResumeSeek`
    /// (app/Sources/PlayerScreen.swift:1845 stash -> :1654 first-frame apply).
    @Volatile
    private var pendingResumeSeekMs: Long = 0L

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
                PROP_TIME_POS -> {
                    // A position advancing past zero is proof the demuxer/decoder delivered real data
                    // (belt-and-suspenders alongside PLAYBACK_RESTART for the END_FILE discriminator).
                    if (value > 0.0) {
                        playbackStarted = true
                        // RESUME WATCHDOG: if PLAYBACK_RESTART was missed, a real position advance is the
                        // fallback signal that the pipeline is warm enough to apply the deferred resume seek.
                        consumePendingResumeSeek()
                    }
                    _state.value = _state.value.copy(positionMs = (value * 1000).toLong().coerceAtLeast(0L))
                }
                PROP_DURATION -> _state.value = _state.value.copy(durationMs = (value * 1000).toLong().coerceAtLeast(0L))
            }
        }

        override fun eventProperty(name: String, value: Boolean) {
            when (name) {
                PROP_PAUSE -> _state.value = _state.value.copy(isPaused = value)
                PROP_PAUSED_FOR_CACHE -> {
                    // Before the first frame, [load] holds isBuffering=true as the "connecting" state, and
                    // mpv's initial observer sync delivers paused-for-cache=false for the still-idle core.
                    // Honoring that false would clear the spinner over a black frame that has not produced
                    // any video yet, so pre-playback only a TRUE (cache actually filling) passes through;
                    // once real playback started every value is authoritative again. The connecting state
                    // itself is cleared by PLAYBACK_RESTART (first frame) or the END_FILE error branch.
                    if (value || playbackStarted) _state.value = _state.value.copy(isBuffering = value)
                }
            }
        }

        override fun eventProperty(name: String, value: String) {
            // track-list is read via the property API (refreshTracks), not delivered as a string here.
        }

        override fun event(id: Int) {
            when (id) {
                MPVLib.Event.PLAYBACK_RESTART -> {
                    // Playback (re)started: the first frame is rendering. Marks real playback for the
                    // END_FILE discriminator and ends the "connecting" state ([load] set isBuffering=true).
                    playbackStarted = true
                    // The pipeline is now warm, so a stashed resume seek lands as an ordinary warm scrub
                    // instead of the cold pre-first-frame seek that wedged video output. No-op after the
                    // first apply (idempotent) and for a non-resume load. Mirrors Apple's first-frame apply.
                    consumePendingResumeSeek()
                    _state.value = _state.value.copy(isBuffering = false)
                }
                MPVLib.Event.END_FILE -> {
                    // The JNI seam exposes no END_FILE reason (see [playbackStarted]), so: an EOF before
                    // any real playback is a FAILED SOURCE (dead link, unsupported codec, exhausted
                    // reconnect) -> hasError, which drives the chrome's error overlay and, critically,
                    // does NOT trip the host's hasEnded-gated next-episode auto-advance. An EOF after
                    // real playback is the genuine end-of-content -> hasEnded, exactly as before.
                    _state.value = if (playbackStarted) {
                        _state.value.copy(hasEnded = true)
                    } else {
                        _state.value.copy(hasError = true, isBuffering = false)
                    }
                }
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
        val upscaling = TrackPreferencesStore(
            appContext,
            PerformanceMode.isConstrainedDevice(appContext),
        ).videoUpscaling
        for ((name, value) in upscaling.mpvOptions) {
            mpv.setOptionString(name, value)
        }
        // Apply the trust policy last and fail closed if this packaged libmpv rejects any part of it.
        // create() catches the exception, destroys this libmpv instance, and returns null so the router
        // can use the platform player rather than continue with unknown certificate behavior.
        for ((name, value) in MpvConfig.requiredSecurityOptions(caBundlePath)) {
            requireMpvSecurityOption(name, mpv.setOptionString(name, value))
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
        // Fresh terminal flags for the new file, and isBuffering=true as the CONNECTING state: from
        // loadfile until the first frame (PLAYBACK_RESTART) or a failed open (END_FILE error branch),
        // the chrome shows its spinner instead of a silent black frame. mpv only starts reporting
        // `paused-for-cache` once the demuxer is up, so without this the open window had no signal.
        playbackStarted = false
        _state.value = _state.value.copy(hasEnded = false, hasError = false, isBuffering = true)

        // Every file starts from the known network-identity baseline. This player instance is reused across
        // `loadfile replace`, so conditional SET-only writes would leak a prior source's Referer / custom UA
        // into a later source that omitted them. Apply the reset first, then this file's values, all as runtime
        // properties because mpv is already initialized.
        for ((name, value) in streamHttpPropertyWrites(playable)) {
            mpv.setPropertyString(name, value)
        }

        // Device-scaled forward cache cap, applied per file as a property (the Apple loadFile split).
        //   - Disk cache ON: hand mpv the large, free-disk-clamped budget so the on-disk cache actually
        //     fills (the cache-on-disk/cache-dir options are already armed pre-init). Recomputed per file
        //     so it always reflects CURRENT free space (DiskCacheSetting's UNLIMITED safety).
        //   - Disk cache OFF: a LOCAL (torrent/loopback) stream buffers in the streaming server's own
        //     cache, so keep mpv's read-ahead tight; a remote debrid/CDN link keeps the larger buffer for
        //     network resilience; a constrained device stays tight even for remote (PerformanceMode hook).
        val reduced = PerformanceMode.isReduced(appContext)
        val diskCache = DiskCacheSetting.diskCacheEnabled(appContext)
        // Local == torrent/loopback/trailer/reduced: all keep the tight flat read-ahead (a trailer is a
        // short clip; a torrent/loopback buffers in the streaming server's own cache; a reduced device
        // stays clear of jetsam). Mirrors Apple loadFile's local vs remote split.
        val localStream = playable.isTorrent || playable.viaStreamingServer || playable.isTrailer || reduced
        // The capable remote debrid/CDN path is the ONE that takes the adaptive buffer.
        val remoteAdaptive = !diskCache && !localStream
        val readAhead = when {
            diskCache -> DiskCacheSetting.resolvedMaxBytes(appContext, reduced).toString()
            localStream -> READ_AHEAD_LOCAL
            // Remote debrid/CDN on a capable device: size the forward read-ahead to the device RAM tier
            // scaled by the buffer-intent + measured-link plan, clamped by free disk and floored at the
            // conservative flat cap. Behind the buffer-tuning flag; OFF keeps the flat cap.
            else -> AdaptiveTuning.mpvRemoteReadAheadBytes(appContext).toString()
        }
        mpv.setPropertyString(OPT_DEMUXER_MAX_BYTES, readAhead)

        // On the capable remote path, also match the forward read-ahead SECONDS and cache window to the
        // adaptive plan (the mpv half of feeding the plan into demuxer-readahead-secs / cache-secs). The
        // local / disk-cache paths keep the base-option values from [MpvConfig].
        if (remoteAdaptive) {
            val plan = AdaptiveTuning.currentPlan(appContext)
            mpv.setPropertyString(OPT_DEMUXER_READAHEAD_SECS, plan.mpvReadaheadSecs.toString())
            mpv.setPropertyString(OPT_CACHE_SECS, plan.mpvCacheSecs.toString())
        }

        // Record this stream so the adaptive tuner can measure its host in the background for the NEXT play
        // (opt-in + unmetered gated inside noteStream). Fail-soft.
        AdaptiveTuning.noteStream(appContext, playable.url, playable.headers)

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

        // Resume position: DEFER the seek to the first rendered frame rather than issuing it here. A
        // pre-first-frame absolute seek on a cold libmpv pipeline arms mpv's cache-emptying hold and
        // wedges video output (a blank frame + a frozen timer); stashing it and applying it at
        // PLAYBACK_RESTART (or the first observed position advance, the resume watchdog) lands it as an
        // ordinary warm scrub, which is proven to render. Mirrors the Apple fix
        // (app/Sources/PlayerScreen.swift:1845 stash -> :1654 first-frame apply). Cleared on every load
        // so a switch/reload never inherits the previous file's resume.
        pendingResumeSeekMs = if (playable.startPositionMs > 0L) playable.startPositionMs else 0L
    }

    /// Apply the deferred resume seek once the pipeline is warm (first frame rendered, or the first
    /// position advance as the watchdog). The pending value is cleared BEFORE the seek so the two trigger
    /// signals (PLAYBACK_RESTART + the first `time-pos` advance) can never double-apply it; both run on the
    /// single mpv event thread, so no lock is needed. A no-op for a non-resume load. Mirrors Apple
    /// consuming `pendingLibmpvResumeSeek` at the FIRST FRAME.
    private fun consumePendingResumeSeek() {
        val target = pendingResumeSeekMs
        if (target <= 0L) return
        pendingResumeSeekMs = 0L
        // RESUME ADMISSION (Apple PlayerScreen.swift:1812 `resumeSeconds > 5, resumeSeconds < d - 10`):
        // only honour a resume past a >5s floor and clear of the last 10s, so a barely-started or
        // all-but-finished title starts over instead of snapping to a position 5s from the credits. The
        // duration is known by the first frame; when it is not yet, only the floor applies (the tail guard
        // is gated on a positive duration), which the later position advance never re-triggers.
        if (target <= RESUME_FLOOR_MS) return
        val durationMs = _state.value.durationMs
        if (durationMs > 0L && target >= durationMs - RESUME_TAIL_GUARD_MS) return
        mpv.command(arrayOf("seek", (target / 1000.0).toString(), "absolute"))
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

    override fun seekBy(deltaMs: Long) {
        // mpv's own relative seek: exact against mpv's true position (the observed time-pos can lag up
        // to a second behind) and natively clamped to [0, duration], so no state math here.
        mpv.command(arrayOf("seek", (deltaMs / 1000.0).toString(), "relative"))
    }

    override fun setPlaybackSpeed(speed: Float) { mpv.setPropertyString(PROP_SPEED, speed.toString()) }

    override fun selectAudioTrack(id: Int) { mpv.setPropertyString(PROP_AID, id.toString()) }

    override fun selectSubtitleTrack(id: Int?) {
        mpv.setPropertyString(PROP_SID, id?.toString() ?: "no")
    }

    override fun addExternalSubtitle(url: String) { mpv.command(arrayOf("sub-add", url)) }

    override fun setSubtitleDelay(seconds: Double) { mpv.setPropertyString(PROP_SUB_DELAY, seconds.toString()) }

    /// Select / clear the SECOND simultaneous subtitle track via mpv `secondary-sid`. A negative / null id
    /// clears it (`no`). Setting it makes mpv flag the second track `selected` in `track-list`, which
    /// republishes [PlayerState.subtitleTracks] so the chrome re-reads [secondarySubtitleId]. Mirrors Apple
    /// `setSecondarySubtitleTrack`.
    override fun setSecondarySubtitleTrack(id: Int?) {
        mpv.setPropertyString(PROP_SECONDARY_SID, id?.takeIf { it >= 0 }?.toString() ?: "no")
    }

    /// Force hardware (`mediacodec`, the DV/HDR passthrough default) or software (`no`) decode via mpv
    /// `hwdec`. Software is the escape hatch for a device whose hardware codec emits green / garbled frames;
    /// hardware stays the default. Mirrors Apple `setHardwareDecoding`.
    override fun setHardwareDecoding(hardware: Boolean) {
        mpv.setPropertyString(PROP_HWDEC, if (hardware) MpvConfig.HWDEC else "no")
    }

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
        for ((name, value) in mode.mpvLiveProperties()) {
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

    /// Source frame rate + pixel size for the Match-Frame-Rate display switch, from mpv's demuxer
    /// properties. Null until the container rate is known (a beat after the first frames), which is the
    /// signal [com.vortx.android.player.AfrController] polls for. Thread-safe: mpv property reads are.
    override fun videoFrameProfile(): com.vortx.android.player.VideoFrameProfile? {
        val fps = mpv.getPropertyDouble("container-fps")?.takeIf { it > 0 } ?: return null
        val w = (mpv.getPropertyInt("video-params/w") ?: mpv.getPropertyInt("width") ?: 0).coerceAtLeast(0)
        val h = (mpv.getPropertyInt("video-params/h") ?: mpv.getPropertyInt("height") ?: 0).coerceAtLeast(0)
        return com.vortx.android.player.VideoFrameProfile(fps, w, h)
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
                            // mpv does NOT read dimensions off the attached Surface: its Android GL
                            // context sizes the render viewport from the `android-surface-size`
                            // property (the mpv-android/jdtech contract). The framework guarantees this
                            // callback fires at least once after surfaceCreated with the real size, and
                            // again on every resize (the portrait<->landscape rotation). Without this
                            // write mpv keeps a stale/zero viewport and the frame renders at the wrong
                            // aspect; this IS the aspect-ratio fix, not an optimization.
                            mpv.setPropertyString(PROP_ANDROID_SURFACE_SIZE, "${width}x$height")
                        }

                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            runCatching { mpv.detachSurface() }
                        }
                    })
                }
            },
            // Aspect / zoom / stretch: FIT keeps the whole frame (keepaspect on, panscan 0), ZOOM crops to
            // fill keeping aspect (panscan 1), STRETCH distorts to fill (keepaspect off). Re-applied on
            // recompose so the chrome's aspect sheet takes effect without rebuilding the surface.
            update = {
                when (scaleMode) {
                    VideoScaleMode.STRETCH -> {
                        mpv.setPropertyString(PROP_KEEPASPECT, "no")
                        mpv.setPropertyString(PROP_PANSCAN, "0.0")
                    }
                    VideoScaleMode.ZOOM -> {
                        mpv.setPropertyString(PROP_KEEPASPECT, "yes")
                        mpv.setPropertyString(PROP_PANSCAN, "1.0")
                    }
                    VideoScaleMode.FIT -> {
                        mpv.setPropertyString(PROP_KEEPASPECT, "yes")
                        mpv.setPropertyString(PROP_PANSCAN, "0.0")
                    }
                }
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
        private const val PROP_SECONDARY_SID = "secondary-sid"
        private const val PROP_SUB_DELAY = "sub-delay"
        private const val PROP_AUDIO_DELAY = "audio-delay"
        private const val PROP_HWDEC = "hwdec"
        private const val PROP_VID = "vid"
        private const val PROP_SPEED = "speed"
        private const val PROP_PANSCAN = "panscan"
        private const val PROP_KEEPASPECT = "keepaspect"
        /// The Android GL context's viewport size, written on every surfaceChanged (mpv-android contract).
        private const val PROP_ANDROID_SURFACE_SIZE = "android-surface-size"
        private const val PROP_VOLUME = "volume"
        private const val PROP_MUTE = "mute"
        // Per-file User-Agent override (the trailer UA/URL lockstep); the base UA is a pre-init option.
        private const val PROP_USER_AGENT = "user-agent"
        private const val PROP_CHAPTER_COUNT = "chapter-list/count"
        private const val PROP_SCREENSHOT_JPEG_QUALITY = "screenshot-jpeg-quality"
        private const val OPT_HTTP_HEADER_FIELDS = "http-header-fields"
        private const val OPT_DEMUXER_MAX_BYTES = "demuxer-max-bytes"
        // Per-file adaptive read-ahead SECONDS + cache window on the capable remote path (the base values
        // are pre-init options in [MpvConfig]; these override them from the adaptive plan).
        private const val OPT_DEMUXER_READAHEAD_SECS = "demuxer-readahead-secs"
        private const val OPT_CACHE_SECS = "cache-secs"

        /// Quality of mpv's full-resolution INTERMEDIATE grab. High on purpose: it is re-encoded below at
        /// [CAPTURE_JPEG_QUALITY] after downscaling, and compressing twice at the final quality would
        /// stack artifacts. The file is deleted in the same call, so its size never matters on disk.
        private const val SCREENSHOT_INTERMEDIATE_QUALITY = "90"

        /// Final tile quality, 0.7 == Apple's `kCGImageDestinationLossyCompressionQuality: 0.7` on both of
        /// its capture paths. Kept identical so an Android-contributed tile matches an Apple one.
        private const val CAPTURE_JPEG_QUALITY = 70

        /// Resume admission bounds (Apple `resumeSeconds > 5, resumeSeconds < d - 10`): resume only past a
        /// 5s floor and clear of the last 10s, so a barely-started or all-but-finished title starts over.
        private const val RESUME_FLOOR_MS = 5_000L
        private const val RESUME_TAIL_GUARD_MS = 10_000L

        // Per-file read-ahead: local torrent/loopback vs remote debrid/CDN (mirrors Apple loadFile).
        // LOCAL stays a conservative flat cap (a torrent/loopback stream buffers in the streaming server's
        // own cache, so mpv's read-ahead is kept tight). The REMOTE path is now sized per load by the
        // adaptive tuner (device RAM tier + buffer intent + measured link), see
        // [com.vortx.android.player.tuning.AdaptiveTuning.mpvRemoteReadAheadBytes].
        private const val READ_AHEAD_LOCAL = "96MiB"

        /// Runtime HTTP-property writes for one file, in application order. The first two writes always clear
        /// the previous file's identity; later writes apply only this file's headers / trailer-bound UA.
        /// Kept pure and internal so hostile transition tests can prove a reused engine never carries stale
        /// network identity without constructing the native mpv handle.
        internal fun streamHttpPropertyWrites(playable: Playable): List<Pair<String, String>> = buildList {
            add(OPT_HTTP_HEADER_FIELDS to "")
            add(PROP_USER_AGENT to MpvConfig.USER_AGENT)
            if (playable.headers.isNotEmpty()) {
                val fields = playable.headers.entries.joinToString(",") { "${it.key}: ${it.value}" }
                add(OPT_HTTP_HEADER_FIELDS to fields)
            }
            playable.userAgent?.let { ua ->
                add(PROP_USER_AGENT to ua)
                // A client-resolved trailer's UA applies to both googlevideo legs. Do not also replay an
                // unrelated add-on header map against those URLs.
                add(OPT_HTTP_HEADER_FIELDS to "")
            }
        }

        /// Build an [MpvPlayer], applying config + init. Returns null if [MPVLib.create] fails (missing
        /// native `.so` for the running ABI / OOM), so [com.vortx.android.player.MpvEngineFactory]
        /// can fall back to ExoPlayer. Never throws.
        fun create(context: Context): MpvPlayer? {
            val appContext = context.applicationContext
            if (!MpvConfig.ensureSystemTrustStoreObserver(appContext)) return null
            val caBundlePath = MpvConfig.provisionSystemCaBundle(appContext) ?: return null
            val lib = MPVLib.create(appContext) ?: return null
            return runCatching { MpvPlayer(lib, appContext, caBundlePath) }.getOrElse {
                runCatching { lib.destroy() }
                null
            }
        }
    }
}

internal fun requireMpvSecurityOption(name: String, result: Int) {
    check(result >= 0) {
        "required libmpv security option rejected: $name ($result)"
    }
}
