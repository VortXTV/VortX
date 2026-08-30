package com.vortx.android.player

import android.content.Context
import com.vortx.android.player.mpv.MpvPlayer

/// `full` flavor factory: builds the real libmpv [PlayerEngine]. This is the flavor-specific half of the
/// seam declared (contract-only) in [PlayerEngine]. Returns null when libmpv cannot start on this device
/// (missing native `.so` for the running ABI, OOM), so [PlayerEngineRouter.engine] falls back to
/// ExoPlayer instead of crashing. [MpvPlayer.create] itself never throws: it wraps native failure and
/// returns null.
object MpvEngineFactory {
    const val isBundled: Boolean = true

    fun create(context: Context): PlayerEngine? = createSafely { MpvPlayer.create(context) }

    /** Native linkage and class initialization failures are Errors, not Exceptions. */
    internal fun createSafely(createMpv: () -> PlayerEngine?): PlayerEngine? = try {
        createMpv()
    } catch (_: Throwable) {
        null
    }
}
