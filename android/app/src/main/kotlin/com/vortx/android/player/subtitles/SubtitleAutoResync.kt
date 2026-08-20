package com.vortx.android.player.subtitles

import android.content.Context
import com.vortx.android.player.SubtitleOffsetMemory
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * Automatic subtitle sync alignment layered on top of the existing manual [SubtitleOffsetMemory]. The Kotlin
 * port of the auto-resync half of Apple's player integration (`restoreSubtitleTimingOffsetIfReady` + the pool
 * seed in `fetchPooledSubtitles` + `captureSubOffset` in PlayerScreen.swift / TVPlayerView.swift).
 *
 * Apple has no separate local audio-alignment pass: the "auto-resync" IS the community-learned per-rip offset
 * from the subtitle pool ([SubtitlePoolClient.fetchPooled]'s `offsetMs`), applied AUTOMATICALLY when the viewer
 * has not already dialled in their own manual offset, and the viewer's own manual nudges are contributed back
 * ([SubtitlePoolClient.postOffset]) so the pool learns. This module is the pure, deterministic resolution +
 * capture policy behind that behaviour; the engine still owns applying the resolved delay (libmpv `sub-delay`;
 * ExoPlayer has no live sub-delay knob and documents its apply as a no-op).
 *
 * PRECEDENCE (mirrors Apple exactly): the viewer's own manual offset always wins. It is restored FIRST and
 * marks the session seeded, which blocks the community offset from overriding it. The community offset is only
 * applied when there is no manual offset AND nothing has seeded the session yet. Once seeded, neither re-applies
 * (idempotent) so a late pool response never yanks subtitles the viewer already positioned.
 */
object SubtitleAutoResync {

    /** Where a resolved offset came from, so the caller can log / surface it honestly. */
    enum class OffsetSource { NONE, MANUAL, COMMUNITY }

    /**
     * The outcome of one resolution pass.
     *
     * @param seconds the subtitle delay to apply, in seconds, rounded to 0.1 s (matching Apple).
     * @param seeded  whether the session is now seeded (a nonzero offset was chosen, or one already was).
     * @param source  which layer supplied [seconds]; [OffsetSource.NONE] when nothing applied.
     */
    data class Resolution(val seconds: Double, val seeded: Boolean, val source: OffsetSource)

    /** Bound on any applied/captured offset, byte-for-byte Apple's `abs(subDelay) <= 120`. */
    const val MAX_ABS_SECONDS = 120.0

    /**
     * Resolve the subtitle delay to apply, layering the manual offset over the community-learned one.
     *
     * @param manualOffsetSeconds the viewer's own saved offset for this scope (from [SubtitleOffsetMemory]), or
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
        if (manual != null && manual != 0.0) {
            return Resolution(manual, seeded = true, source = OffsetSource.MANUAL)
        }

        val community = poolOffsetMs?.let { sanitizedSeconds(secondsFromMs(it)) }
        if (community != null && community != 0.0) {
            return Resolution(community, seeded = true, source = OffsetSource.COMMUNITY)
        }

        // A manual offset that sanitizes to exactly zero (an explicit reset) still counts as the viewer having
        // decided: mark seeded so the community offset does not later override the reset.
        val seededByManualZero = manualOffsetSeconds != null
        return Resolution(0.0, seeded = seededByManualZero, source = OffsetSource.NONE)
    }

    /**
     * Convenience one-shot for the player: read the manual offset for [contentKey] from [SubtitleOffsetMemory]
     * and layer the community [poolOffsetMs] over it. Returns the same [Resolution] as [resolve].
     */
    fun resolveForPlayback(
        context: Context,
        contentKey: String?,
        poolOffsetMs: Int?,
        alreadySeeded: Boolean,
    ): Resolution {
        val manual = SubtitleOffsetMemory.savedOffset(context, contentKey)
        return resolve(manualOffsetSeconds = manual, poolOffsetMs = poolOffsetMs, alreadySeeded = alreadySeeded)
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

    /** A pool offset in ms as seconds, rounded to 0.1 s exactly as Apple rounds it. */
    private fun secondsFromMs(ms: Int): Double = (ms / 1000.0 * 10.0).roundToLong() / 10.0

    /** Reject a non-finite or out-of-bounds offset; otherwise round to 0.1 s like the memory + pool paths. */
    private fun sanitizedSeconds(seconds: Double?): Double? {
        val value = seconds ?: return null
        if (!value.isFinite() || abs(value) > MAX_ABS_SECONDS) return null
        return (value * 10.0).roundToLong() / 10.0
    }
}
