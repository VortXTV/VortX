package com.vortx.android.player.mpv

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.vortx.android.model.Playable
import com.vortx.android.model.ExternalSubtitle
import com.vortx.android.communityjs.CommunityJsUrlPolicy
import com.vortx.android.engine.DeadlinePublicDns
import com.vortx.android.engine.PublicAddressPolicy
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.player.AudioOutputMode
import com.vortx.android.player.DiskCacheSetting
import com.vortx.android.player.EngineFallbackReason
import com.vortx.android.player.EngineFailureCoordinator
import com.vortx.android.player.EngineFailureResolution
import com.vortx.android.player.LoudnessNormalizationSetting
import com.vortx.android.player.PerformanceMode
import com.vortx.android.player.PlayerChapter
import com.vortx.android.player.PlayerEngine
import com.vortx.android.player.PlayerState
import com.vortx.android.player.PlayerTrack
import com.vortx.android.player.SubtitleStyle
import com.vortx.android.player.VideoScaleMode
import com.vortx.android.player.normalizedExternalSubtitles
import com.vortx.android.player.recoverNativeFailure
import com.vortx.android.player.requestEngineFallback
import com.vortx.android.player.tuning.AdaptiveTuning
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.delay
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.Proxy
import java.net.URI
import java.net.InetAddress
import java.net.UnknownHostException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dns
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

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
/// null when [MPVLib.create] fails; runtime engine failures publish [EngineFallbackReason], which
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
    override val hdrToneMapAvailable: Boolean = true

    /// The live primary / secondary subtitle track ids, read from mpv (`sid` / `secondary-sid`). Both read
    /// -1 when their slot is off (mpv reports the property as `no`, which [MPVLib.getPropertyInt] surfaces
    /// as null). The chrome uses [primarySubtitleId] to key the primary checkmark once a second subtitle
    /// makes mpv flag BOTH tracks `selected`. Mirrors Apple `primarySubtitleID` / `secondarySubtitleID`.
    override val primarySubtitleId: Int get() = mpv.getPropertyInt(PROP_SID) ?: -1
    override val secondarySubtitleId: Int get() = mpv.getPropertyInt(PROP_SECONDARY_SID) ?: -1

    /// True once real playback happened for the current file. This controls connecting/buffering and
    /// deferred-resume behavior only. It must never infer terminal reason: a midstream decoder or network
    /// error can happen after playback started and is not EOF.
    @Volatile
    private var playbackStarted: Boolean = false

    /// Typed, idempotent terminal state for the current source, guarded by [MpvTerminalGate]'s single
    /// lock together with teardown + UI publication. Since W1-B the seam delivers the REAL
    /// mpv_event_end_file payload, so EOF/ERROR/STOP/QUIT/REDIRECT are native facts; UNKNOWN remains
    /// reachable only for reason codes a future libmpv might add, and fails safe (error, no advance).
    /// The former eof-reached flag heuristic is GONE: it was a global, non-source-scoped property that
    /// could stale-race across source generations; with real reasons there is nothing left to infer.
    private val failureCoordinator = EngineFailureCoordinator<EngineTerminalVerdict>()
    private val terminalGate = MpvTerminalGate { hasEnded, hasError, isBuffering, terminal ->
        val verdict = EngineTerminalVerdict(hasEnded, hasError, isBuffering)
        if (terminal) {
            applyFailureResolution(failureCoordinator.onTerminal(verdict))
        } else {
            // Source reset runs under the terminal gate's lock, preserving one global lock order:
            // terminal gate -> failure coordinator. Old async opportunity completions then become no-ops.
            failureCoordinator.reset()
            _state.update {
                it.copy(hasEnded = hasEnded, hasError = hasError, isBuffering = isBuffering)
            }
        }
    }

    private fun applyFailureResolution(resolution: EngineFailureResolution<EngineTerminalVerdict>) {
        when (resolution) {
            EngineFailureResolution.None -> Unit
            is EngineFailureResolution.CommitTerminal -> _state.update {
                it.copy(
                    hasEnded = resolution.terminal.hasEnded,
                    hasError = resolution.terminal.hasError,
                    isBuffering = resolution.terminal.isBuffering,
                )
            }
            is EngineFailureResolution.Demote -> {
                _state.update { it.requestEngineFallback(resolution.reason) }
                Log.e(TAG, "libmpv ${resolution.reason}; requesting Media3 fallback")
            }
        }
    }

    @Volatile
    private var hasLoadedSource: Boolean = false

    /// The resume position (ms) to seek to ONCE the pipeline is warm, or 0 for none. A pre-first-frame
    /// absolute seek on a cold libmpv pipeline arms mpv's cache-emptying hold and wedges video output
    /// (a blank frame + a frozen timer), so [load] stashes the resume here instead of seeking inline and
    /// [consumePendingResumeSeek] applies it at the first rendered frame. Volatile: written on [load] and
    /// read/cleared on the mpv event thread. Mirrors Apple `pendingLibmpvResumeSeek`
    /// (app/Sources/PlayerScreen.swift:1845 stash -> :1654 first-frame apply).
    @Volatile
    private var pendingResumeSeekMs: Long = 0L

    private val runtimePolicyScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val subtitleLoadScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val subtitleLoadGeneration = AtomicLong()
    private val subtitleGenerationGate = Any()
    private val released = AtomicBoolean(false)
    private val audioHealthLock = Any()
    private var audioHealthJob: Job? = null
    @Volatile private var audioRecoveryAttempted = false
    @Volatile private var audioFileLoadedGeneration = 0L
    // `FILE_LOADED` can arrive before mpv has published the file's track-list. Keep the observation
    // separate from PlayerState's currently visible tracks so an early empty snapshot cannot silently
    // declare a real audio-bearing stream healthy. Access is serialized with audio-health scheduling.
    private var audioTrackListObservedGeneration = 0L
    private var audioTrackListHasAudio = false
    private var pausedClampJob: Job? = null
    private var memoryRecoveryJob: Job? = null
    private var normalReadAheadBytes: Long? = null
    private var activeReadAheadBytes: Long? = null
    private var pausedCacheClamped = false
    private var memoryShedConsumed = false
    private var memoryShedActive = false
    private var memoryShedPositionMs = 0L

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
                    // A position advancing past zero is proof the demuxer/decoder delivered real data.
                    if (value > 0.0) {
                        playbackStarted = true
                        // RESUME WATCHDOG: if PLAYBACK_RESTART was missed, a real position advance is the
                        // fallback signal that the pipeline is warm enough to apply the deferred resume seek.
                        consumePendingResumeSeek()
                    }
                    _state.update { it.copy(positionMs = (value * 1000).toLong().coerceAtLeast(0L)) }
                }
                PROP_DURATION -> _state.update { it.copy(durationMs = (value * 1000).toLong().coerceAtLeast(0L)) }
                // `demuxer-cache-time` is the ABSOLUTE timestamp (seconds) of the end of the forward cache,
                // i.e. how far ahead of the playhead the demuxer has loaded. Feeds the scrubber's buffered
                // band, the mpv analogue of ExoPlayer's `bufferedPosition`. A negative sentinel (no cache
                // info) leaves the last value untouched so the band never flickers to 0 mid-play.
                PROP_DEMUXER_CACHE_TIME ->
                    if (value >= 0.0) {
                        _state.update { it.copy(bufferedPositionMs = (value * 1000).toLong().coerceAtLeast(0L)) }
                    }
            }
        }

        override fun eventProperty(name: String, value: Boolean) {
            when (name) {
                PROP_PAUSE -> {
                    _state.update { it.copy(isPaused = value) }
                    pausedStateChanged(value)
                }
                PROP_PAUSED_FOR_CACHE -> {
                    // Before the first frame, [load] holds isBuffering=true as the "connecting" state, and
                    // mpv's initial observer sync delivers paused-for-cache=false for the still-idle core.
                    // Honoring that false would clear the spinner over a black frame that has not produced
                    // any video yet, so pre-playback only a TRUE (cache actually filling) passes through;
                    // once real playback started every value is authoritative again. The connecting state
                    // itself is cleared by PLAYBACK_RESTART (first frame) or a terminal callback.
                    if (value || playbackStarted) _state.update { it.copy(isBuffering = value) }
                }
            }
        }

        override fun eventProperty(name: String, value: String) {
            // track-list is read via the property API (refreshTracks), not delivered as a string here.
        }

        override fun eventTerminal(event: MpvTerminalEvent) {
            // The gate drops the callback entirely when teardown won the race, when a duplicate
            // arrives after the first terminal, or inside the replacement-suppression window; it
            // publishes under its lock only for a state-changing verdict.
            val applied = terminalGate.onTerminal(event)
            if (applied?.nativeError != null) {
                Log.e(TAG, "mpv terminal ${applied.reason}; native error=${applied.nativeError}")
            }
        }

        override fun event(id: Int) {
            when (id) {
                MPVLib.Event.START_FILE -> terminalGate.onSourceStarted()
                MPVLib.Event.PLAYBACK_RESTART -> {
                    // Playback (re)started: the first frame is rendering. Marks real playback for resume
                    // handling and ends the "connecting" state ([load] set isBuffering=true).
                    playbackStarted = true
                    // The pipeline is now warm, so a stashed resume seek lands as an ordinary warm scrub
                    // instead of the cold pre-first-frame seek that wedged video output. No-op after the
                    // first apply (idempotent) and for a non-resume load. Mirrors Apple's first-frame apply.
                    consumePendingResumeSeek()
                    _state.update { it.copy(isBuffering = false) }
                    scheduleAudioOutputHealthCheck()
                }
                MPVLib.Event.FILE_LOADED -> {
                    synchronized(audioHealthLock) {
                        audioFileLoadedGeneration = subtitleLoadGeneration.get()
                        audioTrackListObservedGeneration = 0L
                        audioTrackListHasAudio = false
                    }
                    refreshTracks()
                    scheduleAudioOutputHealthCheck(replaceExisting = true)
                }
                MPVLib.Event.VIDEO_RECONFIG -> refreshTracks()
                MPVLib.Event.AUDIO_RECONFIG -> scheduleAudioOutputHealthCheck()
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
        // WHY audit 13: arm the persisted late-night dynamic normalizer before mpv initializes.
        for ((name, value) in LoudnessNormalizationSetting.mpvOptions(appContext)) {
            mpv.setOptionString(name, value)
        }
        // Route-aware: the live output route decides the channel layout / bitstream so a multichannel
        // (5.1/Atmos) stream is never forced onto a stereo-only sink as silence (the Apple silence guard).
        for ((name, value) in AudioOutputMode.current(appContext).mpvOptions(appContext)) {
            mpv.setOptionString(name, value)
        }
        // HDR -> SDR tone-map policy (Apple `stremiox.hdrToneMapMode`): pin the output transfer/primaries to
        // SDR when forcing, else leave them on auto for HDR passthrough. Applied pre-init here and live via
        // [applyHdrToneMap]. mpv-only; the ExoPlayer engine leaves HDR/DV to the panel.
        for ((name, value) in MpvConfig.hdrOutputOptions(
            com.vortx.android.player.extras.HdrToneMapSetting.forceSDR(appContext),
        )) {
            mpv.setOptionString(name, value)
        }
        val upscaling = TrackPreferencesStore(
            appContext,
            PerformanceMode.isConstrainedDevice(appContext),
        ).videoUpscaling
        // Anime4K needs its bundled GLSL chain extracted to disk before its options mean anything: its
        // `mpvOptions` set bilinear scalers precisely BECAUSE the neural shaders do the upscaling. If the
        // chain cannot be armed (assets missing / IO failure), skip this preset entirely and fall back to the
        // plain baseline rather than applying bilinear-with-no-shaders, which would look WORSE than Standard.
        val shaderChain = Anime4KShaders.glslShadersOption(appContext, upscaling.glslShaderFileNames)
        if (upscaling.glslShaderFileNames.isEmpty() || shaderChain != null) {
            for ((name, value) in upscaling.mpvOptions) {
                mpv.setOptionString(name, value)
            }
            shaderChain?.let { mpv.setOptionString("glsl-shaders", it) }
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
        mpv.observeProperty(PROP_DEMUXER_CACHE_TIME, MPVLib.Format.DOUBLE)
        mpv.observeProperty(PROP_TRACK_LIST, MPVLib.Format.NONE)
        mpv.addObserver(observer)
    }

    override fun load(playable: Playable) {
        if (released.get()) return
        val loadGeneration = synchronized(subtitleGenerationGate) {
            subtitleLoadGeneration.incrementAndGet()
        }
        // Reset terminal classification and invalidate the previous source's opportunity tokens before
        // cancelling its jobs. Their finally blocks may run immediately; completion must be a no-op for
        // this new source generation.
        if (hasLoadedSource) {
            terminalGate.beginReplacementLoad()
        } else {
            terminalGate.beginFirstLoad()
        }
        // A replacement never retains work started for its predecessor. The final command is also gated
        // below, covering a job that completed its copy at exactly the same time as this cancellation.
        subtitleLoadScope.coroutineContext.cancelChildren()
        synchronized(audioHealthLock) {
            audioHealthJob?.cancel()
            audioHealthJob = null
            audioRecoveryAttempted = false
            audioFileLoadedGeneration = 0L
            audioTrackListObservedGeneration = 0L
            audioTrackListHasAudio = false
        }
        // For a replacement the gate above armed its suppression window: mpv queues the OLD source's
        // END_FILE before the NEW source's START_FILE on this client's event queue, so exactly that span
        // is where a stale old-source terminal must be dropped. START_FILE closes the window.
        hasLoadedSource = true
        playbackStarted = false

        // Every file starts from the known network-identity baseline. This player instance is reused across
        // `loadfile replace`, so conditional SET-only writes would leak a prior source's Referer / custom UA
        // into a later source that omitted them. Apply the reset first, then this file's values, all as runtime
        // properties because mpv is already initialized.
        for ((name, value) in streamHttpPropertyWrites(playable)) {
            mpv.setPropertyString(name, value)
        }
        // The player instance survives `loadfile replace`; pick up a Settings change for the next title and
        // clear the old filter when the toggle moved OFF.
        for ((name, value) in LoudnessNormalizationSetting.mpvOptions(appContext)) {
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
            diskCache -> DiskCacheSetting.resolvedMaxBytes(appContext, reduced)
            localStream -> READ_AHEAD_LOCAL_BYTES
            // Remote debrid/CDN on a capable device: size the forward read-ahead to the device RAM tier
            // scaled by the buffer-intent + measured-link plan, clamped by free disk and floored at the
            // conservative flat cap. Behind the buffer-tuning flag; OFF keeps the flat cap.
            else -> AdaptiveTuning.mpvRemoteReadAheadBytes(appContext)
        }
        resetRuntimeCachePolicy(readAhead)
        applyReadAheadCap(readAhead)

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

        // WHY audit 07.5: never hand an untrusted remote subtitle URL to mpv. Download under the same
        // 8 MiB / 20s bounds as Apple, then mount only the local cache file. Failure never affects playback.
        for (sub in MpvExternalSubtitleTransport.normalizedTracks(playable)) {
            mountExternalSubtitle(sub, loadGeneration)
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

    /** WHY audit 05.3: mpv keeps filling its forward cache while paused. Mirror Apple's delayed 48 MiB
     * clamp, but use the requested 10s Android grace, then restore this file's current tuned budget. */
    @Synchronized
    private fun pausedStateChanged(paused: Boolean) {
        pausedClampJob?.cancel()
        pausedClampJob = null
        if (paused) {
            val active = activeReadAheadBytes ?: return
            if (pausedCacheClamped || active <= PAUSED_CACHE_CLAMP_BYTES) return
            pausedClampJob = runtimePolicyScope.launch {
                delay(PAUSED_CACHE_CLAMP_GRACE_MS)
                applyPausedCacheClamp()
            }
        } else if (pausedCacheClamped) {
            pausedCacheClamped = false
            activeReadAheadBytes?.let(::applyReadAheadCap)
            Log.i(TAG, "paused cache clamp released")
        }
    }

    @Synchronized
    private fun applyPausedCacheClamp() {
        if (!_state.value.isPaused || pausedCacheClamped) return
        val active = activeReadAheadBytes ?: return
        if (active <= PAUSED_CACHE_CLAMP_BYTES) return
        pausedCacheClamped = true
        applyReadAheadCap(PAUSED_CACHE_CLAMP_BYTES)
        Log.i(TAG, "paused cache clamped to 48MiB after 10s")
    }

    @Synchronized
    private fun resetRuntimeCachePolicy(normalBytes: Long) {
        pausedClampJob?.cancel()
        memoryRecoveryJob?.cancel()
        pausedClampJob = null
        memoryRecoveryJob = null
        normalReadAheadBytes = normalBytes
        activeReadAheadBytes = normalBytes
        pausedCacheClamped = false
        memoryShedConsumed = false
        memoryShedActive = false
        memoryShedPositionMs = 0L
    }

    private fun applyReadAheadCap(bytes: Long) {
        val value = bytes.toString()
        // The second property is present on newer mpv cache backends. Older builds may reject it, so each
        // write is independent and fail-soft while demuxer-max-bytes remains the authoritative cap.
        runCatching { mpv.setPropertyString(OPT_DEMUXER_MAX_BYTES, value) }
        runCatching { mpv.setPropertyString(OPT_DEMUXER_MAX_BYTES_CACHE, value) }
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

    override fun addExternalSubtitle(url: String) {
        mountExternalSubtitle(ExternalSubtitle(url = url), subtitleLoadGeneration.get())
    }

    private fun mountExternalSubtitle(source: ExternalSubtitle, generation: Long) {
        subtitleLoadScope.launch {
            val local = boundedSubtitleFile(source)
            if (local == null) {
                Log.w(TAG, "external subtitle skipped: bounded fetch failed")
                return@launch
            }
            synchronized(subtitleGenerationGate) {
                if (released.get() || !MpvExternalSubtitleTransport.shouldMount(generation, subtitleLoadGeneration.get())) {
                    return@launch
                }
                mpv.command(arrayOf("sub-add", local.absolutePath))
            }
        }
    }

    private suspend fun boundedSubtitleFile(source: ExternalSubtitle): File? {
        MpvExternalSubtitleTransport.localFileFor(source.url)?.let { local ->
            return local.takeIf { it.isFile && it.length() in 1..MAX_EXTERNAL_SUBTITLE_BYTES }
        }
        if (MpvExternalSubtitleTransport.isContentUri(source.url)) {
            return boundedContentSubtitleFile(source.url)
        }
        val request = MpvExternalSubtitleTransport.requestFor(source) ?: return null
        val uri = request.uri
        val digest = MpvExternalSubtitleTransport.cacheKey(request)
        val extension = uri.path?.substringAfterLast('.', "")
            ?.lowercase()?.takeIf { it in SUBTITLE_EXTENSIONS } ?: "srt"
        val target = File(appContext.cacheDir, "vortx-extsub-$digest.$extension")
        if (target.isFile && target.length() in 1..MAX_EXTERNAL_SUBTITLE_BYTES) return target

        var temp: File? = null
        return try {
            var current = request
            val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(EXTERNAL_SUBTITLE_TIMEOUT_MS.toLong())
            repeat(MpvExternalSubtitleTransport.MAX_REDIRECTS + 1) { hop ->
                currentCoroutineContext().ensureActive()
                val remainingMs = TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime()).coerceAtLeast(1L)
                val client = MpvExternalSubtitleTransport.protectedClient(remainingMs)
                val httpUrl = current.uri.toString().toHttpUrlOrNull() ?: return null
                val response = client.awaitResponse(
                    Request.Builder().url(httpUrl).get().apply {
                        current.headers.forEach { (name, value) -> header(name, value) }
                    }.build(),
                    remainingMs,
                )
                response.use { currentResponse ->
                    val code = currentResponse.code
                    if (code in 300..399) {
                        val redirect = MpvExternalSubtitleTransport.redirectFor(
                            current = current,
                            location = currentResponse.header("Location"),
                            hop = hop,
                        ) ?: return null
                        current = redirect
                        return@repeat
                    }
                    if (code !in 200..299 || currentResponse.body?.contentLength()?.let { it > MAX_EXTERNAL_SUBTITLE_BYTES } == true) return null
                    temp = File.createTempFile("vortx-extsub-", ".$extension", appContext.cacheDir)
                    val complete = currentResponse.body?.byteStream()?.use { input ->
                        temp!!.outputStream().use outputUse@{ output ->
                            val buffer = ByteArray(16 * 1024)
                            var total = 0L
                            while (true) {
                                currentCoroutineContext().ensureActive()
                                val read = input.read(buffer)
                                if (read < 0) break
                                total += read
                                if (total > MAX_EXTERNAL_SUBTITLE_BYTES) return@outputUse false
                                output.write(buffer, 0, read)
                            }
                            total > 0
                        }
                    } ?: false
                    if (!complete) return null
                    if (temp!!.renameTo(target)) {
                        temp = null
                        return target
                    }
                    if (target.isFile && target.length() in 1..MAX_EXTERNAL_SUBTITLE_BYTES) return target
                    return null
                }
            }
            null
        } catch (error: Throwable) {
            MpvExternalSubtitleTransport.rethrowIfFatal(error)
            null
        } finally {
            temp?.delete()
        }
    }

    private suspend fun boundedContentSubtitleFile(source: String): File? {
        val uri = runCatching { android.net.Uri.parse(source) }.getOrNull() ?: return null
        val extension = uri.lastPathSegment?.substringAfterLast('.', "")
            ?.lowercase()?.takeIf { it in SUBTITLE_EXTENSIONS } ?: "srt"
        val target = File(appContext.cacheDir, "vortx-extsub-content-${MpvExternalSubtitleTransport.localCacheKey(source)}.$extension")
        if (target.isFile && target.length() in 1..MAX_EXTERNAL_SUBTITLE_BYTES) return target
        var temp: File? = null
        return try {
            temp = File.createTempFile("vortx-extsub-", ".$extension", appContext.cacheDir)
            val complete = copyBoundedContentSubtitle(
                openInput = { appContext.contentResolver.openInputStream(uri) },
                target = temp!!,
                maxBytes = MAX_EXTERNAL_SUBTITLE_BYTES,
                timeoutMs = EXTERNAL_SUBTITLE_TIMEOUT_MS.toLong(),
            )
            if (!complete) return null
            if (temp!!.renameTo(target)) {
                temp = null
                target
            } else {
                target.takeIf { it.isFile && it.length() in 1..MAX_EXTERNAL_SUBTITLE_BYTES }
            }
        } catch (error: Throwable) {
            MpvExternalSubtitleTransport.rethrowIfFatal(error)
            null
        } finally {
            temp?.delete()
        }
    }

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
        // WHY audit 13: this existing live style refresh is the settings-to-mpv property bridge. Re-read the
        // persisted toggle here so enabling or disabling late-night normalization does not require a restart.
        for ((name, value) in LoudnessNormalizationSetting.mpvOptions(appContext)) {
            mpv.setPropertyString(name, value)
        }
    }

    /// Apply the device audio-output mode live. `audio-channels` / `audio-spdif` are best-effort mid-file
    /// (mpv may only fully honor them on the next AO (re)open); applied as options pre-init for the reliable
    /// path. Mirrors Apple `setAudioOutputMode`.
    override fun setAudioOutputMode(mode: AudioOutputMode) {
        // Route-aware live properties: a Passthrough pick on a stereo-only route clears spdif and downmixes
        // instead of wedging the AO, matching the pre-init route-aware options and the Apple silence guard.
        for ((name, value) in mode.mpvLiveProperties(appContext)) {
            mpv.setPropertyString(name, value)
        }
        scheduleAudioOutputHealthCheck()
    }

    /// Re-read `stremiox.hdrToneMapMode` and apply the SDR-force (or HDR-passthrough) target-trc/target-prim
    /// live, so an in-player mode switch takes effect on the current frame. Mirrors Apple `setVideoSize`-style
    /// live property application for the tone-map decision.
    override fun applyHdrToneMap() {
        for ((name, value) in MpvConfig.hdrOutputOptions(
            com.vortx.android.player.extras.HdrToneMapSetting.forceSDR(appContext),
        )) {
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
        mpv.getPropertyString(PROP_CURRENT_AO)?.takeIf { it.isNotBlank() && it != "null" }
            ?.let { stats += "Audio output" to it }
        // Performance rows (the on-screen equivalent of a stats overlay): how many decoded frames mpv had to
        // drop to keep sync, and how many seconds of forward buffer the demuxer is holding ahead of the
        // playhead. Both surface a struggling device or a starving link at a glance. Mirrors the Apple
        // player's frame-drop / cache readout.
        mpv.getPropertyInt("frame-drop-count")?.takeIf { it >= 0 }
            ?.let { stats += "Dropped frames" to it.toString() }
        mpv.getPropertyDouble("demuxer-cache-duration")?.takeIf { it >= 0 }
            ?.let { stats += "Buffer ahead" to String.format("%.1fs", it) }
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

    /** WHY audit 05.4: per-load sizing alone cannot react to Android runtime pressure. Shed exactly one
     * DeviceMemoryTier rung per file, then restore once after sustained healthy playback. */
    @Synchronized
    override fun onTrimMemory(level: Int) {
        if (memoryShedConsumed) return
        val normal = normalReadAheadBytes ?: return
        val target = AdaptiveTuning.oneStepDownReadAheadBytes(appContext, normal)
        if (target >= normal) return

        memoryShedConsumed = true
        memoryShedActive = true
        memoryShedPositionMs = _state.value.positionMs
        activeReadAheadBytes = target
        if (!pausedCacheClamped) applyReadAheadCap(target)
        Log.i(TAG, "memory pressure level=$level shed read-ahead to ${target / BYTES_PER_MIB}MiB")
        memoryRecoveryJob = runtimePolicyScope.launch { awaitHealthyPlaybackAndRecover() }
    }

    private suspend fun awaitHealthyPlaybackAndRecover() {
        var healthyMs = 0L
        var progressed = false
        while (runtimePolicyScope.isActive) {
            delay(MEMORY_RECOVERY_SAMPLE_MS)
            val state = _state.value
            if (state.positionMs > memoryShedPositionMs) progressed = true
            val healthy = progressed && !state.isPaused && !state.isBuffering &&
                !state.hasError && !state.hasEnded
            healthyMs = if (healthy) healthyMs + MEMORY_RECOVERY_SAMPLE_MS else 0L
            if (healthyMs >= MEMORY_RECOVERY_HEALTHY_MS) {
                restoreMemoryShedOnce()
                return
            }
        }
    }

    @Synchronized
    private fun restoreMemoryShedOnce() {
        if (!memoryShedActive) return
        val normal = normalReadAheadBytes ?: return
        memoryShedActive = false
        activeReadAheadBytes = normal
        if (!pausedCacheClamped) applyReadAheadCap(normal)
        Log.i(TAG, "memory pressure recovery restored read-ahead to ${normal / BYTES_PER_MIB}MiB")
    }

    override fun onEnterBackground() {
        // Drop video decode off-screen either way (matches Apple enterBackground: `vid=no`), which saves
        // power while backgrounded. Pause the audio too ONLY when "keep playing in the background" is off.
        val pauseInBackground = !com.vortx.android.player.extras.KeepPlayingBackgroundSetting.isEnabled(appContext)
        if (pauseInBackground) pause()
        mpv.setPropertyString(PROP_VID, "no")
    }

    override fun onEnterForeground() {
        mpv.setPropertyString(PROP_VID, "auto")
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
    /// SAFETY GATE. [MpvConfig.HWDEC] is plain
    /// `mediacodec` (surface-direct), deliberately NOT `mediacodec-copy`, because the direct path is what
    /// carries HDR/DV to the panel. Surface-direct mediacodec hands decoded frames to the Android Surface
    /// without staging them in CPU-addressable memory. Entering mpv's synchronous screenshot command on
    /// that path is driver-dependent and can terminate the process rather than return an error. The guard
    /// below therefore permits only software or explicit copy-back decode. We do NOT switch normal playback
    /// to `mediacodec-copy`: that would trade the DV mandate for the preview mandate.
    ///
    /// Fail-soft on every step; never throws. The temp file is always cleaned up.
    override suspend fun captureFrameJpeg(maxWidth: Int): ByteArray? = withContext(Dispatchers.IO) {
        if (!canSafelyCaptureMpvFrame(mpv.getPropertyString(PROP_HWDEC_CURRENT))) {
            return@withContext null
        }
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

    /**
     * Verify that an audio-bearing file opened a real AO. One failure gets a decoded-stereo reopen;
     * a second failure enters the normal bad-source path instead of leaving a silent video running.
     */
    private fun scheduleAudioOutputHealthCheck(replaceExisting: Boolean = false) {
        val generation = subtitleLoadGeneration.get()
        synchronized(audioHealthLock) {
            if (released.get() || audioFileLoadedGeneration != generation) return
            if (audioHealthJob?.isActive == true) {
                if (!replaceExisting) return
            }
            // Begin the successor opportunity before cancelling its predecessor. A terminal racing the
            // handoff therefore remains held continuously until one explicit health verdict wins.
            val opportunity = failureCoordinator.beginOpportunity()
            audioHealthJob?.cancel()
            audioHealthJob = runtimePolicyScope.launch {
                verifyAudioOutput(generation, opportunity)
            }
        }
    }

    private suspend fun verifyAudioOutput(generation: Long, opportunity: Long) {
        var fallbackReason: EngineFallbackReason? = null
        try {
            delay(AUDIO_OUTPUT_SETTLE_MS)
            if (!audioOutputCheckActive(generation)) return

            var trackListAction = audioTrackListHealthAction(generation, timedOut = false)
            if (trackListAction == MpvAudioTrackListHealthAction.PENDING_TRACK_LIST) {
                delay(AUDIO_TRACK_LIST_WAIT_MS)
                if (!audioOutputCheckActive(generation)) return
                trackListAction = audioTrackListHealthAction(generation, timedOut = true)
            }
            if (trackListAction != MpvAudioTrackListHealthAction.CHECK_AUDIO_OUTPUT) return

            val initialAction = mpvAudioOutputHealthAction(
                hasAudioTrack = true,
                currentAo = mpv.getPropertyString(PROP_CURRENT_AO),
                outputChannelCount = mpv.getPropertyInt(PROP_AUDIO_OUTPUT_CHANNEL_COUNT),
                recoveryAttempted = audioRecoveryAttempted,
            )
            if (initialAction == MpvAudioOutputHealthAction.NONE) return
            if (initialAction == MpvAudioOutputHealthAction.FAIL_SOURCE) {
                fallbackReason = EngineFallbackReason.AUDIO_OUTPUT_FAILED
                return
            }

            synchronized(audioHealthLock) {
                if (!audioOutputCheckActive(generation) || audioRecoveryAttempted) return
                audioRecoveryAttempted = true
            }
            Log.w(TAG, "libmpv opened no audio output; retrying decoded stereo")
            for ((name, value) in safeMpvAudioRecoveryProperties()) {
                if (!audioOutputCheckActive(generation)) return
                mpv.setPropertyString(name, value)
            }

            delay(AUDIO_OUTPUT_RECOVERY_MS)
            if (!audioOutputCheckActive(generation)) return
            if (audioTrackListHealthAction(generation, timedOut = true) !=
                MpvAudioTrackListHealthAction.CHECK_AUDIO_OUTPUT
            ) return
            val recoveredAction = mpvAudioOutputHealthAction(
                hasAudioTrack = true,
                currentAo = mpv.getPropertyString(PROP_CURRENT_AO),
                outputChannelCount = mpv.getPropertyInt(PROP_AUDIO_OUTPUT_CHANNEL_COUNT),
                recoveryAttempted = true,
            )
            if (recoveredAction == MpvAudioOutputHealthAction.FAIL_SOURCE) {
                fallbackReason = EngineFallbackReason.AUDIO_OUTPUT_FAILED
            }
        } finally {
            applyFailureResolution(
                failureCoordinator.completeOpportunity(opportunity, fallbackReason),
            )
        }
    }

    private fun audioOutputCheckActive(generation: Long): Boolean {
        val state = _state.value
        return !released.get() && subtitleLoadGeneration.get() == generation &&
            audioFileLoadedGeneration == generation &&
            !state.hasError && !state.hasEnded
    }

    private fun audioTrackListHealthAction(
        generation: Long,
        timedOut: Boolean,
    ): MpvAudioTrackListHealthAction = synchronized(audioHealthLock) {
        val observed = audioTrackListObservedGeneration == generation
        mpvAudioTrackListHealthAction(
            trackListObserved = observed,
            hasAudioTrack = observed && audioTrackListHasAudio,
            timedOut = timedOut,
        )
    }

    override fun release() {
        if (!released.compareAndSet(false, true)) return
        synchronized(subtitleGenerationGate) {
            subtitleLoadGeneration.incrementAndGet()
        }
        // Retire every held terminal/opportunity before cancellation. A cancelled audio-health coroutine
        // runs its `finally` and may complete its old opportunity immediately; after reset that completion
        // is a no-op instead of publishing an EOF/error while teardown owns the player.
        terminalGate.release()
        failureCoordinator.reset()
        synchronized(audioHealthLock) {
            audioHealthJob?.cancel()
            audioHealthJob = null
            audioFileLoadedGeneration = 0L
            audioTrackListObservedGeneration = 0L
            audioTrackListHasAudio = false
        }
        subtitleLoadScope.cancel()
        runtimePolicyScope.cancel()
        mpv.removeObserver(observer)
        // Native destruction owns final cleanup of any still-attached surface. SurfaceHolder may deliver
        // surfaceDestroyed before or after this call; both paths are idempotent at the seam.
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
                    // Audio channel count for the fidelity tie-break (0 for subs; mpv reports none there).
                    channels = if (type == "audio") t.optInt("demux-channel-count", 0) else 0,
                )
                when (type) {
                    "audio" -> audio.add(entry)
                    "sub" -> subs.add(entry)
                }
            }
        }
        _state.update { it.copy(audioTracks = audio, subtitleTracks = subs) }
        trackListUpdated(audio.isNotEmpty())
    }

    /**
     * A valid track-list read is the boundary between "not available yet" and a real no-audio file.
     * Only the first audio-bearing transition rearms health work, preventing repeated property changes
     * from creating recovery loops. The generation fence drops a late old-source notification.
     */
    private fun trackListUpdated(hasAudioTrack: Boolean) {
        val generation = subtitleLoadGeneration.get()
        val shouldRearm = synchronized(audioHealthLock) {
            if (released.get() || audioFileLoadedGeneration != generation) return
            val firstObservation = audioTrackListObservedGeneration != generation
            val hadAudioTrack = audioTrackListHasAudio
            val rearm = shouldRearmMpvAudioHealthForTrackList(
                loadedGeneration = audioFileLoadedGeneration,
                callbackGeneration = generation,
                trackListPreviouslyObserved = !firstObservation,
                trackListPreviouslyHadAudio = hadAudioTrack,
                hasAudioTrack = hasAudioTrack,
            )
            audioTrackListObservedGeneration = generation
            audioTrackListHasAudio = audioTrackListHasAudio || hasAudioTrack
            rearm
        }
        // An empty first snapshot resolves the pending state in the existing bounded check. A later
        // audio-bearing update must rearm, even if that bounded check already accepted no audio.
        if (shouldRearm) scheduleAudioOutputHealthCheck(replaceExisting = true)
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
                            val opportunity = failureCoordinator.beginOpportunity()
                            val reason = attachMpvSurfaceOrFallback { mpv.attachSurface(holder.surface) }
                            applyFailureResolution(
                                failureCoordinator.completeOpportunity(opportunity, reason),
                            )
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
        private const val TAG = "VortxMpvPlayer"
        private const val BYTES_PER_MIB = 1024L * 1024
        private const val PAUSED_CACHE_CLAMP_BYTES = 48L * BYTES_PER_MIB
        private const val PAUSED_CACHE_CLAMP_GRACE_MS = 10_000L
        private const val MEMORY_RECOVERY_HEALTHY_MS = 30_000L
        private const val MEMORY_RECOVERY_SAMPLE_MS = 1_000L
        private const val MAX_EXTERNAL_SUBTITLE_BYTES = 8L * BYTES_PER_MIB
        private const val EXTERNAL_SUBTITLE_TIMEOUT_MS = 20_000
        private val SUBTITLE_EXTENSIONS = setOf("srt", "vtt", "ass", "ssa", "sub", "smi")

        // Observed property names (Apple MPVMetalViewController parity).
        private const val PROP_TIME_POS = "time-pos"
        private const val PROP_DURATION = "duration"
        private const val PROP_PAUSE = "pause"
        private const val PROP_PAUSED_FOR_CACHE = "paused-for-cache"
        private const val PROP_DEMUXER_CACHE_TIME = "demuxer-cache-time"
        private const val PROP_TRACK_LIST = "track-list"

        // Runtime property names.
        private const val PROP_AID = "aid"
        private const val PROP_SID = "sid"
        private const val PROP_SECONDARY_SID = "secondary-sid"
        private const val PROP_SUB_DELAY = "sub-delay"
        private const val PROP_AUDIO_DELAY = "audio-delay"
        private const val PROP_HWDEC = "hwdec"
        private const val PROP_HWDEC_CURRENT = "hwdec-current"
        private const val PROP_CURRENT_AO = "current-ao"
        private const val PROP_AUDIO_OUTPUT_CHANNEL_COUNT = "audio-out-params/channel-count"
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
        private const val OPT_DEMUXER_MAX_BYTES_CACHE = "demuxer-max-bytes-cache"
        // Per-file adaptive read-ahead SECONDS + cache window on the capable remote path (the base values
        // are pre-init options in [MpvConfig]; these override them from the adaptive plan).
        private const val OPT_DEMUXER_READAHEAD_SECS = "demuxer-readahead-secs"
        private const val OPT_CACHE_SECS = "cache-secs"

        /// Quality of mpv's full-resolution INTERMEDIATE grab. High on purpose: it is re-encoded below at
        /// [CAPTURE_JPEG_QUALITY] after downscaling, and compressing twice at the final quality would
        /// stack artifacts. The file is deleted in the same call, so its size never matters on disk.
        private const val SCREENSHOT_INTERMEDIATE_QUALITY = "90"
        private const val AUDIO_OUTPUT_SETTLE_MS = 2_500L
        private const val AUDIO_TRACK_LIST_WAIT_MS = 2_500L
        private const val AUDIO_OUTPUT_RECOVERY_MS = 2_500L

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
        private const val READ_AHEAD_LOCAL_BYTES = 96L * BYTES_PER_MIB

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

        /// Build an [MpvPlayer], applying config + init. Returns null if [MPVLib.create] has a recoverable
        /// native linkage or initialization failure, so [com.vortx.android.player.MpvEngineFactory]
        /// can fall back to ExoPlayer. Process-fatal failures and cancellation propagate.
        fun create(context: Context): MpvPlayer? {
            val appContext = context.applicationContext
            if (!MpvConfig.ensureSystemTrustStoreObserver(appContext)) return null
            val caBundlePath = MpvConfig.provisionSystemCaBundle(appContext) ?: return null
            val lib = recoverNativeFailure("native-create") {
                MPVLib.create(appContext)
            } ?: return null
            return recoverNativeFailure("mpv-init") {
                MpvPlayer(lib, appContext, caBundlePath)
            } ?: run {
                recoverNativeFailure("mpv-init") {
                    lib.destroy()
                    Unit
                }
                null
            }
        }
    }
}

private data class EngineTerminalVerdict(
    val hasEnded: Boolean,
    val hasError: Boolean,
    val isBuffering: Boolean,
)

/** Fatal-aware surface attach seam: expected runtime failures demote; process-fatal failures propagate. */
internal fun attachMpvSurfaceOrFallback(attach: () -> Unit): EngineFallbackReason? {
    val attached = recoverNativeFailure("mpv-init") {
        attach()
        true
    } ?: false
    return if (attached) null else EngineFallbackReason.SURFACE_ATTACH_FAILED
}

/**
 * Sidecar-only HTTP admission and cache identity. This deliberately remains separate from mpv's stream
 * properties: a subtitle credential must never be replayed against the video URL or written to libmpv.
 */
internal object MpvExternalSubtitleTransport {
    const val MAX_REDIRECTS = 5
    private const val MAX_HEADER_COUNT = 32
    private const val MAX_HEADER_BYTES = 8 * 1024
    private val HEADER_TOKEN = Regex("[!#$%&'*+.^_`|~0-9A-Za-z-]+")
    private val FORBIDDEN_HEADERS = setOf(
        "host", "content-length", "transfer-encoding", "connection", "keep-alive", "te",
        "trailer", "upgrade", "proxy-authorization", "proxy-connection",
    )

    internal data class Request(
        val uri: URI,
        val headers: Map<String, String>,
    )

    fun normalizedTracks(playable: Playable): List<ExternalSubtitle> =
        normalizedExternalSubtitles(playable).distinct()

    /** Schemeless and file references are offline media, never candidates for the remote HTTP transport. */
    fun localFileFor(source: String): File? {
        val uri = runCatching { URI(source) }.getOrNull()
        return when {
            uri?.scheme == null -> File(source)
            uri.scheme.equals("file", ignoreCase = true) -> runCatching { File(uri) }.getOrNull()
            else -> null
        }
    }

    fun isContentUri(source: String): Boolean = runCatching { URI(source).scheme.equals("content", ignoreCase = true) }
        .getOrDefault(false)

    fun localCacheKey(source: String): String = MessageDigest.getInstance("SHA-256")
        .digest(source.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    /** The public DNS result supplied to OkHttp is also the only address it may connect to. */
    fun protectedClient(timeoutMs: Long, dns: Dns = publicDns(timeoutMs)): OkHttpClient =
        OkHttpClient.Builder()
            .proxy(Proxy.NO_PROXY)
            .dns(dns)
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .build()

    /** Validate injected resolver answers too, so tests and future callers cannot bypass the DNS policy. */
    fun publicDns(
        timeoutMs: Long,
        resolver: (String) -> List<InetAddress> = PublicAddressPolicy::requirePublic,
    ): Dns = DeadlinePublicDns(timeoutMs) { host ->
        val addresses = resolver(host)
        if (addresses.isEmpty() || addresses.any(PublicAddressPolicy::isBlocked)) {
            throw UnknownHostException("Sidecar DNS returned a non-public address")
        }
        addresses
    }

    fun requestFor(subtitle: ExternalSubtitle): Request? {
        val uri = runCatching { URI(subtitle.url) }.getOrNull() ?: return null
        if (!CommunityJsUrlPolicy.isPublicHttpsUrl(subtitle.url) || uri.host.isNullOrBlank()) return null
        return Request(uri = uri, headers = sanitizeHeaders(subtitle.headers))
    }

    /** Only request identity headers that provider sidecars commonly require are admitted. */
    fun sanitizeHeaders(headers: Map<String, String>): Map<String, String> {
        if (headers.size > MAX_HEADER_COUNT) return emptyMap()
        var byteCount = 0
        val accepted = mutableListOf<Pair<String, String>>()
        for ((rawName, rawValue) in headers) {
            val name = rawName.trim()
            val value = rawValue.trim()
            val lowerName = name.lowercase()
            if (!HEADER_TOKEN.matches(name) || value.any(::isControl) || lowerName in FORBIDDEN_HEADERS) continue
            if (lowerName !in setOf("authorization", "referer", "user-agent") && !lowerName.startsWith("x-")) continue
            byteCount += name.toByteArray(Charsets.UTF_8).size + value.toByteArray(Charsets.UTF_8).size
            if (byteCount > MAX_HEADER_BYTES) return emptyMap()
            accepted += name to value
        }
        return accepted.sortedWith(compareBy<Pair<String, String>>({ it.first.lowercase() }, { it.second }))
            .toMap(LinkedHashMap())
    }

    fun cacheKey(request: Request): String {
        val digest = MessageDigest.getInstance("SHA-256")
        fun update(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            digest.update(java.nio.ByteBuffer.allocate(Int.SIZE_BYTES).putInt(bytes.size).array())
            digest.update(bytes)
        }
        update(request.uri.toString())
        request.headers.entries.sortedWith(compareBy({ it.key.lowercase() }, { it.value })).forEach { (name, value) ->
            update(name)
            update(value)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun redirectFor(current: Request, location: String?, hop: Int): Request? {
        if (hop >= MAX_REDIRECTS || location.isNullOrBlank() || location.any(::isControl)) return null
        val next = runCatching { current.uri.resolve(location) }.getOrNull() ?: return null
        if (!CommunityJsUrlPolicy.isPublicHttpsUrl(next.toString()) || next.host.isNullOrBlank()) return null
        return Request(
            uri = next,
            headers = if (sameOrigin(current.uri, next)) current.headers else emptyMap(),
        )
    }

    fun shouldMount(expectedGeneration: Long, currentGeneration: Long): Boolean =
        expectedGeneration == currentGeneration

    fun rethrowIfFatal(error: Throwable) {
        when (error) {
            is kotlinx.coroutines.CancellationException,
            is VirtualMachineError,
            is ThreadDeath -> throw error
        }
    }

    private fun sameOrigin(first: URI, second: URI): Boolean =
        first.scheme.equals(second.scheme, ignoreCase = true) &&
            first.host.equals(second.host, ignoreCase = true) &&
            effectivePort(first) == effectivePort(second)

    private fun effectivePort(uri: URI): Int = when {
        uri.port >= 0 -> uri.port
        uri.scheme.equals("https", ignoreCase = true) -> 443
        else -> -1
    }

    private fun isControl(character: Char): Boolean = character.code < 32 || character.code == 127
}

private suspend fun OkHttpClient.awaitResponse(request: Request, timeoutMs: Long): Response =
    suspendCancellableCoroutine { continuation ->
        val call = newCall(request)
        call.timeout().timeout(timeoutMs, TimeUnit.MILLISECONDS)
        val completed = AtomicBoolean(false)
        fun complete(result: Result<Response>) {
            if (completed.compareAndSet(false, true)) continuation.resumeWith(result)
        }
        continuation.invokeOnCancellation {
            completed.set(true)
            call.cancel()
        }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                complete(Result.failure(e))
            }

            override fun onResponse(call: Call, response: Response) {
                if (completed.compareAndSet(false, true)) {
                    // A cancellation may win after this callback receives ownership but before the
                    // suspended caller can enter its response.use block. Bind cleanup to resume itself
                    // so that race closes this exact response rather than leaking its socket/body.
                    continuation.resume(response) { _, delivered, _ -> delivered.close() }
                } else {
                    response.close()
                }
            }
        })
    }

/**
 * ContentResolver streams are provider-owned and can block outside coroutine cancellation. Keep that work
 * on one interruptible worker, then make cancellation and the cumulative deadline close the live stream.
 * Aborting also unlinks the temporary target immediately, so a hostile provider that ignores both close and
 * interrupt cannot leave a partial sidecar behind after the caller has timed out or moved on.
 */
internal suspend fun copyBoundedContentSubtitle(
    openInput: () -> InputStream?,
    target: File,
    maxBytes: Long,
    timeoutMs: Long,
): Boolean = suspendCancellableCoroutine { continuation ->
    val input = AtomicReference<InputStream?>()
    val future = AtomicReference<Future<*>?>()
    val completed = AtomicBoolean(false)
    val aborted = AtomicBoolean(false)
    val ioLock = Any()
    lateinit var deadline: ScheduledFuture<*>

    fun abort() {
        aborted.set(true)
        synchronized(ioLock) {
            runCatching { input.getAndSet(null)?.close() }
            target.delete()
        }
        future.get()?.cancel(true)
    }

    fun complete(result: Result<Boolean>): Boolean {
        if (completed.compareAndSet(false, true)) {
            deadline.cancel(false)
            continuation.resumeWith(result)
            return true
        }
        return false
    }

    continuation.invokeOnCancellation { abort() }
    deadline = CONTENT_COPY_DEADLINES.schedule(
        {
            if (completed.compareAndSet(false, true)) {
                abort()
                continuation.resumeWith(Result.failure(TimeoutException("content subtitle transfer exceeded deadline")))
            }
        },
        timeoutMs.coerceAtLeast(1L),
        TimeUnit.MILLISECONDS,
    )
    val worker = CONTENT_COPY_WORKER.submit {
        var success = false
        try {
            val opened = openInput() ?: run {
                complete(Result.success(false))
                return@submit
            }
            val output = synchronized(ioLock) {
                if (aborted.get()) {
                    runCatching { opened.close() }
                    null
                } else {
                    input.set(opened)
                    target.outputStream()
                }
            } ?: run {
                complete(Result.success(false))
                return@submit
            }
            opened.use { stream ->
                output.use outputUse@{ output ->
                    val buffer = ByteArray(16 * 1024)
                    var total = 0L
                    while (true) {
                        if (Thread.currentThread().isInterrupted) return@outputUse false
                        val read = stream.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > maxBytes) return@outputUse false
                        output.write(buffer, 0, read)
                    }
                    total > 0
                }
            }.also { success = it }
            complete(Result.success(success))
        } catch (error: Throwable) {
            complete(Result.failure(error))
        } finally {
            runCatching { input.getAndSet(null)?.close() }
            if (!success) target.delete()
        }
    }
    future.set(worker)
    if (aborted.get()) worker.cancel(true)
}

private val CONTENT_COPY_WORKER = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "vortx-content-subtitle-copy").apply { isDaemon = true }
}

private val CONTENT_COPY_DEADLINES = Executors.newSingleThreadScheduledExecutor { runnable ->
    Thread(runnable, "vortx-content-subtitle-deadline").apply { isDaemon = true }
}

internal fun requireMpvSecurityOption(name: String, result: Int) {
    check(result >= 0) {
        "required libmpv security option rejected: $name ($result)"
    }
}
