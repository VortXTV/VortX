package com.vortx.android.trickplay

import kotlin.math.max

/**
 * Revision-based ownership for community uploads.
 *
 * Frame count is not progress once retention reaches its cap. A retained-content revision continues to
 * advance when a later endpoint replaces an interior frame at the same count. Only a confirmed store
 * advances [deliveredRevision]. A progressive rejection settles that exact revision while allowing newer
 * content, and a final rejection is a separate terminal verdict. Failed transport remains retryable.
 */
class TrickplayUploadCoordinator {
    enum class Kind { PROGRESSIVE, FINAL }
    enum class Outcome { STORED, REJECTED, FAILED }

    data class Claim(
        val key: String,
        val sequence: Long,
        val kind: Kind,
        val revision: Long,
        val frameCount: Int,
    )

    sealed interface Admission {
        val claim: Claim

        data class Start(override val claim: Claim) : Admission
        data class Deferred(override val claim: Claim) : Admission
    }

    data class Completion(val applied: Boolean, val nextClaim: Claim?)

    private data class KeyState(
        var deliveredRevision: Long = 0L,
        var progressiveRejectedRevision: Long = 0L,
        var finalRejected: Boolean = false,
    ) {
        val settledRevision: Long
            get() = max(deliveredRevision, progressiveRejectedRevision)
    }

    private val states = mutableMapOf<String, KeyState>()
    private var nextSequence = 1L
    var inFlight: Claim? = null
        private set
    var deferredFinal: Claim? = null
        private set

    fun deliveredRevision(key: String): Long = states[key]?.deliveredRevision ?: 0L
    fun settledRevision(key: String): Long = states[key]?.settledRevision ?: 0L
    fun isFinalRejected(key: String): Boolean = states[key]?.finalRejected == true

    fun request(
        key: String,
        kind: Kind,
        retainedRevision: Long,
        frameCount: Int,
        existingFrameCount: Int,
        coverageReady: Boolean,
        throttleReady: Boolean,
    ): Admission? {
        val state = states.getOrPut(key) { KeyState() }
        if (state.finalRejected || retainedRevision <= state.settledRevision ||
            frameCount < 2 || frameCount <= existingFrameCount || !coverageReady ||
            (kind == Kind.PROGRESSIVE && !throttleReady)
        ) {
            return null
        }

        if (inFlight != null) {
            if (kind != Kind.FINAL) return null
            val queued = deferredFinal
            if (queued != null && queued.key == key && queued.revision >= retainedRevision) return null
            val claim = claim(key, kind, retainedRevision, frameCount)
            deferredFinal = claim
            return Admission.Deferred(claim)
        }

        val claim = claim(key, kind, retainedRevision, frameCount)
        inFlight = claim
        return Admission.Start(claim)
    }

    /**
     * Complete only the exact active claim, then drain at most one still-eligible final. This method owns
     * the in-flight latch and is called from production's finally block for every outcome.
     */
    fun complete(claim: Claim, outcome: Outcome): Completion {
        if (inFlight != claim) return Completion(applied = false, nextClaim = null)
        inFlight = null
        val state = states.getOrPut(claim.key) { KeyState() }
        when (outcome) {
            Outcome.STORED -> state.deliveredRevision = max(state.deliveredRevision, claim.revision)
            Outcome.REJECTED -> if (claim.kind == Kind.FINAL) {
                state.finalRejected = true
            } else {
                state.progressiveRejectedRevision = max(state.progressiveRejectedRevision, claim.revision)
            }
            Outcome.FAILED -> Unit
        }

        val queued = deferredFinal
        deferredFinal = null
        val next = queued?.takeIf { candidate ->
            val candidateState = states.getOrPut(candidate.key) { KeyState() }
            !candidateState.finalRejected && candidate.revision > candidateState.settledRevision
        }
        inFlight = next
        return Completion(applied = true, nextClaim = next)
    }

    private fun claim(key: String, kind: Kind, revision: Long, frameCount: Int): Claim {
        val claim = Claim(key, nextSequence, kind, revision, frameCount)
        nextSequence += 1L
        return claim
    }
}
