package com.vortx.android.trickplay

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Log
import com.vortx.android.model.MediaRef
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

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
 * SCOPE vs Apple. Apple's store is TWO layers: an L1 community sheet AND a per-device local disk cache
 * (`LocalTrickplayFrameCache`) that serves scrub previews from this device's own captures when the pool has
 * nothing. BOTH are now ported: [previewAt] returns the community crop when the pool has one, else this
 * device's own frame from [LocalTrickplayFrameCache], so a first-contributor gets their own previews (and
 * every later viewer still gets the shared sheet). Previews come from the community sheet, the local cache,
 * or -- only when neither has a frame yet -- nothing.
 *
 * THREADING: the player calls [configure] / [recordFrame] / [finishAndFlush] from the Compose main
 * thread. Mutable state is confined behind [publication]'s short monitor and every network/CPU step runs off the main thread
 * inside [CommunityTrickplay]. [previewAt] is the ONE synchronous read (the scrubber calls it per drag
 * frame, so it must never suspend or touch disk): it reads one immutable preview snapshot and crops.
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

    private val publication = TrickplayPublication<CommunityTrickplay.Sheet>()
    private var sourceOwner: TrickplayPublication.SourceClaim? = null

    /** Orders frame admission and the final snapshot by call time, and closes admission at teardown. */
    private val admissionQueue = TrickplayAdmissionQueue(scope)

    /** Per-device local frame cache, behind the immutable community preview snapshot. */
    private val localCache = LocalTrickplayFrameCache(context)

    /** Refreshes a stationary scrub after a sheet or local frame becomes available. */
    private val previewRevisionState = MutableStateFlow(0L)
    val previewRevision: StateFlow<Long> = previewRevisionState.asStateFlow()
    private fun previewChanged() { previewRevisionState.update { it + 1L } }

    /** Identity of the title currently keyed. Guarded by [publication]'s monitor. */
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

    /** Monotonic revision of the retained frame content, including same-count replacement after the cap. */
    private var retainedRevision: Long = 0L

    /** Owns one active upload and one exact deferred teardown snapshot. */
    private val uploadCoordinator = TrickplayUploadCoordinator()
    private var deferredUpload: PendingUpload? = null

    /**
     * [SystemClock.elapsedRealtime] ms of the last progressive push; 0 = none yet. MONOTONIC (not wall
     * clock) so a clock change can neither wedge nor fast-forward the gate, exactly as Apple uses
     * `DispatchTime.now().uptimeNanoseconds` rather than a `Date`.
     */
    private var lastUploadUptimeMs: Long = 0L

    /** One original-source lookup shared by later duration buckets, never a per-clock-tick request. */
    private val resolution = TrickplayResolution(publication)

    /** Invalidates every contribution admitted before an opt-out, even if the viewer opts back in later. */
    private val consentGate = TrickplayConsentGate()
    private val activeRequests = ConcurrentHashMap.newKeySet<CommunityTrickplayRequestControl>()
    private val consentObserver = CommunityTrickplay.observeEnabled(context) { enabled ->
        if (!enabled) revokeContributionConsent()
    }

    private fun contributionIsCurrent(generation: Long): Boolean =
        consentGate.permits(generation) && CommunityTrickplay.isEnabled(context)

    /** Stop active fetch/build/upload work and discard frames that were captured under revoked consent. */
    private fun revokeContributionConsent() {
        val revokedRequests = publication.withState {
            consentGate.revoke()
            publication.invalidate()
            previewChanged()
            resetRetainedState()
            sourceOwner = null
            resolution.reset()
            deferredUpload = null
            uploadCoordinator.revokeAdmissions()
            // Concurrent job-finally removals may shrink this CHM view after a size probe.
            // Iterate its weakly consistent iterator directly; Collection.toList's singleton
            // shortcut can otherwise call next() on an already-empty view.
            val requestsToRevoke = buildList {
                val requests = activeRequests.iterator()
                while (requests.hasNext()) add(requests.next())
            }
            // Capture before cancellation can deregister an old request in its finally block.
            // The same monitor excludes new-source admissions until old children are cancelled;
            // actual network disconnection remains outside this monitor below.
            scope.coroutineContext.cancelChildren()
            requestsToRevoke
        }
        // Disconnect only the captured old set, never a request registered after re-enabling.
        revokedRequests.forEach(CommunityTrickplayRequestControl::cancel)
    }

    /** Called under the publication monitor; retainedRevision stays monotonic across resets. */
    private fun resetRetainedState() {
        contentKey = null
        imdbId = null
        season = null
        episode = null
        durationBucket = 0
        srcHeight = 0
        existingFrameCount = 0
        frames.clear()
        lastUploadUptimeMs = 0L
    }

    private fun requestControl(request: TrickplayPublication.Request): CommunityTrickplayRequestControl? =
        publication.withState {
            if (!publication.isCurrent(request) ||
                !contributionIsCurrent(request.source.consentGeneration)
            ) return@withState null
            CommunityTrickplayRequestControl().also { activeRequests += it }
        }

    private fun resolutionControl(source: TrickplayPublication.SourceClaim): CommunityTrickplayRequestControl? =
        publication.withState {
            if (publication.captureSource() !== source || !contributionIsCurrent(source.consentGeneration)) {
                null
            } else {
                CommunityTrickplayRequestControl().also { activeRequests += it }
            }
        }

    private fun requestIsCurrent(request: TrickplayPublication.Request): Boolean =
        publication.withState {
            publication.isCurrent(request) && contributionIsCurrent(request.source.consentGeneration)
        }

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
        if (!durationSeconds.isFinite() || durationSeconds <= 0.0) return
        val request = publication.withState {
            if (!CommunityTrickplay.isEnabled(context)) return@withState null
            publication.configure(
                identity = TrickplayPublication.SourceIdentity(
                    isSeries = ref.isSeries,
                    imdb = ref.imdb?.takeIf { it.startsWith("tt") },
                    tmdb = ref.tmdb,
                    season = ref.season,
                    episode = ref.episode,
                ),
                generation = consentGate.admit(),
                bucket = CommunityTrickplay.durationBucket(durationSeconds),
            )
        } ?: return

        scope.launch {
            if (!requestIsCurrent(request)) return@launch
            // Prefer the tt id the ref already carries; otherwise resolve the tmdb fallback identity.
            val tt = ref.imdb?.takeIf { it.startsWith("tt") } ?: resolveTt(ref, request) ?: return@launch
            if (!requestIsCurrent(request)) return@launch
            keyAndFetch(tt, ref.season, ref.episode, durationSeconds, request)
        }
    }

    /**
     * The tt id for a tmdb-keyed ref, or null. Checks the process-wide cache first (no network), then
     * mints at most ONE lookup per source/consent admission. A newer duration request awaits that same
     * result rather than being stranded when the old request loses its final publication claim. Misses
     * remain settled for that source, like Apple's `communityResolveTriedFor`.
     */
    private suspend fun resolveTt(ref: MediaRef, request: TrickplayPublication.Request): String? {
        val tmdb = ref.tmdb ?: return null
        val rawId = "tmdb:$tmdb"
        CommunityTrickplay.cachedImdbId(rawId)?.let { return it }
        val admission = resolution.admit(request) ?: return null
        if (!admission.startsLookup) return admission.lookup.result.await()
        var resolved: String? = null
        val requestControl = resolutionControl(admission.lookup.source)
        try {
            if (requestControl != null) {
                resolved = CommunityTrickplay.resolveImdbId(context, rawId, ref.isSeries, requestControl)
            }
            if (resolved == null) Log.d(TAG, "tmdb->imdb resolve FAILED for $rawId (session contributes nothing)")
            return resolved
        } finally {
            requestControl?.let { activeRequests -= it }
            // Completes even if the winning lookup was cancelled. Waiters retain their own original
            // request/source claim and must pass it after this suspension before binding any key.
            admission.lookup.result.complete(resolved)
        }
    }

    /** Compute the content key and, if it changed, fetch the community sheet for it. */
    private suspend fun keyAndFetch(
        tt: String,
        s: Int?,
        e: Int?,
        durationSeconds: Double,
        request: TrickplayPublication.Request,
    ) {
        if (!requestIsCurrent(request)) return
        val key = CommunityTrickplay.contentKey(tt, s, e, durationSeconds) ?: run {
            Log.d(TAG, "community NOT keyed (need tt id + duration>0): imdb=$tt dur=${durationSeconds.toInt()}")
            return
        }
        val rekeying = publication.withState {
            if (!requestIsCurrent(request)) return@withState null
            if (sourceOwner !== request.source) {
                resetRetainedState()
                sourceOwner = request.source
            }
            val wasKeyed = contentKey != null
            contentKey = key
            imdbId = tt
            season = s
            episode = e
            durationBucket = CommunityTrickplay.durationBucket(durationSeconds)
            // A re-key under a new bucket invalidates the fetched sheet (it belonged to the old key).
            // Captured frames stay valid: they are time-indexed, not bucket-indexed.
            if (wasKeyed) existingFrameCount = 0
            if (!publication.bind(request, key)) return@withState null
            previewChanged()
            wasKeyed
        } ?: return
        // Publish the local-cache key and warm this device's own frames for it from disk, so a re-opened
        // title serves the viewer's previous previews before any fresh capture lands.
        localCache.warm(key) { requestIsCurrent(request) }
        if (!requestIsCurrent(request)) return
        previewChanged()
        Log.d(TAG, "community ${if (rekeying) "re-keyed" else "keyed"}: $key (imdb=$tt)")

        val requestControl = requestControl(request) ?: return
        val fetched = try {
            CommunityTrickplay.fetch(key, requestControl)
        } finally {
            activeRequests -= requestControl
        } ?: return
        // The title may have changed while the fetch was in flight; only publish if still current.
        val accepted = publication.withState {
            if (!requestIsCurrent(request) || contentKey != key ||
                !publication.publish(request, key, fetched)
            ) return@withState false
            existingFrameCount = fetched.frameCount
            previewChanged()
            true
        }
        if (accepted) Log.d(TAG, "community sheet HIT key=$key frames=${fetched.frameCount}")
    }

    /**
     * The scrub preview for [timeSeconds], or null when this title has no community sheet. Synchronous and
     * allocation-light by design: the scrubber calls this on the main thread for every drag frame, so it
     * must never suspend, hit the network, or touch disk. Mirrors the community fast path of Apple's
     * `ScrubThumbnailsStore.show(time:)`.
     */
    fun previewAt(timeSeconds: Double): Bitmap? {
        val expected = publication.snapshot() ?: return null
        if (!consentGate.permits(expected.request.source.consentGeneration)) return null
        // Both layers are derived from ONE identity. Neither cropping nor the resident-cache read holds
        // the metadata monitor, and neither performs disk or network I/O.
        // Like Apple, prefer exact community coverage and local captures before an approximate
        // resident community tile. The seek destination stays [timeSeconds], not the tile's time.
        val result = expected.sheet?.crop(timeSeconds) ?: localCache.previewAt(expected.key, timeSeconds)
            ?: expected.sheet?.nearestCrop(timeSeconds)
        return publication.withState {
            if (publication.isCurrent(expected) &&
                consentGate.permits(expected.request.source.consentGeneration)
            ) result else null
        }
    }

    /**
     * Worker-owned scrub resolution. Exact community coverage still wins; a resident local miss can
     * consult the requested disk range before falling back to an approximate community tile. The one
     * original immutable publication claim fences every suspension and the final result.
     */
    suspend fun loadPreviewAt(timeSeconds: Double): Bitmap? = withContext(Dispatchers.Default) {
        currentCoroutineContext().ensureActive()
        if (!timeSeconds.isFinite() || timeSeconds < 0.0) return@withContext null
        val expected = publication.snapshot() ?: return@withContext null
        fun isCurrent(): Boolean = publication.withState {
            publication.isCurrent(expected) && contributionIsCurrent(expected.request.source.consentGeneration)
        }
        if (!isCurrent()) return@withContext null
        val result = expected.sheet?.crop(timeSeconds) ?: localCache.previewAt(expected.key, timeSeconds)
            ?: localCache.loadPreviewAt(expected.key, timeSeconds, ::isCurrent)
            ?: expected.sheet?.nearestCrop(timeSeconds)
        currentCoroutineContext().ensureActive()
        publication.withState { if (isCurrent()) result else null }
    }

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
        if (!CommunityTrickplay.isEnabled(context)) return
        val source = publication.withState {
            publication.captureSource()?.takeIf { contributionIsCurrent(it.consentGeneration) }
        } ?: return
        admissionQueue.enqueue {
            if (!contributionIsCurrent(source.consentGeneration)) return@enqueue
            if (!keepFrame(jpeg, timeSeconds)) return@enqueue
            val admitted = publication.withState {
                if (!publication.isCurrent(source) || sourceOwner !== source ||
                    !contributionIsCurrent(source.consentGeneration)
                ) return@withState null
                val key = contentKey ?: return@withState null
                // Remember the source height HERE rather than reading it off the engine at teardown: the
                // engine is being released around then, and a property read against a destroyed native mpv
                // handle is a segfault, which no runCatching can save. A frame we hold is proof the engine
                // was alive and rendering when this height was read.
                if (videoHeight > 0) srcHeight = videoHeight
                // Keep a bounded sample across the whole observed timeline. Once full, every later
                // capture is admitted and the most temporally redundant interior frame is evicted, so
                // long titles retain both their opening and current endpoint instead of freezing at the
                // first 100 minutes.
                val candidates = frames + CommunityTrickplay.CapturedFrame(time = timeSeconds, jpeg = jpeg)
                val retained = TrickplayTimeline.retainedIndices(candidates.map { it.time }, MAX_SESSION_FRAMES)
                val nextFrames = retained.map { candidates[it] }
                val push = if (sameRetainedContent(frames, nextFrames)) null else {
                    frames.clear()
                    frames += nextFrames
                    retainedRevision += 1L
                    uploadDecision(progressive = true, source = source)
                }
                key to push
            }
            admitted?.let { (key, push) ->
                // Use the key admitted with THIS frame, never a later title's volatile local key.
                localCache.store(key, timeSeconds, jpeg)
                publication.withState {
                    if (publication.isCurrent(source) && sourceOwner === source &&
                        contributionIsCurrent(source.consentGeneration)
                    ) previewChanged()
                }
                push?.let(::launchUpload)
            }
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

    private fun sameRetainedContent(
        first: List<CommunityTrickplay.CapturedFrame>,
        second: List<CommunityTrickplay.CapturedFrame>,
    ): Boolean = first.size == second.size && first.indices.all { index ->
        first[index].time == second[index].time && first[index].jpeg.contentEquals(second[index].jpeg)
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
        publication.withState {
            val source = publication.close()
            previewChanged()
            admissionQueue.closeAndEnqueue {
                val push = publication.withState {
                    source?.let { uploadDecision(progressive = false, source = it) }
                }
                push?.let(::launchUpload)
            }
        }
    }

    /**
     * Evaluate every upload gate and return the push to make, or null. MUST hold the publication monitor.
     * Each clause is named so the probe below reports exactly WHY a tick did or did not upload, which is
     * how an empty pool gets diagnosed from a log instead of a guess. Mirrors Apple's
     * `maybeUploadProgressively` / `finishAndUploadIfNeeded`, which share these gates.
     */
    private fun uploadDecision(progressive: Boolean, source: TrickplayPublication.SourceClaim): PendingUpload? {
        val generation = source.consentGeneration
        if (!publication.isCurrent(source) || sourceOwner !== source || !contributionIsCurrent(generation)) return null
        val key = contentKey
        val imdb = imdbId
        val now = SystemClock.elapsedRealtime()
        val hasKey = key != null && imdb != null
        // Keep-fuller: never spend a POST that could not improve on the stored set.
        val beatsStored = frames.size > existingFrameCount
        val deliveredRevision = key?.let(uploadCoordinator::deliveredRevision) ?: 0L
        val hasNewCoverage = retainedRevision > deliveredRevision
        // The sheet builder floors at 2 tiles (buildAndUpload's `while budget >= 2`), so a lone frame is
        // structurally unbuildable and admitting it only reproduces a noisy sorted=1 failure.
        val enoughToBuild = frames.size >= 2
        // Progressive pushes are throttled; a teardown flush is the last chance and is never throttled.
        val throttleElapsed = !progressive || lastUploadUptimeMs == 0L ||
            now - lastUploadUptimeMs >= MIN_UPLOAD_INTERVAL_MS
        // Predict the Worker's coverage verdict so a doomed POST is skipped rather than sent and rejected.
        // Fails OPEN on an unknown bucket, so this only skips uploads we can positively call dead.
        val coverageReady = CommunityTrickplay.uploadCanStore(frames.size, CAPTURE_INTERVAL_S, durationBucket)
        val admission = if (key != null && imdb != null) {
            uploadCoordinator.request(
                key = key,
                kind = if (progressive) {
                    TrickplayUploadCoordinator.Kind.PROGRESSIVE
                } else {
                    TrickplayUploadCoordinator.Kind.FINAL
                },
                retainedRevision = retainedRevision,
                frameCount = frames.size,
                existingFrameCount = existingFrameCount,
                coverageReady = coverageReady,
                throttleReady = throttleElapsed,
            )
        } else null
        val willUpload = admission != null
        Log.d(
            TAG,
            "upload-gate(${if (progressive) "progressive" else "teardown"}) frames=${frames.size} " +
                "existing=$existingFrameCount revision=$retainedRevision delivered=$deliveredRevision hasKey=$hasKey " +
                "imdb=${imdb ?: "nil"} beatsStored=$beatsStored hasNewCoverage=$hasNewCoverage " +
                "enoughToBuild=$enoughToBuild throttleElapsed=$throttleElapsed coverageReady=$coverageReady " +
                "inFlight=${uploadCoordinator.inFlight != null} finalRejected=${key?.let(uploadCoordinator::isFinalRejected) == true} " +
                "-> ${if (willUpload) "UPLOAD" else "skip"}",
        )
        if (admission == null || key == null || imdb == null) return null
        val pending = PendingUpload(
            claim = admission.claim,
            revision = retainedRevision,
            key = key,
            imdb = imdb,
            season = season,
            episode = episode,
            durationBucket = durationBucket,
            srcHeight = srcHeight,
            frames = frames.toList(),
            consentGeneration = generation,
        )
        return when (admission) {
            is TrickplayUploadCoordinator.Admission.Start -> {
                lastUploadUptimeMs = now
                pending
            }
            is TrickplayUploadCoordinator.Admission.Deferred -> {
                deferredUpload = pending
                Log.d(TAG, "upload deferred key=$key revision=$retainedRevision frames=${frames.size}")
                null
            }
        }
    }

    private fun launchUpload(push: PendingUpload) {
        scope.launch { pushUpload(push) }
    }

    /** Build + POST off the main thread. The coordinator latch is cleared from finally for every exit. */
    private suspend fun pushUpload(push: PendingUpload) {
        Log.d(
            TAG,
            "pushUpload FIRING key=${push.key} imdb=${push.imdb} revision=${push.revision} frames=${push.frames.size}",
        )
        var outcome: CommunityTrickplay.UploadOutcome = CommunityTrickplay.UploadOutcome.Failed
        val requestControl = publication.withState {
            if (!contributionIsCurrent(push.consentGeneration) || uploadCoordinator.inFlight != push.claim) {
                null
            } else {
                CommunityTrickplayRequestControl().also { activeRequests += it }
            }
        }
        try {
            if (requestControl == null || !contributionIsCurrent(push.consentGeneration)) return
            outcome = CommunityTrickplay.buildAndUpload(
                context = context,
                key = push.key,
                imdbId = push.imdb,
                season = push.season,
                episode = push.episode,
                durationBucket = push.durationBucket,
                srcHeight = push.srcHeight,
                intervalS = CAPTURE_INTERVAL_S,
                frames = push.frames,
                canContribute = { contributionIsCurrent(push.consentGeneration) },
                requestControl = requestControl,
            )
            // Honest result labels: a 200 the Worker consciously declined is "rejected(reason)", NOT "failed".
            val label = when (outcome) {
                is CommunityTrickplay.UploadOutcome.Stored -> "stored"
                is CommunityTrickplay.UploadOutcome.Rejected -> "rejected(${outcome.reason})"
                is CommunityTrickplay.UploadOutcome.Failed -> "failed"
            }
            Log.d(TAG, "upload key=${push.key} revision=${push.revision} frames=${push.frames.size} -> $label")
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: Exception) {
            Log.d(TAG, "upload key=${push.key} revision=${push.revision} -> failed(${failure.javaClass.simpleName})")
        } finally {
            requestControl?.let { activeRequests -= it }
            completeAndLaunchNextUpload(
                complete = {
                    publication.withState {
                        val policyOutcome = when (outcome) {
                            is CommunityTrickplay.UploadOutcome.Stored -> TrickplayUploadCoordinator.Outcome.STORED
                            is CommunityTrickplay.UploadOutcome.Rejected -> TrickplayUploadCoordinator.Outcome.REJECTED
                            is CommunityTrickplay.UploadOutcome.Failed -> TrickplayUploadCoordinator.Outcome.FAILED
                        }
                        val completion = uploadCoordinator.complete(push.claim, policyOutcome)
                        if (!completion.applied) return@withState null
                        val deferred = deferredUpload
                        deferredUpload = null
                        completion.nextClaim?.let { nextClaim -> deferred?.takeIf { it.claim == nextClaim } }
                    }
                },
                launchNext = { next ->
                    if (contributionIsCurrent(next.consentGeneration)) {
                        Log.d(
                            TAG,
                            "upload draining deferred final key=${next.key} revision=${next.revision} " +
                                "frames=${next.frames.size}",
                        )
                        launchUpload(next)
                    }
                },
            )
        }
    }

    /** The immutable snapshot handed to a push, so the build never races the live [frames] buffer. */
    private data class PendingUpload(
        val claim: TrickplayUploadCoordinator.Claim,
        val revision: Long,
        val key: String,
        val imdb: String,
        val season: Int?,
        val episode: Int?,
        val durationBucket: Int,
        val srcHeight: Int,
        val frames: List<CommunityTrickplay.CapturedFrame>,
        val consentGeneration: Long,
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
