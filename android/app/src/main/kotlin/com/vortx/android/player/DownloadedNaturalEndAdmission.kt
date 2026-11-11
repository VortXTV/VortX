package com.vortx.android.player

import com.vortx.android.model.Playable
import com.vortx.android.model.cwItemIsFinished

/** One revocable end-of-file offer for an exact mounted player generation. Main-thread use only. */
class DownloadedNaturalEndAdmission internal constructor(private val stillEnded: () -> Boolean) {
    private var retired = false

    internal fun isCurrent(): Boolean = !retired && stillEnded()

    internal fun retire() {
        retired = true
    }
}

internal fun isDownloadedNaturalCompletion(playable: Playable, state: PlayerState): Boolean {
    if (!state.hasEnded || state.hasError || playable.userForcedSource ||
        !canReportPlayerProgress(playable, state.positionMs, state.durationMs) ||
        isJunkPlayerEof(state.positionMs, state.durationMs, playable)) return false
    return cwItemIsFinished("series", state.positionMs.toFloat() / state.durationMs, 0, 0)
}
