package com.vortx.android.player

import android.content.Context
import com.vortx.android.player.mpv.MpvPlayer
import kotlinx.coroutines.CancellationException

/// `full` flavor factory: builds the real libmpv [PlayerEngine]. This is the flavor-specific half of the
/// seam declared (contract-only) in [PlayerEngine]. Returns null when libmpv cannot start on this device
/// (missing native `.so` for the running ABI, OOM), so [PlayerEngineRouter.engine] falls back to
/// ExoPlayer instead of crashing. [MpvPlayer.create] itself never throws: it wraps native failure and
/// returns null.
object MpvEngineFactory {
    const val isBundled: Boolean = true

    fun create(context: Context): PlayerEngine? = recoverNativeFailure("native-linkage") {
        MpvPlayer.create(context)
    }

    /** Native linkage and class initialization failures are Errors, not Exceptions. */
    internal fun createSafely(createMpv: () -> PlayerEngine?): PlayerEngine? =
        recoverNativeFailure("native-linkage", createMpv)
}

/** Converts expected optional-native failures to null without hiding process-fatal conditions. */
internal inline fun <T> recoverNativeFailure(stage: String, action: () -> T?): T? = try {
    action()
} catch (failure: Throwable) {
    when (failure) {
        is VirtualMachineError,
        is ThreadDeath,
        is CancellationException,
        -> throw failure
        is LinkageError,
        is Exception,
        -> {
            val message = "VortX optional native fallback stage=$stage failure=${failure.javaClass.name}"
            runCatching { android.util.Log.w("MpvEngineFactory", message) }
                .onFailure { System.err.println(message) }
            null
        }
        else -> throw failure
    }
}
