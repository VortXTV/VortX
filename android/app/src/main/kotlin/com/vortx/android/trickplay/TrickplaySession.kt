package com.vortx.android.trickplay

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Log
import com.vortx.android.model.MediaRef
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The per-title community-trickplay lifecycle: key it, FETCH the shared sheet so the viewer sees previews
 * immediately, buffer this device's captured frames, and UPLOAD them so the pool grows. One instance per
 * played title, owned by `PlayerScreen`.
 *
 * Android port of the community half of `app/SourcesShared/ScrubThumbnails.swift`
 * (`ScrubThumbnailsStore`), and the piece that makes [CommunityTrickplay] reachable at all: that client
 * shipped complete but with ZERO callers, so the HARD trickplay mandate ("capture and serve on every
 * platform"; acceptance: play 6 minutes anywhere and the pool row grows) was being violated by a
 * subsystem marked DONE. This class is the missing driver.
 *
 * SCOPE vs Apple, stated up front so the gap is not mistaken for parity. Apple's store is TWO layers:
 * an L1 community sheet AND a per-device local disk cache (`LocalTrickplayFrameCache`) that serves scrub
 * previews from this device's own captures when the pool has nothing. This port implements the COMMUNITY
 * layer only. A local disk cache is a separate, self-contained piece of work; leaving it out costs a
 * first-contributor their own previews (they still contribute, and every later viewer gets the sheet),
 * whereas leaving the community layer unwired costs the whole pool. Previews therefore come from the
 * community sheet or not at all.
 *
 * THREADING: the player calls [configure] / [recordFrame] / [finishAndFlush] from the Compose main
 * thread. Mutable state is confined behind [mutex] and every network/CPU step runs off the main thread
 * inside [CommunityTrickplay]. [previewAt] is the ONE synchronous read (the scrubber calls it per drag
 * frame, so it must never suspend or touch disk): it reads a `@Volatile` sheet reference and crops.
 *
 * FAIL-SOFT by contract, like the Swift original: any miss (no key, no imdb identity, no network, a
 * capture the engine cannot produce) silently leaves the viewer with no preview and the pool unchanged.
 * Nothing here can break playback.
 */
class TrickplaySession(context: Context) {

    private val context: Context = context.applicationContext

    /**
     * Internal scope, NOT one borrowed from composition, and that is load-bearing. The teardown flush is
     * fired from the player's `onDispose`, i.e. exactly when the player is leaving composition: launching
     * it into a `rememberCoroutineScope()` would cancel the upload the instant it started, silently
     * destroying the final (fullest) set of every session. A SupervisorJob on IO keeps a push alive past
     * teardown, the same reason [com.vortx.android.integrations.ScrobbleService] owns its own scope so its
     * `stop` still completes after the player is gone. Apple solves the identical problem with
     * `Task.detached`.
     */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val mutex = Mutex()

    /**
     * The fetched community sheet. `@Volatile` because [previewAt] reads it from the scrubber on the main
     * thread while the fetch coroutine writes it from IO. [CommunityTrickplay.Sheet] is immutable once
     * built, so a plain reference publish is safe: the reader either sees the old value (null) or the
     * fully-built new one, never a half-built sheet.
     */
    @Volatile
    private var sheet: CommunityTrickplay.Sheet? = null

    /** Identity of the title currently keyed. Guarded by [mutex]. */
    private var contentKey: String? = null
    private var imdbId: String? = null
    private var season: Int? = null
    private var episode: Int? = null
    private var durationBucket: Int = 0
    private var srcHeight: Int = 0

    /**
     * Frame count of the community set the L1 fetch returned (0 = none). We only upload when our own
     * capture is strictly FULLER than this, so a thin set gets improved while a full one is not needlessly
     * re-POSTed. Mirrors Apple's `communityExistingFrameCount` (the worker also keep-fuller-merges as a
     * race safety net).
     */
    private var existingFrameCount: Int = 0

    /** Raw JPEG frames captured THIS session, the time-ordered build input for the sprite sheet. */
    private val frames = mutableListOf<CommunityTrickplay.CapturedFrame>()

    /** Frame count at the last upload, so a flush skips a re-send when no new coverage arrived. */
    private var lastUploadedCount: Int = 0

    /**
     * [SystemClock.elapsedRealtime] ms of the last progressive push; 0 = none yet. MONOTONIC (not wall
     * clock) so a clock change can neither wedge nor fast-forward the gate, exactly as Apple uses
     * `DispatchTime.now().uptimeNanoseconds` rather than a `Date`.
     */
    private var lastUploadUptimeMs: Long = 0L

    /** True while a push is building/POSTing, so a burst of captures cannot spawn overlapping re-encodes. */
    private var uploadInFlight: Boolean = false

    /** The raw `tmdb:` id already sent for resolution, so per-tick calls mint exactly ONE network lookup. */
    private var resolveTriedFor: String? = null

    /**
     * Key this title and kick off the L1 community fetch. Idempotent: safe to call on every duration tick
     * (the player does), and a no-op once keyed on the same content key.
     *
     * IDENTITY, and the known past root cause this exists to avoid. A hub / TMDB-catalog play carries a
     * `tmdb:NNN` id, NOT a `tt…` id, and [CommunityTrickplay.contentKey] hard-requires a real `tt…` id.
     * Dropping those plays is precisely the bug that left an account contributing NOTHING from any device
     * despite trickplay being "done". So a tmdb id is resolved through [TmdbImdbResolver] (cached
     * in-memory + on disk, so at most one lookup per title per install) and we re-enter with the tt id.
     * A cached mapping resolves inline with no network at all.
     *
     * DIVERGENCE from Apple, deliberate. Apple keys TWICE: first provisionally off `meta.runtime` (so
     * capture can start before mpv reports a duration, since a debrid MKV may never emit mpv's `duration`
     * event), then again on the real duration. This port keys ONCE, off the engine's real reported
     * duration, because the Android [com.vortx.android.model.Playable] carries no runtime estimate to key
     * provisionally FROM. That is the same gate the already-shipped skip-segment wiring in `PlayerScreen`
     * uses (`durationMs > 0`), so it is the established local contract, not a new risk. The cost is real
     * and worth naming: a stream whose engine never reports a duration contributes nothing. Closing that
     * needs a runtime estimate plumbed onto `Playable`, which is a metadata-layer change, not a player one.
     */
    fun configure(mediaRef: MediaRef?, durationSeconds: Double) {
        if (!CommunityTrickplay.isEnabled(context)) return
        val ref = mediaRef ?: return
        if (durationSeconds <= 0.0) return

        scope.launch {
            // Prefer the tt id the ref already carries; otherwise resolve the tmdb fallback identity.
            val tt = ref.imdb?.takeIf { it.startsWith("tt") } ?: resolveTt(ref) ?: return@launch
            keyAndFetch(tt, ref.season, ref.episode, durationSeconds)
        }
    }

    /**
     * The tt id for a tmdb-keyed ref, or null. Checks the process-wide cache first (no network), then
     * mints at most ONE lookup per raw id per session: [resolveTriedFor] is deliberately NOT cleared on
     * failure, so a title whose lookup misses stops re-firing it and the session stays local-only, exactly
     * like Apple's `communityResolveTriedFor`.
     */
    private suspend fun resolveTt(ref: MediaRef): String? {
        val tmdb = ref.tmdb ?: return null
        val rawId = "tmdb:$tmdb"
        CommunityTrickplay.cachedImdbId(rawId)?.let { return it }
        mutex.withLock {
            if (resolveTriedFor == rawId) return null
            resolveTriedFor = rawId
        }
        val tt = CommunityTrickplay.resolveImdbId(context, rawId, seriesHint = ref.isSeries)
        if (tt == null) Log.d(TAG, "tmdb->imdb resolve FAILED for $rawId (session contributes nothing)")
        return tt
    }

    /** Compute the content key and, if it changed, fetch the community sheet for it. */
    private suspend fun keyAndFetch(tt: String, s: Int?, e: Int?, durationSeconds: Double) {
        val key = CommunityTrickplay.contentKey(tt, s, e, durationSeconds) ?: run {
            Log.d(TAG, "community NOT keyed (need tt id + duration>0): imdb=$tt dur=${durationSeconds.toInt()}")
            return
        }
        val rekeying = mutex.withLock {
            if (contentKey == key) return                    // already keyed on this exact title
            val wasKeyed = contentKey != null
            contentKey = key
            imdbId = tt
            season = s
            episode = e
            durationBucket = CommunityTrickplay.durationBucket(durationSeconds)
            // A re-key under a new bucket invalidates the fetched sheet (it belonged to the old key).
            // Captured frames stay valid: they are time-indexed, not bucket-indexed.
            if (wasKeyed) existingFrameCount = 0
            wasKeyed
        }
        if (rekeying) sheet = null
        Log.d(TAG, "community ${if (rekeying) "re-keyed" else "keyed"}: $key (imdb=$tt)")

        val fetched = CommunityTrickplay.fetch(key) ?: return
        // The title may have changed while the fetch was in flight; only publish if still current.
        mutex.withLock {
            if (contentKey != key) return
            existingFrameCount = fetched.frameCount
        }
        sheet = fetched
        Log.d(TAG, "community sheet HIT key=$key frames=${fetched.frameCount}")
    }

    /**
     * The scrub preview for [timeSeconds], or null when this title has no community sheet. Synchronous and
     * allocation-light by design: the scrubber calls this on the main thread for every drag frame, so it
     * must never suspend, hit the network, or touch disk. Mirrors the community fast path of Apple's
     * `ScrubThumbnailsStore.show(time:)`.
     */
    fun previewAt(timeSeconds: Double): Bitmap? = sheet?.crop(timeSeconds)

    /**
     * Record one captured frame and, if the gates allow, push the set. [jpeg] is the raw encoded frame
     * from `PlayerEngine.captureFrameJpeg`; [timeSeconds] is the playhead it was grabbed at.
     *
     * The near-black guard runs FIRST and is the safety valve for the one thing that cannot be verified
     * without a device (see `MpvPlayer.captureFrameJpeg`): if surface-direct `hwdec=mediacodec` yields
     * unrendered frames, they are dropped HERE and never reach the shared pool. Failing closed matters
     * more than usual because this pool is READ BY APPLE AND WEB CLIENTS TOO: uploading black tiles would
     * not just waste a POST, it would poison other platforms' previews for that title.
     */
    fun recordFrame(jpeg: ByteArray, timeSeconds: Double, videoHeight: Int) {
        scope.launch {
            if (!keepFrame(jpeg, timeSeconds)) return@launch
            val push = mutex.withLock {
                if (contentKey == null) return@launch
                // Remember the source height HERE rather than reading it off the engine at teardown: the
                // engine is being released around then, and a property read against a destroyed native mpv
                // handle is a segfault, which no runCatching can save. A frame we hold is proof the engine
                // was alive and rendering when this height was read.
                if (videoHeight > 0) srcHeight = videoHeight
                // Bound the buffer; the worker caps at 600 tiles anyway (CommunityTrickplay.MAX_FRAMES).
                if (frames.size >= MAX_SESSION_FRAMES) return@launch
                frames += CommunityTrickplay.CapturedFrame(time = timeSeconds, jpeg = jpeg)
                uploadDecision(progressive = true)
            }
            push?.let { pushUpload(it) }
        }
    }

    /**
     * Whether a captured frame is real video rather than an unrendered black grab. Ports Apple's
     * `decodeCapturedFrame` verdict, including its SIZE-BASED OVERRIDE: a real detailed frame
     * JPEG-compresses to tens of KB while a truly black one compresses to ~2-4 KB, so a frame at or above
     * [NON_BLACK_BYTE_FLOOR] is definitely real no matter what the pixel sampler reads, and we only drop
     * when BOTH the sampler says black AND the encoded size is small. Apple learned that the hard way:
     * an over-eager sampler silently discarded every frame on the owner's device.
     *
     * Runs the decode off the main thread. Logs every frame's fate so a silent pool stays traceable from
     * `adb logcat -s trickplay` alone, matching the Apple probe.
     */
    private suspend fun keepFrame(jpeg: ByteArray, timeSeconds: Double): Boolean = withContext(Dispatchers.Default) {
        val bigEnoughToBeReal = jpeg.size >= NON_BLACK_BYTE_FLOOR
        val samplerBlack = if (bigEnoughToBeReal) false else isBlackJpeg(jpeg)
        val kept = bigEnoughToBeReal || !samplerBlack
        Log.d(TAG, "frame at ${timeSeconds.toInt()}s bytes=${jpeg.size} samplerBlack=$samplerBlack kept=$kept")
        kept
    }

    /**
     * Samples five points and calls the frame black when four or more are near-black, the same shape and
     * thresholds as Apple's `isBlackImage`. Android needs no format guard: [Bitmap.getPixel] normalises
     * whatever the decoder produced to sRGB ARGB_8888, so the raw-buffer striding hazard that made Apple's
     * sampler misfire on 10-bit/HDR frames does not exist here. Any decode failure returns false (NOT
     * black), so a frame is never discarded on a format we could not read.
     */
    private fun isBlackJpeg(jpeg: ByteArray): Boolean {
        val bmp = runCatching { BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) }.getOrNull() ?: return false
        try {
            val w = bmp.width
            val h = bmp.height
            if (w <= 0 || h <= 0) return false
            val points = listOf(
                w / 4 to h / 4, 3 * w / 4 to h / 4, w / 2 to h / 2,
                w / 4 to 3 * h / 4, 3 * w / 4 to 3 * h / 4,
            )
            val blackCount = points.count { (x, y) ->
                val p = bmp.getPixel(x.coerceIn(0, w - 1), y.coerceIn(0, h - 1))
                ((p shr 16) and 0xFF) < BLACK_THRESHOLD &&
                    ((p shr 8) and 0xFF) < BLACK_THRESHOLD &&
                    (p and 0xFF) < BLACK_THRESHOLD
            }
            return blackCount >= 4
        } finally {
            bmp.recycle()
        }
    }

    /**
     * Teardown flush: send the FULL session set if it grew since the last progressive push. Called when the
     * player leaves composition. Apple pushes progressively DURING playback precisely because a teardown
     * may never fire (movie ends, sleep, auto-advance, or the process is killed), so this is the backstop,
     * not the primary path.
     *
     * Takes NO engine argument on purpose: it is called while the player is being torn down, so it must not
     * touch the engine at all (the source height is already banked by [recordFrame]). Never throttled --
     * this is the last chance to store the fullest set.
     */
    fun finishAndFlush() {
        scope.launch {
            val push = mutex.withLock { uploadDecision(progressive = false) } ?: return@launch
            pushUpload(push)
        }
    }

    /**
     * Evaluate every upload gate and return the push to make, or null. MUST be called holding [mutex].
     * Each clause is named so the probe below reports exactly WHY a tick did or did not upload, which is
     * how an empty pool gets diagnosed from a log instead of a guess. Mirrors Apple's
     * `maybeUploadProgressively` / `finishAndUploadIfNeeded`, which share these gates.
     */
    private fun uploadDecision(progressive: Boolean): PendingUpload? {
        val key = contentKey
        val imdb = imdbId
        val now = SystemClock.elapsedRealtime()
        val hasKey = key != null && imdb != null
        // Keep-fuller: never spend a POST that could not improve on the stored set.
        val beatsStored = frames.size > existingFrameCount
        val hasNewCoverage = frames.size > lastUploadedCount
        // The sheet builder floors at 2 tiles (buildAndUpload's `while budget >= 2`), so a lone frame is
        // structurally unbuildable and admitting it only reproduces a noisy sorted=1 failure.
        val enoughToBuild = frames.size >= 2
        // Progressive pushes are throttled; a teardown flush is the last chance and is never throttled.
        val throttleElapsed = !progressive || lastUploadUptimeMs == 0L ||
            now - lastUploadUptimeMs >= MIN_UPLOAD_INTERVAL_MS
        // Predict the Worker's coverage verdict so a doomed POST is skipped rather than sent and rejected.
        // Fails OPEN on an unknown bucket, so this only skips uploads we can positively call dead.
        val coverageReady = CommunityTrickplay.uploadCanStore(frames.size, CAPTURE_INTERVAL_S, durationBucket)
        val willUpload = hasKey && beatsStored && hasNewCoverage && enoughToBuild &&
            throttleElapsed && coverageReady && !uploadInFlight
        Log.d(
            TAG,
            "upload-gate(${if (progressive) "progressive" else "teardown"}) frames=${frames.size} " +
                "existing=$existingFrameCount lastUploaded=$lastUploadedCount hasKey=$hasKey " +
                "imdb=${imdb ?: "nil"} beatsStored=$beatsStored hasNewCoverage=$hasNewCoverage " +
                "enoughToBuild=$enoughToBuild throttleElapsed=$throttleElapsed coverageReady=$coverageReady " +
                "inFlight=$uploadInFlight -> ${if (willUpload) "UPLOAD" else "skip"}",
        )
        if (!willUpload || key == null || imdb == null) return null
        // Stamp the throttle + uploaded count NOW (still under the lock) so a concurrent tick cannot pick
        // the same coverage up again before the POST returns.
        lastUploadedCount = frames.size
        lastUploadUptimeMs = now
        uploadInFlight = true
        return PendingUpload(
            key = key, imdb = imdb, season = season, episode = episode,
            durationBucket = durationBucket, srcHeight = srcHeight, frames = frames.toList(),
        )
    }

    /** Build + POST off the main thread, then clear the in-flight latch. Fail-soft; never throws. */
    private suspend fun pushUpload(push: PendingUpload) {
        Log.d(TAG, "pushUpload FIRING key=${push.key} imdb=${push.imdb} frames=${push.frames.size}")
        val outcome = CommunityTrickplay.buildAndUpload(
            context = context,
            key = push.key,
            imdbId = push.imdb,
            season = push.season,
            episode = push.episode,
            durationBucket = push.durationBucket,
            srcHeight = push.srcHeight,
            intervalS = CAPTURE_INTERVAL_S,
            frames = push.frames,
        )
        // Honest result labels: a 200 the Worker consciously declined is "rejected(reason)", NOT "failed".
        // "failed" is reserved for a transport error, a non-200, or a local build that never POSTed.
        val label = when (outcome) {
            is CommunityTrickplay.UploadOutcome.Stored -> "stored"
            is CommunityTrickplay.UploadOutcome.Rejected -> "rejected(${outcome.reason})"
            is CommunityTrickplay.UploadOutcome.Failed -> "failed"
        }
        Log.d(TAG, "upload key=${push.key} frames=${push.frames.size} -> $label")
        mutex.withLock { uploadInFlight = false }
    }

    /** The immutable snapshot handed to a push, so the build never races the live [frames] buffer. */
    private data class PendingUpload(
        val key: String,
        val imdb: String,
        val season: Int?,
        val episode: Int?,
        val durationBucket: Int,
        val srcHeight: Int,
        val frames: List<CommunityTrickplay.CapturedFrame>,
    )

    companion object {
        private const val TAG = "trickplay"

        /**
         * Capture cadence in seconds, and therefore also the sheet/vtt tile interval: the two MUST agree
         * or the community sheet's timings are wrong for every consumer. 10.0 == Apple's shipping
         * `RemoteConfigDefaults.captureIntervalSecs`. Apple reads it from a fleet dial (clamped 2..60);
         * Android has no remote-config surface, so the baked default is used directly, exactly as
         * [CommunityTrickplay] does for its own endpoint.
         */
        const val CAPTURE_INTERVAL_S: Double = 10.0

        /** Progressive pushes: at most one per minute. Apple's `minUploadIntervalS`. */
        private const val MIN_UPLOAD_INTERVAL_MS: Long = 60_000L

        /** Session frame buffer bound; the Worker caps at 600 tiles regardless. Apple's literal. */
        private const val MAX_SESSION_FRAMES = 600

        /** Apple's `nonBlackByteFloor`: at/above this an encoded frame is definitely real detail. */
        private const val NON_BLACK_BYTE_FLOOR = 8_000

        /** Apple's per-channel near-black threshold. */
        private const val BLACK_THRESHOLD = 30
    }
}
