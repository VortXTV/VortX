package com.vortx.android.player

import android.content.Context

/// `play` flavor factory: libmpv is NEVER packaged in the Play-Store build (the GPLv3 mpv/ffmpeg native
/// libs are scoped to `fullImplementation`), so this always returns null and [PlayerEngineRouter.engine]
/// always resolves to the ExoPlayer engine. This is the flavor-specific half of the seam declared
/// (contract-only) in [PlayerEngine]; keeping it here means the `play` variant has no reference to any
/// libmpv class and compiles clean without the AAR.
object MpvEngineFactory {
    fun create(context: Context): PlayerEngine? = null
}
