package com.stremiox.android.player

import android.content.Context
import com.stremiox.android.player.mpv.MpvPlayer

/// `full` flavor factory: builds the real libmpv [PlayerEngine]. This is the flavor-specific half of the
/// seam declared (contract-only) in [PlayerEngine]. Returns null when libmpv cannot start on this device
/// (missing native `.so` for the running ABI, OOM), so [PlayerEngineRouter.engine] falls back to
/// ExoPlayer instead of crashing. [MpvPlayer.create] itself never throws: it wraps native failure and
/// returns null.
object MpvEngineFactory {
    fun create(context: Context): PlayerEngine? = MpvPlayer.create(context)
}
