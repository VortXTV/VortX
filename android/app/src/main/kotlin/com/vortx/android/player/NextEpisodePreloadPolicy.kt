package com.vortx.android.player

/**
 * Pure scheduling state for next-episode preparation.
 *
 * Player progress can arrive several times per second. A failed preload therefore needs bounded retry
 * state rather than returning to an idle shape that launches again on every tick.
 */
internal class NextEpisodePreloadPolicy {
    data class Target(
        val episodeId: String,
        val generation: Long,
    )

    enum class AttemptKind {
        REGULAR,
        NEAR_CREDITS,
    }

    data class Attempt(
        val target: Target,
        val sequence: Long,
        val kind: AttemptKind,
        val startedAtMs: Long,
        val deadlineMs: Long,
    )

    enum class Completion {
        READY,
        RETRY_SCHEDULED,
        EXHAUSTED,
        STALE,
    }

    var target: Target? = null
        private set
    var activeAttempt: Attempt? = null
        private set
    var ready: Boolean = false
        private set
    var regularAttempts: Int = 0
        private set
    var nearCreditsAttempted: Boolean = false
        private set
    var nextRetryAtMs: Long? = null
        private set

    private var nextSequence = 0L

    fun evaluate(
        requestedTarget: Target,
        positionMs: Long,
        durationMs: Long,
        nowMs: Long,
    ): Attempt? {
        if (target != requestedTarget) reset(requestedTarget)
        if (ready || !isCommitted(positionMs, durationMs)) return null

        activeAttempt?.let { active ->
            if (
                isNearCredits(positionMs, durationMs) &&
                active.kind == AttemptKind.REGULAR &&
                !nearCreditsAttempted
            ) {
                activeAttempt = null
                nearCreditsAttempted = true
                nextRetryAtMs = null
                regularAttempts = MAX_REGULAR_ATTEMPTS
                return launch(AttemptKind.NEAR_CREDITS, nowMs)
            }
            if (nowMs < active.deadlineMs) return null
            activeAttempt = null
            if (active.kind == AttemptKind.NEAR_CREDITS) {
                nextRetryAtMs = null
                return null
            }
            nextRetryAtMs = nowMs
        }

        if (regularAttempts == 0) return launchRegular(nowMs)

        if (isNearCredits(positionMs, durationMs) && !nearCreditsAttempted) {
            nearCreditsAttempted = true
            nextRetryAtMs = null
            regularAttempts = MAX_REGULAR_ATTEMPTS
            return launch(AttemptKind.NEAR_CREDITS, nowMs)
        }

        val retryAt = nextRetryAtMs
        if (regularAttempts >= MAX_REGULAR_ATTEMPTS || retryAt == null || nowMs < retryAt) return null
        return launchRegular(nowMs)
    }

    fun complete(attempt: Attempt, success: Boolean, nowMs: Long): Completion {
        if (target != attempt.target || activeAttempt != attempt) return Completion.STALE
        activeAttempt = null
        if (success) {
            ready = true
            nextRetryAtMs = null
            return Completion.READY
        }
        if (attempt.kind != AttemptKind.REGULAR || regularAttempts >= MAX_REGULAR_ATTEMPTS) {
            nextRetryAtMs = null
            return Completion.EXHAUSTED
        }
        val delay = RETRY_DELAYS_MS.getOrNull(regularAttempts - 1)
        if (delay == null) {
            nextRetryAtMs = null
            return Completion.EXHAUSTED
        }
        nextRetryAtMs = saturatedAdd(nowMs, delay)
        return Completion.RETRY_SCHEDULED
    }

    /**
     * A prepared URL can expire before credits. Reopen only the final credits attempt, without reviving
     * the regular retry schedule.
     */
    fun warmFailed(requestedTarget: Target): Boolean {
        if (target != requestedTarget || !ready || activeAttempt != null || nearCreditsAttempted) return false
        ready = false
        regularAttempts = MAX_REGULAR_ATTEMPTS
        nextRetryAtMs = null
        return true
    }

    fun accepts(attempt: Attempt): Boolean = target == attempt.target && activeAttempt == attempt

    fun isReady(requestedTarget: Target): Boolean = target == requestedTarget && ready

    fun invalidate() {
        target = null
        activeAttempt = null
        ready = false
        regularAttempts = 0
        nearCreditsAttempted = false
        nextRetryAtMs = null
        nextSequence = 0L
    }

    private fun reset(requestedTarget: Target) {
        target = requestedTarget
        activeAttempt = null
        ready = false
        regularAttempts = 0
        nearCreditsAttempted = false
        nextRetryAtMs = null
        nextSequence = 0L
    }

    private fun launchRegular(nowMs: Long): Attempt {
        regularAttempts += 1
        nextRetryAtMs = null
        return launch(AttemptKind.REGULAR, nowMs)
    }

    private fun launch(kind: AttemptKind, nowMs: Long): Attempt {
        val currentTarget = requireNotNull(target)
        nextSequence += 1L
        return Attempt(
            target = currentTarget,
            sequence = nextSequence,
            kind = kind,
            startedAtMs = nowMs,
            deadlineMs = saturatedAdd(nowMs, ATTEMPT_TIMEOUT_MS),
        ).also { activeAttempt = it }
    }

    companion object {
        const val DURATIONLESS_START_MS = 120_000L
        const val NEAR_CREDITS_REMAINING_MS = 100_000L
        const val DURATIONLESS_NEAR_CREDITS_MS = 300_000L
        const val MAX_REGULAR_ATTEMPTS = 3
        const val ATTEMPT_TIMEOUT_MS = 15_000L
        val RETRY_DELAYS_MS = listOf(20_000L, 60_000L)

        fun isCommitted(positionMs: Long, durationMs: Long): Boolean {
            if (positionMs < 0L || durationMs < 0L) return false
            return if (durationMs > 0L) {
                positionMs >= durationMs / 2L + durationMs % 2L
            } else {
                positionMs >= DURATIONLESS_START_MS
            }
        }

        fun isNearCredits(positionMs: Long, durationMs: Long): Boolean {
            if (positionMs < 0L || durationMs < 0L) return false
            return if (durationMs > 0L) {
                durationMs - positionMs <= NEAR_CREDITS_REMAINING_MS
            } else {
                positionMs >= DURATIONLESS_NEAR_CREDITS_MS
            }
        }

        private fun saturatedAdd(value: Long, increment: Long): Long =
            if (value > Long.MAX_VALUE - increment) Long.MAX_VALUE else value + increment
    }
}
