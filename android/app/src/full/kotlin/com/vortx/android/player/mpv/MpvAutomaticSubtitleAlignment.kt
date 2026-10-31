package com.vortx.android.player.mpv

import com.vortx.android.player.PlayerExternalSubtitleSelectionResult
import com.vortx.android.player.PlayerSubtitleSelection
import com.vortx.android.player.mpv.seam.MpvReferenceReply
import com.vortx.android.player.mpv.seam.MpvReferenceClose
import com.vortx.android.player.mpv.seam.MpvReferenceRequest
import com.vortx.android.player.mpv.seam.MpvReferenceSession
import com.vortx.android.player.subtitles.SubtitleAlignmentWork
import com.vortx.android.player.subtitles.SubtitleReferenceQuery
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import org.json.JSONArray

/**
 * The host's original source/manual receipt remains separate from the native v2 capture. Neither
 * completion may adopt a newer choice. All cleanup closes the exact original effect; it never admits
 * an ordinary command after owner retirement. No monitor here spans JNI, a callback or suspension.
 */
internal class MpvAutomaticSubtitleAlignment(
    // This callback reserves state only. Its returned completion runs outside every host/registry lock.
    private val reserveRetirement: () -> ((MpvReferenceClose) -> Unit) = { { } },
) {
    class Attempt internal constructor(val selection: PlayerSubtitleSelection) {
        internal var effect: MpvReferenceSession? = null
        internal var closeRequested = false
        internal var closeAction: (() -> Unit)? = null
    }

    private val lock = Any()
    private var active: Attempt? = null

    fun begin(selection: PlayerSubtitleSelection): Pair<Attempt, () -> Unit> {
        val next = Attempt(selection)
        val previous = synchronized(lock) { active.also { active = next } }
        return next to (previous?.let(::prepareClose) ?: {})
    }

    fun discard(attempt: Attempt) {
        synchronized(lock) { if (active === attempt) active = null }
        prepareClose(attempt).invoke()
    }

    fun isCurrent(attempt: Attempt): Boolean = synchronized(lock) { active === attempt }

    /** Detach while the host revokes its selection; invoke cleanup only after the host lock. */
    fun takeRetirement(): () -> Unit {
        val previous = synchronized(lock) { active.also { active = null } }
        return previous?.let(::prepareClose) ?: {}
    }

    fun retire() = takeRetirement().invoke()

    private fun attach(attempt: Attempt, effect: MpvReferenceSession): Boolean {
        val accepted = synchronized(lock) {
            check(attempt.effect == null)
            attempt.effect = effect
            active === attempt && !attempt.closeRequested
        }
        if (!accepted) prepareClose(attempt).invoke()
        return accepted
    }

    /** Reserve before the effect's first close, including cancellation and retained publication. */
    private fun prepareClose(attempt: Attempt): () -> Unit = synchronized(lock) {
        attempt.closeRequested = true
        attempt.closeAction?.let { return@synchronized it }
        val original = attempt.effect ?: return@synchronized {}
        val completed = reserveRetirement()
        val started = java.util.concurrent.atomic.AtomicBoolean(false)
        val action: () -> Unit = {
            if (started.compareAndSet(false, true)) {
                original.whenClosed(completed)
                original.close()
            }
        }
        attempt.closeAction = action
        action
    }

    suspend fun alignMounted(
        attempt: Attempt,
        externalBytes: ByteArray,
        language: String,
        selectedNativeId: Int,
        cleanupScope: CoroutineScope,
        current: () -> Boolean,
        openOriginal: () -> MpvReferenceSession?,
    ): PlayerExternalSubtitleSelectionResult {
        var retainedPublication = false
        var effect: MpvReferenceSession? = null
        var ownerObserver: kotlinx.coroutines.Job? = null
        fun admitted() = isCurrent(attempt) && current()
        try {
            val result = run {
                currentCoroutineContext().ensureActive()
                if (!admitted()) return@run PlayerExternalSubtitleSelectionResult.SUPERSEDED
                val original = openOriginal()
                    ?: return@run PlayerExternalSubtitleSelectionResult.SELECTED_WITHOUT_ALIGNMENT
                effect = original
                if (!attach(attempt, original)) return@run PlayerExternalSubtitleSelectionResult.SUPERSEDED
                // Owner writers only retire their one-way cell. Observe it on the engine's own worker;
                // no cleanup callback or JNI call is introduced into their account/profile locks.
                ownerObserver = cleanupScope.launch(Dispatchers.IO) {
                    try { while (admitted()) delay(50L) } finally { prepareClose(attempt).invoke() }
                }
                if (!original.capture.primaryExternal || original.capture.primarySID != selectedNativeId.toLong())
                    return@run PlayerExternalSubtitleSelectionResult.SELECTED_WITHOUT_ALIGNMENT
                if (!admitted()) return@run PlayerExternalSubtitleSelectionResult.SUPERSEDED
                val read = await(original::read, attempt)
                if (read !is MpvReferenceReply.Read) return@run failure(read, admitted())
                if (!admitted()) return@run PlayerExternalSubtitleSelectionResult.SUPERSEDED
                val file = SubtitleAlignmentWork.align(externalBytes, read.receipt.cues.map {
                    SubtitleReferenceQuery.Timing(it.startMs, it.endMs)
                }) ?: return@run PlayerExternalSubtitleSelectionResult.SELECTED_WITHOUT_ALIGNMENT
                if (!admitted()) return@run PlayerExternalSubtitleSelectionResult.SUPERSEDED
                val payload = SubtitleReferenceQuery.payload(file, language)
                    ?: return@run PlayerExternalSubtitleSelectionResult.SELECTED_WITHOUT_ALIGNMENT
                val prepared = await({ callback -> original.prepare(payload, callback) }, attempt)
                if (prepared !is MpvReferenceReply.Prepared) return@run failure(prepared, admitted())
                if (!admitted()) return@run PlayerExternalSubtitleSelectionResult.SUPERSEDED
                val committed = await(original::commit, attempt)
                if (committed !is MpvReferenceReply.Committed) return@run failure(committed, admitted())
                if (!admitted() || !original.isActive()) return@run PlayerExternalSubtitleSelectionResult.SUPERSEDED
                PlayerExternalSubtitleSelectionResult.ALIGNED
            }
            if (result == PlayerExternalSubtitleSelectionResult.ALIGNED) {
                retainedPublication = true
                return result
            }
            // A rejected match is not a successful raw fallback until its exact effect has retired.
            // Revoke failure requests context teardown and must reach the existing engine fallback.
            val original = effect
            if (original != null) {
                prepareClose(attempt).invoke()
                val closed = suspendCancellableCoroutine<MpvReferenceClose> { continuation ->
                    original.whenClosed { if (continuation.isActive) continuation.resume(it) }
                }
                if (closed == MpvReferenceClose.TEARDOWN_REQUESTED)
                    return PlayerExternalSubtitleSelectionResult.NEEDS_STOP
            }
            return result
        } finally {
            if (!retainedPublication) {
                ownerObserver?.cancel()
                discard(attempt)
            }
        }
    }

    private suspend fun await(
        begin: ((MpvReferenceReply) -> Unit) -> MpvReferenceRequest?,
        attempt: Attempt,
    ): MpvReferenceReply = suspendCancellableCoroutine { continuation ->
        // Cancel the whole original effect, not a mutable "current request" that might now be PREPARE.
        continuation.invokeOnCancellation { prepareClose(attempt).invoke() }
        val request = begin { reply -> if (continuation.isActive) continuation.resume(reply) }
        if (request == null && continuation.isActive) continuation.resume(MpvReferenceReply.Rejected(Int.MIN_VALUE))
    }

    private fun failure(reply: MpvReferenceReply, current: Boolean): PlayerExternalSubtitleSelectionResult = when {
        !current || reply == MpvReferenceReply.Cancelled -> PlayerExternalSubtitleSelectionResult.SUPERSEDED
        reply == MpvReferenceReply.Unconfirmed -> PlayerExternalSubtitleSelectionResult.NEEDS_STOP
        else -> PlayerExternalSubtitleSelectionResult.SELECTED_WITHOUT_ALIGNMENT
    }
}

/** Exact native visible-primary receipt. Duplicate paths/ids or missing fields fail closed. */
internal fun uniqueMpvExternalSubtitleId(rawTrackList: String?, exactOwnedPath: String, actualSID: Int?): Int? {
    if (rawTrackList == null || rawTrackList.length > 1024 * 1024 || actualSID == null || actualSID <= 0) return null
    return try {
        val tracks = JSONArray(rawTrackList)
        if (tracks.length() > 4096) return null
        var match: Int? = null
        for (index in 0 until tracks.length()) {
            val row = tracks.optJSONObject(index) ?: return null
            if (row.optString("type") != "sub" || row.opt("external") != true ||
                row.optString("external-filename") != exactOwnedPath) continue
            val value = row.opt("id")
            val id: Int? = if (value is Int) {
                value.takeIf { it > 0 }
            } else if (value is Long && value >= 1L && value <= Int.MAX_VALUE.toLong()) {
                value.toInt()
            } else {
                null
            }
            if (id == null) return null
            if (match != null) return null
            match = id
        }
        match?.takeIf { it == actualSID }
    } catch (_: org.json.JSONException) { null }
}
