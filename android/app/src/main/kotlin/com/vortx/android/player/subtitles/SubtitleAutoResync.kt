package com.vortx.android.player.subtitles

import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * Pure resolution/capture policy for a community-learned constant offset of the playing rip. The shared
 * Android PlayerScreen owns fetching the pool result, current source/account/profile admission, and the
 * one-shot SubtitleTimingSession which applies it to libmpv's live sub-delay. Media3 does not advertise
 * that capability and therefore never claims to apply an offset. This is not speech, cue or FPS/drift alignment.
 *
 * A valid saved manual decision wins over the community offset, and a manual adjustment (including zero
 * reset) holds the current source session against a late pool response. The existing device-local memory
 * deliberately removes a zero reset rather than persisting a new account/profile preference format.
 *
 * The capture helpers validate values only. The current Android host does not post manual adjustments
 * back to the pool; contributing them requires a separately wired consent/eligibility path.
 */
object SubtitleAutoResync {

    /** Where a resolved offset came from, so the caller can log / surface it honestly. */
    enum class OffsetSource { NONE, MANUAL, COMMUNITY }

    /**
     * The outcome of one resolution pass.
     *
     * @param seconds the subtitle delay to apply, in seconds, rounded to 0.1 s (matching Apple).
     * @param seeded  whether a valid offset decision, including explicit zero, was chosen or already existed.
     * @param source  which layer supplied [seconds]; [OffsetSource.NONE] when nothing applied.
     */
    data class Resolution(val seconds: Double, val seeded: Boolean, val source: OffsetSource)

    /** Bound on any applied/captured offset, byte-for-byte Apple's `abs(subDelay) <= 120`. */
    const val MAX_ABS_SECONDS = 120.0

    /**
     * Resolve the subtitle delay to apply, layering the manual offset over the community-learned one.
     *
     * @param manualOffsetSeconds the viewer's own saved offset from device-local subtitle memory, or
     *        null when they never set one.
     * @param poolOffsetMs        the community-learned offset (ms) from the pool, or null when the pool has none.
     * @param alreadySeeded       whether a prior pass already seeded this session (Apple's `pooledSeededOffset`).
     *
     * When [alreadySeeded] is true this is a no-op that reports the session as still seeded and applies nothing,
     * so a late caller cannot re-seed. Manual wins over community; community applies only when there is no manual
     * offset and the session is unseeded.
     */
    fun resolve(
        manualOffsetSeconds: Double?,
        poolOffsetMs: Int?,
        alreadySeeded: Boolean,
    ): Resolution {
        if (alreadySeeded) return Resolution(0.0, seeded = true, source = OffsetSource.NONE)

        val manual = sanitizedSeconds(manualOffsetSeconds)
        // Zero is an explicit viewer decision, not permission to replace it with a pool value.
        if (manual != null) {
            return Resolution(manual, seeded = true, source = OffsetSource.MANUAL)
        }

        // Validate the original value before rounding: 120001ms is outside the 120s bound.
        val community = poolOffsetMs?.let { sanitizedSeconds(it / 1000.0) }
        if (community != null) {
            return Resolution(community, seeded = true, source = OffsetSource.COMMUNITY)
        }

        // Invalid/non-finite manual input is not a decision and cannot poison later seeding.
        return Resolution(0.0, seeded = false, source = OffsetSource.NONE)
    }

    /**
     * Whether a viewer-adjusted [seconds] offset is a valid candidate to contribute back to the pool. Mirrors
     * Apple's `subDelay.isFinite, abs(subDelay) <= 120` capture guard.
     */
    fun captureIsValid(seconds: Double): Boolean = seconds.isFinite() && abs(seconds) <= MAX_ABS_SECONDS

    /** The integer ms value to submit to the pool for a captured offset, or null when it is not valid. */
    fun captureOffsetMs(seconds: Double): Int? {
        if (!captureIsValid(seconds)) return null
        return (seconds * 1000.0).roundToLong().toInt()
    }

    /** Reject a non-finite or out-of-bounds offset; otherwise round to 0.1 s like the memory + pool paths. */
    private fun sanitizedSeconds(seconds: Double?): Double? {
        val value = seconds ?: return null
        if (!value.isFinite() || abs(value) > MAX_ABS_SECONDS) return null
        return (value * 10.0).roundToLong() / 10.0
    }
}
