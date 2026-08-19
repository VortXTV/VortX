package com.vortx.android.player.tuning

/**
 * The buffer configuration the adaptive tuner produces, fed to BOTH engines: ExoPlayer's LoadControl
 * (target bytes + durations) and libmpv's demuxer (`demuxer-max-bytes` via [ramFraction], plus
 * `demuxer-readahead-secs` and `cache-secs`). Immutable value type; the pure [AdaptiveBufferPlanner]
 * derives it, and the two construction sites read it.
 */
data class AdaptiveBufferPlan(
    /** ExoPlayer LoadControl target buffer, in bytes, already clamped to the RAM budget. */
    val targetBufferBytes: Int,
    /** ExoPlayer minimum forward buffer, ms. */
    val minBufferMs: Int,
    /** ExoPlayer maximum forward buffer, ms. */
    val maxBufferMs: Int,
    /** ExoPlayer buffer needed to (re)start playback, ms. */
    val bufferForPlaybackMs: Int,
    /** libmpv `demuxer-readahead-secs`. */
    val mpvReadaheadSecs: Int,
    /** libmpv `cache-secs`. */
    val mpvCacheSecs: Int,
    /** Fraction of the device RAM budget mpv's `demuxer-max-bytes` should use on the remote path. */
    val ramFraction: Double,
)

/**
 * Turns (device RAM budget, measured link speed, viewer intent) into an [AdaptiveBufferPlan]. This is the
 * Nuvio Phase 2 layer ON TOP of the merged RAM-tier ladder: the RAM budget is the ceiling
 * ([com.vortx.android.player.DeviceMemoryTier]), and this picks the CHEAPEST config inside it that still
 * sustains roughly [SUSTAIN_MULTIPLE]x a 4K VBR design peak given the measured link.
 *
 * The model:
 *   - Each [BufferIntentProfile] sets a baseline fraction of the RAM budget and the buffer durations.
 *     [BufferIntentProfile.BALANCED] with NO link measurement is byte-for-byte the merged RAM-tier
 *     behavior (fraction 1.0, 40 s..120 s, 3 s to start), so enabling adaptive tuning changes nothing
 *     until the viewer picks another profile or a link sweep lands.
 *   - When a link measurement exists, headroom = linkBps / ([SUSTAIN_MULTIPLE] * [PEAK_BITRATE_BPS]):
 *       - headroom < 1 (the link cannot comfortably carry 2x the peak): DEEPEN the buffer toward the RAM
 *         ceiling so a throughput dip has runway.
 *       - headroom >= [FAST_LINK_HEADROOM] (a very fast, roomy link): on the latency-first FAST profile
 *         only, take the CHEAPEST buffer (shrink the fraction) because a deep buffer would just waste RAM.
 *     BALANCED and STALL are never shrunk by a fast link, so the default stays stable and predictable.
 *
 * Pure and side-effect-free, so the whole decision is unit-testable without a device.
 */
object AdaptiveBufferPlanner {

    /** The 4K variable-bitrate design peak the buffer is sized to ride, ~40 Mbps. */
    const val PEAK_BITRATE_BPS: Long = 40_000_000L / 8 // bytes/s

    /** "~2x the stream bitrate" sustain target from the Nuvio Phase 2 brief. */
    const val SUSTAIN_MULTIPLE: Double = 2.0

    /** At or above this headroom the link is roomy enough to shrink the FAST profile's buffer. */
    const val FAST_LINK_HEADROOM: Double = 2.0

    /** Floor so a tiny RAM tier still keeps a usable ExoPlayer target buffer. */
    private const val MIN_TARGET_BYTES: Int = 24 * 1024 * 1024

    private const val BUFFER_FOR_PLAYBACK_MS = 3_000

    private data class Baseline(
        val fraction: Double,
        val minBufferMs: Int,
        val maxBufferMs: Int,
        val readaheadSecs: Int,
        val cacheSecs: Int,
    )

    private fun baseline(intent: BufferIntentProfile): Baseline = when (intent) {
        // Latency-first: half the RAM budget, short durations, modest read-ahead.
        BufferIntentProfile.FAST -> Baseline(0.5, 15_000, 45_000, 120, 120)
        // The merged RAM-tier baseline: full budget, 40 s..120 s, the proven 300 s VOD read-ahead.
        BufferIntentProfile.BALANCED -> Baseline(1.0, 40_000, 120_000, 300, 300)
        // Stall-first: full budget, the deepest durations + read-ahead the tier allows.
        BufferIntentProfile.STALL -> Baseline(1.0, 60_000, 180_000, 600, 600)
    }

    /**
     * @param ramBudgetBytes device RAM buffer budget (the ceiling), from [com.vortx.android.player
     *   .DeviceMemoryTier.safeBufferMb] converted to bytes.
     * @param linkBps measured sustained link speed (bytes/s) or null when no sweep has run.
     * @param intent the viewer's [BufferIntentProfile].
     */
    fun plan(ramBudgetBytes: Long, linkBps: Long?, intent: BufferIntentProfile): AdaptiveBufferPlan {
        val base = baseline(intent)
        var fraction = base.fraction
        var maxBufferMs = base.maxBufferMs
        var readaheadSecs = base.readaheadSecs

        val headroom = linkBps?.let { it.toDouble() / (SUSTAIN_MULTIPLE * PEAK_BITRATE_BPS) }
        if (headroom != null) {
            when {
                // Marginal link: deepen toward the ceiling so a dip does not starve the decoder.
                headroom < 1.0 -> {
                    fraction = maxOf(fraction, 0.85)
                    maxBufferMs = maxOf(maxBufferMs, 120_000)
                    readaheadSecs = maxOf(readaheadSecs, 300)
                }
                // Roomy link: only the latency-first profile shrinks (cheapest buffer that still sustains).
                headroom >= FAST_LINK_HEADROOM && intent == BufferIntentProfile.FAST -> {
                    fraction = maxOf(0.4, fraction * 0.8)
                }
            }
        }

        val target = (ramBudgetBytes * fraction)
            .toLong()
            .coerceIn(MIN_TARGET_BYTES.toLong(), ramBudgetBytes.coerceAtLeast(MIN_TARGET_BYTES.toLong()))
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()

        return AdaptiveBufferPlan(
            targetBufferBytes = target,
            minBufferMs = base.minBufferMs,
            maxBufferMs = maxBufferMs,
            bufferForPlaybackMs = BUFFER_FOR_PLAYBACK_MS,
            mpvReadaheadSecs = readaheadSecs,
            mpvCacheSecs = base.cacheSecs,
            ramFraction = fraction,
        )
    }
}
