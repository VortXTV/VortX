package com.vortx.android.skip

import kotlin.math.roundToLong

/** Stable identity for one skip span. Start alone is not enough: credits and another segment kind can
 * share a boundary, and their cancel/completion memory must stay independent. */
data class AutoSkipSegmentKey(
    val kind: SkipSegment.Kind,
    val startMilliseconds: Long,
    val endMilliseconds: Long,
) {
    constructor(segment: SkipSegment) : this(
        kind = segment.kind,
        startMilliseconds = (segment.start * 1000.0).roundToLong(),
        endMilliseconds = (segment.end * 1000.0).roundToLong(),
    )
}

/** Mutable pure state for a position-driven automatic-skip countdown. No wall-clock or coroutine belongs
 * here: PlayerScreen calls [advance] from telemetry and passes false while paused/buffering. */
data class AutoSkipCountdownState(
    var mediaId: String? = null,
    var epoch: Long = 0,
    var lastPositionMs: Long? = null,
    var activeSegment: AutoSkipSegmentKey? = null,
    var accruedPlaybackMs: Long = 0,
    val cancelledSegments: MutableSet<AutoSkipSegmentKey> = mutableSetOf(),
    val completedSegments: MutableSet<AutoSkipSegmentKey> = mutableSetOf(),
) {
    fun isSuppressed(segment: SkipSegment): Boolean {
        val key = AutoSkipSegmentKey(segment)
        return key in cancelledSegments || key in completedSegments
    }
}

sealed class AutoSkipCountdownDecision {
    data object Idle : AutoSkipCountdownDecision()
    data class Prompt(
        val segment: AutoSkipSegmentKey,
        val remainingSeconds: Double,
    ) : AutoSkipCountdownDecision()
    data class Skip(
        val segment: AutoSkipSegmentKey,
        val targetPositionMs: Long,
        val epoch: Long,
    ) : AutoSkipCountdownDecision()
}

/**
 * Shared Android countdown policy. It is deliberately independent of Compose, ExoPlayer, mpv, and
 * coroutines so the phone and TV player hooks can enforce the same pause/seek/source fences.
 */
object AutoSkipCountdownPolicy {
    const val DEFAULT_DELAY_SECONDS = 5
    const val MAXIMUM_SAMPLE_DELTA_MS = 2_000L

    fun advance(
        state: AutoSkipCountdownState,
        mediaId: String,
        segment: SkipSegment?,
        positionMs: Long,
        durationMs: Long? = null,
        playbackActive: Boolean,
        delaySeconds: Double,
    ): AutoSkipCountdownDecision {
        bindMediaIfNeeded(state, mediaId)
        if (segment == null) {
            clearActive(state, positionMs)
            return AutoSkipCountdownDecision.Idle
        }

        val key = AutoSkipSegmentKey(segment)
        if (state.activeSegment != key) {
            state.activeSegment = key
            state.accruedPlaybackMs = 0
            state.epoch += 1
        }

        val safeDelaySeconds = if (delaySeconds.isFinite()) delaySeconds.coerceAtLeast(0.0) else 0.0
        val previous = state.lastPositionMs
        state.lastPositionMs = positionMs
        if (previous != null) {
            val delta = positionMs - previous
            if (delta < 0 || delta > MAXIMUM_SAMPLE_DELTA_MS) {
                // Backward/large jumps are a user seek or bad telemetry, never five seconds of viewing.
                state.accruedPlaybackMs = 0
                state.epoch += 1
            } else if (playbackActive && delta > 0 && safeDelaySeconds > 0) {
                val delayMs = (safeDelaySeconds * 1000.0).roundToLong().coerceAtLeast(1L)
                state.accruedPlaybackMs = (state.accruedPlaybackMs + delta).coerceAtMost(delayMs)
            }
        }

        if (safeDelaySeconds <= 0.0 || key in state.cancelledSegments || key in state.completedSegments) {
            return AutoSkipCountdownDecision.Idle
        }
        val delayMs = (safeDelaySeconds * 1000.0).roundToLong().coerceAtLeast(1L)
        if (state.accruedPlaybackMs >= delayMs) {
            state.completedSegments += key
            state.epoch += 1
            return AutoSkipCountdownDecision.Skip(
                segment = key,
                targetPositionMs = clampedEnd(segment.end, durationMs, segment.start),
                epoch = state.epoch,
            )
        }
        return AutoSkipCountdownDecision.Prompt(
            segment = key,
            remainingSeconds = (delayMs - state.accruedPlaybackMs) / 1000.0,
        )
    }

    fun step(
        state: AutoSkipCountdownState,
        mediaId: String,
        segment: SkipSegment?,
        positionMs: Long,
        durationMs: Long? = null,
        playbackActive: Boolean,
        delaySeconds: Double,
    ): AutoSkipCountdownDecision = advance(
        state = state,
        mediaId = mediaId,
        segment = segment,
        positionMs = positionMs,
        durationMs = durationMs,
        playbackActive = playbackActive,
        delaySeconds = delaySeconds,
    )

    fun cancel(state: AutoSkipCountdownState, segment: SkipSegment) {
        state.cancelledSegments += AutoSkipSegmentKey(segment)
        state.accruedPlaybackMs = 0
        state.epoch += 1
    }

    fun complete(state: AutoSkipCountdownState, segment: SkipSegment) {
        state.completedSegments += AutoSkipSegmentKey(segment)
        state.accruedPlaybackMs = 0
        state.epoch += 1
    }

    /** Invalidates queued work while preserving per-media cancel/completion memory. */
    fun invalidatePending(state: AutoSkipCountdownState, positionMs: Long? = null) {
        state.activeSegment = null
        state.accruedPlaybackMs = 0
        state.lastPositionMs = positionMs
        state.epoch += 1
    }

    /** A new episode/movie clears memory; a same-media source rebind is deliberately a no-op. */
    fun bindMedia(state: AutoSkipCountdownState, mediaId: String) {
        bindMediaIfNeeded(state, mediaId)
    }

    fun isCurrent(
        state: AutoSkipCountdownState,
        mediaId: String,
        segment: SkipSegment,
        epoch: Long,
    ): Boolean = state.mediaId == mediaId
        && state.activeSegment == AutoSkipSegmentKey(segment)
        && state.epoch == epoch

    private fun bindMediaIfNeeded(state: AutoSkipCountdownState, mediaId: String) {
        if (state.mediaId == mediaId) return
        state.mediaId = mediaId
        state.lastPositionMs = null
        state.activeSegment = null
        state.accruedPlaybackMs = 0
        state.cancelledSegments.clear()
        state.completedSegments.clear()
        state.epoch += 1
    }

    private fun clearActive(state: AutoSkipCountdownState, positionMs: Long) {
        if (state.activeSegment != null) state.epoch += 1
        state.activeSegment = null
        state.accruedPlaybackMs = 0
        state.lastPositionMs = positionMs
    }

    private fun clampedEnd(endSeconds: Double, durationMs: Long?, startSeconds: Double): Long {
        val lower = (startSeconds.coerceAtLeast(0.0) * 1000.0).roundToLong()
        val target = (endSeconds.coerceAtLeast(startSeconds) * 1000.0).roundToLong().coerceAtLeast(lower)
        return if (durationMs != null && durationMs > 0) target.coerceAtMost(durationMs) else target
    }
}
