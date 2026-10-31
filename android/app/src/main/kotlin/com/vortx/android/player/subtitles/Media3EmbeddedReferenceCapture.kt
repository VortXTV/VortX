package com.vortx.android.player.subtitles

import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A finite timing witness from ONE already-owned progressive extraction. No network or track selection.
 *
 * The extractor wrapper supplies actual absolute input positions and terminal results. A seek, missing
 * input interval, load error or retirement permanently disqualifies the witness. Reaching a late cue is
 * deliberately insufficient: only real EOS after uninterrupted extraction from byte zero certifies it.
 * This does not claim HLS, encrypted text, bitmap text or low-latency prefix acquisition support.
 */
internal class Media3EmbeddedReferenceCapture(
    val loadIdentity: Any,
    private val originalOwnerLiveness: AtomicBoolean,
) {
    class Track internal constructor(
        internal val owner: Any,
        internal val extractor: Any,
        val extractorTrackId: Int,
    )

    class TrackInfo internal constructor(
        val track: Track,
        val formatId: String,
        val language: String?,
        val sourceMimeType: String,
    )

    data class Occurrence(val startUs: Long, val endUs: Long)

    class Snapshot internal constructor(
        val loadIdentity: Any,
        val track: TrackInfo,
        occurrences: List<Occurrence>,
        internal val responseIdentity: Any,
    ) {
        val occurrences: List<Occurrence> = Collections.unmodifiableList(ArrayList(occurrences))
        val prefixStartUs: Long = 0L
        val prefixEndUs: Long = PREFIX_END_US
    }

    enum class ReadResult { CONTINUE, SEEK_REQUIRED, END_OF_INPUT }

    private class StoredTrack(val token: Track) {
        var format: TrackInfo? = null
        var rejected = false
        val occurrences = ArrayList<Occurrence>()
        var issuedSnapshot: Snapshot? = null
    }

    private val lock = Any()
    private val owner = Any()
    private val tracks = LinkedHashMap<Int, StoredTrack>()
    private var extractor: Any? = null
    private var rejected = false
    private var retired = false
    private var readStarted = false
    private var insideRead = false
    private var expectedPosition = 0L
    private var readStartPosition = 0L
    private var reachedEnd = false
    private var sourceCreationRequested = false
    private var originalDataSource: Any? = null
    private var responseOpenRequested = false
    private var responseEstablished = false
    private var responseClosed = false

    /** Reserve BEFORE factory callouts: every later creation permanently rejects optional evidence. */
    fun dataSourceCreationStarted() = synchronized(lock) {
        if (!admitted() || sourceCreationRequested) rejectAll()
        else sourceCreationRequested = true
    }

    /** Bind the actual one created delegate; no URL, header or guessed entity identity is retained. */
    fun dataSourceCreated(actualDataSource: Any) = synchronized(lock) {
        if (!admitted() || !sourceCreationRequested || originalDataSource != null) rejectAll()
        else originalDataSource = actualDataSource
    }

    /** Called before the real open, so retry/reopen denial precedes delegate callbacks. */
    fun responseOpened(actualDataSource: Any, position: Long, requestedLength: Long) = synchronized(lock) {
        if (!admitted() || originalDataSource !== actualDataSource || responseOpenRequested || responseClosed ||
            position != 0L || requestedLength != UNBOUNDED_LENGTH) rejectAll()
        else responseOpenRequested = true
    }

    fun responseOpenSucceeded(actualDataSource: Any) = synchronized(lock) {
        if (!admitted() || originalDataSource !== actualDataSource || !responseOpenRequested ||
            responseEstablished || responseClosed) rejectAll()
        else responseEstablished = true
    }

    /** Called BEFORE close callouts. A genuine completed extractor may safely release its response. */
    fun responseClosed(actualDataSource: Any) = synchronized(lock) {
        if (!admitted() || originalDataSource !== actualDataSource || !responseEstablished || !reachedEnd || insideRead) rejectAll()
        else responseClosed = true
    }

    fun initialize(actualExtractor: Any): Boolean = synchronized(lock) {
        if (!admitted() || extractor != null) return@synchronized false
        extractor = actualExtractor
        true
    }

    fun track(actualExtractor: Any, actualTrackId: Int): Track? = synchronized(lock) {
        if (!admitted() || extractor !== actualExtractor) return@synchronized null
        tracks[actualTrackId]?.let { return@synchronized it.token }
        if (tracks.size >= MAX_TEXT_TRACKS) {
            rejectAll()
            return@synchronized null
        }
        Track(owner, actualExtractor, actualTrackId).also { tracks[actualTrackId] = StoredTrack(it) }
    }

    /** Pass the ACTUAL Format.id and original source MIME (Media3-cues Format.codecs). */
    fun format(track: Track, formatId: String?, language: String?, sourceMimeType: String?) = synchronized(lock) {
        val stored = owned(track) ?: return@synchronized
        if (!admitted() || reachedEnd || formatId.isNullOrEmpty() || formatId.length > MAX_FORMAT_ID_CHARS ||
            sourceMimeType !in TEXT_SOURCE_MIME_TYPES || (language?.length ?: 0) > MAX_LANGUAGE_CHARS) {
            reject(stored)
            return@synchronized
        }
        val previous = stored.format
        if (previous != null && (previous.formatId != formatId || previous.language != language ||
                previous.sourceMimeType != sourceMimeType)) {
            reject(stored)
            return@synchronized
        }
        stored.format = TrackInfo(track, formatId, language, requireNotNull(sourceMimeType))
    }

    fun acceptsSamples(track: Track): Boolean = synchronized(lock) {
        val stored = owned(track)
        admitted() && hasResponse() && !responseClosed && !reachedEnd && stored != null && stored.format != null && !stored.rejected
    }

    fun reject(track: Track) = synchronized(lock) { owned(track)?.let(::reject) }

    /** Must be called before each real Extractor.read, using that input's absolute getPosition(). */
    fun beginRead(actualExtractor: Any, absolutePosition: Long) = synchronized(lock) {
        if (!admitted() || !hasResponse() || responseClosed || extractor !== actualExtractor || insideRead || reachedEnd ||
            absolutePosition != expectedPosition) {
            rejectAll()
            return@synchronized
        }
        readStarted = true
        insideRead = true
        readStartPosition = absolutePosition
    }

    /** Must be called only after that same real read returns; exceptions call fail instead. */
    fun endRead(actualExtractor: Any, absolutePosition: Long, result: ReadResult) = synchronized(lock) {
        if (!admitted() || !hasResponse() || responseClosed || extractor !== actualExtractor || !insideRead || absolutePosition < readStartPosition) {
            rejectAll()
            return@synchronized
        }
        insideRead = false
        expectedPosition = absolutePosition
        when (result) {
            ReadResult.CONTINUE -> Unit
            ReadResult.SEEK_REQUIRED -> rejectAll()
            ReadResult.END_OF_INPUT -> reachedEnd = true
        }
    }

    /** Initial zero seek before any read is harmless; every later/nonzero seek loses completeness. */
    fun seek(actualExtractor: Any, bytePosition: Long, timeUs: Long) = synchronized(lock) {
        if (!admitted() || extractor !== actualExtractor || readStarted || bytePosition != 0L || timeUs != 0L) rejectAll()
    }

    /** One occurrence per nonblank TEXT cue, including identical/equal-start simultaneous occurrences. */
    fun sample(track: Track, startUs: Long, durationUs: Long, occurrenceCount: Int) = synchronized(lock) {
        val stored = owned(track) ?: return@synchronized
        if (!admitted() || !hasResponse() || responseClosed || !insideRead || reachedEnd || stored.format == null || stored.rejected) {
            reject(stored)
            return@synchronized
        }
        if (occurrenceCount == 0) return@synchronized // Empty/clear cue sets carry no dialogue evidence.
        if (occurrenceCount < 0 || startUs < 0L || durationUs <= 0L || startUs > Long.MAX_VALUE - durationUs) {
            reject(stored)
            return@synchronized
        }
        val endUs = startUs + durationUs
        if (startUs >= PREFIX_END_US || endUs > PREFIX_END_US) return@synchronized
        if (occurrenceCount > MAX_OCCURRENCES - stored.occurrences.size) {
            reject(stored) // Never truncate excess occurrences into a supposedly complete witness.
            return@synchronized
        }
        val occurrence = Occurrence(startUs, endUs)
        repeat(occurrenceCount) { stored.occurrences.add(occurrence) }
    }

    /** Only exact, unique real Format.id matches may bridge to the current Media3 track inventory. */
    fun snapshot(originalLoadIdentity: Any, actualFormatId: String): Snapshot? = synchronized(lock) {
        if (!admitted() || !hasResponse() || originalLoadIdentity !== loadIdentity || !reachedEnd || insideRead || !readStarted) return@synchronized null
        val matches = tracks.values.filter { it.format?.formatId == actualFormatId }
        val selected = matches.singleOrNull() ?: return@synchronized null
        if (selected.rejected || selected.occurrences.size < MIN_OCCURRENCES) return@synchronized null
        val format = selected.format ?: return@synchronized null
        val originalResponse = originalDataSource ?: return@synchronized null
        selected.issuedSnapshot ?: Snapshot(loadIdentity, format, selected.occurrences.sortedBy { it.startUs }, originalResponse)
            .also { selected.issuedSnapshot = it }
    }

    /** Scalar readiness only. It does not assert that a requested track has enough valid occurrences. */
    val isComplete: Boolean get() = synchronized(lock) { admitted() && hasResponse() && reachedEnd && !insideRead && readStarted }

    /** Terminal optional-reference denial only; it never authorizes a query, fallback or player write. */
    val isUnavailable: Boolean get() = synchronized(lock) { !admitted() }

    /** Final application-looper check: no cue sort, array copy, URL read or callback. */
    fun isCurrent(snapshot: Snapshot): Boolean = synchronized(lock) {
        val stored = owned(snapshot.track.track) ?: return@synchronized false
        admitted() && hasResponse() && snapshot.responseIdentity === originalDataSource &&
            snapshot.loadIdentity === loadIdentity && reachedEnd && !insideRead && readStarted &&
            !stored.rejected && stored.issuedSnapshot === snapshot && stored.format === snapshot.track &&
            snapshot.occurrences.size == stored.occurrences.size &&
            stored.occurrences.size in MIN_OCCURRENCES..MAX_OCCURRENCES
    }

    fun fail() = synchronized(lock) { rejectAll() }
    fun retire() = synchronized(lock) { retired = true; rejectAll() }

    private fun admitted(): Boolean = !retired && !rejected && originalOwnerLiveness.get()
    private fun hasResponse(): Boolean = originalDataSource != null && responseOpenRequested && responseEstablished
    private fun owned(track: Track): StoredTrack? = if (track.owner === owner && track.extractor === extractor)
        tracks[track.extractorTrackId]?.takeIf { it.token === track } else null
    private fun reject(stored: StoredTrack) {
        stored.rejected = true
        stored.occurrences.clear()
        stored.issuedSnapshot = null
    }
    private fun rejectAll() { rejected = true; insideRead = false; tracks.values.forEach(::reject) }

    companion object {
        const val PREFIX_END_US = 1_080_000_000L
        const val MAX_OCCURRENCES = 1024
        const val MIN_OCCURRENCES = 8
        const val MAX_TEXT_TRACKS = 16
        const val UNBOUNDED_LENGTH = -1L // Media3 C.LENGTH_UNSET, kept pure for this ledger.
        private const val MAX_FORMAT_ID_CHARS = 1024
        private const val MAX_LANGUAGE_CHARS = 128
        // 1.11.1 SubripParser emits each authored block directly. Other parsers may emit
        // rendered/segmented cue groups that cannot certify original occurrence identity.
        private val TEXT_SOURCE_MIME_TYPES = setOf("application/x-subrip")
    }
}
