package com.vortx.android.player

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.upstream.DefaultAllocator
import com.vortx.android.player.tuning.AdaptiveBufferPlan

/**
 * The ExoPlayer [androidx.media3.exoplayer.LoadControl] VortX runs instead of the stock default, tuned for
 * the heavy Dolby Vision / Atmos 4K remuxes the router sends to this engine. A stock [DefaultLoadControl]
 * caps its target buffer at about 200 MiB and keeps modest default durations, which lets a variable-bitrate
 * 4K peak drain the buffer faster than it fills and stutter. This control:
 *
 *   - Buffers 40 s to 120 s of media (`setBufferDurationsMs(40_000, 120_000, 3_000, 3_000)`) so a dip in
 *     throughput has a deep runway, while only needing 3 s buffered to (re)start playback.
 *   - Keeps a 1.5 s back-buffer retained from the last keyframe (`setBackBuffer(1_500, true)`) so a small
 *     seek-back is instant without holding much already-played data.
 *   - Allocates in 64 KiB units (`DefaultAllocator(true, 64 * 1024)`), trimmed on reset.
 *   - OVERRIDES [calculateTargetBufferBytes] to return a RAM-tier budget from [DeviceMemoryTier] instead
 *     of the ~200 MiB default, so on a capable device the buffer is allowed to hold a real 4K peak rather
 *     than being starved by the stock ceiling. On a small device the tier is small, keeping the buffer
 *     clear of jetsam.
 *
 * WHY the override is honored (media3 1.9.4): [DefaultLoadControl.onTracksSelected] uses a per-player
 * overwrite when one is set (the builder's `setTargetBufferBytes`), otherwise it calls
 * `calculateTargetBufferBytes(parameters, trackSelections)`, which delegates to the deprecated
 * `calculateTargetBufferBytes(trackSelections)` we override here and returns its value directly (bypassing
 * the default ~200 MiB clamp) whenever it is not `C.LENGTH_UNSET`. We pass `C.LENGTH_UNSET` for the
 * constructor's target-bytes argument (so no fixed overwrite is set) and let this override supply the value.
 *
 * Built only when the [BufferTuningSetting] flag is on; when off, [ExoPlayerEngine] builds a stock player.
 */
@UnstableApi
class VortxExoLoadControl private constructor(
    allocator: DefaultAllocator,
    private val targetBufferBytesOverride: Int,
    minBufferMs: Int,
    maxBufferMs: Int,
    bufferForPlaybackMs: Int,
    bufferForPlaybackAfterRebufferMs: Int,
) : DefaultLoadControl(
    allocator,
    // (streaming, local-playback) pairs; VortX uses the same value for both, matching the builder's
    // behavior when only the generic setBufferDurationsMs is called. The durations are constructor params
    // now (defaulted by [create] to the merged RAM-tier values) so the adaptive planner can vary them per
    // the viewer's buffer intent + measured link speed without a second LoadControl subclass.
    minBufferMs, minBufferMs,
    maxBufferMs, maxBufferMs,
    bufferForPlaybackMs, bufferForPlaybackMs,
    bufferForPlaybackAfterRebufferMs, bufferForPlaybackAfterRebufferMs,
    // targetBufferBytes: C.LENGTH_UNSET means "no fixed overwrite"; the override below supplies the value.
    C.LENGTH_UNSET,
    // prioritizeTimeOverSizeThresholds (streaming, local): false, so the size target is honored.
    false, false,
    BACK_BUFFER_MS, RETAIN_BACK_BUFFER_FROM_KEYFRAME,
) {

    /**
     * Return the RAM-tier target so a 4K VBR peak is not starved by the stock ceiling. media3 1.9.4 calls
     * this from the `Parameters` overload and returns the result directly when it is not `C.LENGTH_UNSET`,
     * so a positive value here IS the target buffer size in bytes.
     */
    override fun calculateTargetBufferBytes(trackSelectionArray: Array<out ExoTrackSelection>): Int =
        targetBufferBytesOverride

    companion object {
        // Buffer durations, in ms. 40 s minimum forward buffer, 120 s maximum, 3 s to (re)start playback.
        private const val MIN_BUFFER_MS = 40_000
        private const val MAX_BUFFER_MS = 120_000
        private const val BUFFER_FOR_PLAYBACK_MS = 3_000
        private const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 3_000

        // Back-buffer: keep 1.5 s of already-played media, retained from the last keyframe.
        private const val BACK_BUFFER_MS = 1_500
        private const val RETAIN_BACK_BUFFER_FROM_KEYFRAME = true

        // Allocator: 64 KiB allocation unit, trimmed on reset.
        private const val ALLOCATION_UNIT_BYTES = 64 * 1024
        private const val TRIM_ON_RESET = true

        private const val BYTES_PER_MB = 1024 * 1024

        /**
         * Build a [VortxExoLoadControl] sized to this device's RAM tier, with the merged buffer durations.
         * The target-buffer bytes come from [DeviceMemoryTier.safeBufferMb], which is fail-soft (an unknown
         * RAM reads back as the 2 GB tier). This is the RAM-tier baseline the adaptive [create] refines.
         */
        fun create(context: Context): VortxExoLoadControl {
            val allocator = DefaultAllocator(TRIM_ON_RESET, ALLOCATION_UNIT_BYTES)
            val targetBytes = DeviceMemoryTier.safeBufferMb(context) * BYTES_PER_MB
            return VortxExoLoadControl(
                allocator,
                targetBytes,
                MIN_BUFFER_MS,
                MAX_BUFFER_MS,
                BUFFER_FOR_PLAYBACK_MS,
                BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
            )
        }

        /**
         * Build a [VortxExoLoadControl] from an [AdaptiveBufferPlan] (device RAM tier + viewer buffer
         * intent + measured link speed). At [com.vortx.android.player.tuning.BufferIntentProfile.BALANCED]
         * with no link measurement the plan reproduces the merged RAM-tier values exactly, so this is a
         * superset of [create], never a behavior change until the viewer picks another profile or a sweep
         * lands. The allocator + back-buffer are unchanged.
         */
        fun create(plan: AdaptiveBufferPlan): VortxExoLoadControl {
            val allocator = DefaultAllocator(TRIM_ON_RESET, ALLOCATION_UNIT_BYTES)
            // The plan's target is already clamped to this device's RAM budget by the planner.
            return VortxExoLoadControl(
                allocator,
                plan.targetBufferBytes,
                plan.minBufferMs,
                plan.maxBufferMs,
                plan.bufferForPlaybackMs,
                plan.bufferForPlaybackMs,
            )
        }
    }
}
