package com.vortx.android.sync

/**
 * When a pending account upload may run. Playback reports progress every few seconds and every upload
 * rebuilds and re-encrypts the whole account document, so progress-only work waits until playback goes
 * quiet (no report for [PROGRESS_QUIET_MS]) or [PROGRESS_MAX_WAIT_MS] passes. Any other edit keeps the
 * ordinary cadence. Mirrors Apple `NativeForegroundSyncPolicy.PushQueue`.
 *
 * Not thread-safe: its owner ([DurablePendingSyncState]) serializes every call under its lock.
 */
internal class ProgressUploadWindow {
    /** Latest edit generation carrying something other than playback progress. */
    private var urgentGeneration: Long? = null
    /** First and latest progress reports not yet covered by an accepted upload. */
    private var progressSinceMs: Long? = null
    private var progressLatestMs: Long? = null

    val hasUrgent: Boolean get() = urgentGeneration != null

    fun record(generation: Long, progressOnly: Boolean, nowMs: Long) {
        if (progressOnly) {
            if (progressSinceMs == null) progressSinceMs = nowMs
            progressLatestMs = nowMs
        } else {
            urgentGeneration = generation
        }
    }

    /** An upload carrying edits up to [uploaded] was accepted while the attempt had reached [current]. */
    fun acknowledge(uploaded: Long, current: Long) {
        if (urgentGeneration?.let { it <= uploaded } == true) urgentGeneration = null
        if (uploaded == current) {
            progressSinceMs = null
            progressLatestMs = null
        } else {
            // Only progress reported during that upload remains; its window starts there.
            progressSinceMs = progressLatestMs
        }
    }

    /**
     * Milliseconds until the next upload attempt. Urgent work (or no recorded window, such as a pending
     * marker restored after a restart) waits [failureBackoffMs] or the ordinary [urgentDelayMs]. A
     * progress window never shortens the retry delay that follows a failed upload.
     */
    fun nextDelayMs(nowMs: Long, urgentDelayMs: Long, failureBackoffMs: Long?): UploadWait {
        val since = progressSinceMs
        val latest = progressLatestMs
        if (hasUrgent || since == null || latest == null) {
            return UploadWait(failureBackoffMs ?: urgentDelayMs, progressWindow = false)
        }
        val due = minOf(latest + PROGRESS_QUIET_MS, since + PROGRESS_MAX_WAIT_MS)
        return UploadWait(maxOf(due - nowMs, failureBackoffMs ?: 0L), progressWindow = true)
    }

    internal companion object {
        const val PROGRESS_QUIET_MS = 15_000L
        const val PROGRESS_MAX_WAIT_MS = 60_000L
    }
}

/** How long to wait, and whether the wait is only a playback-progress window an urgent edit may cut short. */
internal data class UploadWait(val delayMs: Long, val progressWindow: Boolean)
