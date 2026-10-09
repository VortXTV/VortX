package com.vortx.android.player.mpv

/**
 * Orders automatic resume, explicit seeks and load commands through their actual native dispatch.
 * MPV's bare warm/START_FILE callbacks carry no source identity. Only the first load on a fresh
 * decoder may automatically resume; replacement uses a fresh engine in the normal player path.
 * Reusing a decoder keeps manual seeks, but permanently retires automatic resume on that decoder.
 *
 * Native destroy must run AFTER [release] returns, never while this monitor is held. Terminal
 * admission may acquire the terminal gate under this monitor; the terminal gate never calls back in.
 */
internal class MpvSeekCommandArbiter(
    private val command: (Array<String>) -> Unit,
    private val durationMs: () -> Long,
) {
    internal class Load internal constructor(internal val automaticResumeEligible: Boolean) {
        internal var dispatched = false
        internal var manualOverride = false
        internal var retired = false
    }

    private val lock = Any()
    private var released = false
    private var hasBegunLoad = false
    private var active: Load? = null
    private var pendingResumeMs = 0L

    /** Called at load ENTRY, before property/setup work or any callback can reuse the old intent. */
    fun beginLoad(resetTerminal: () -> Unit = {}): Load? = synchronized(lock) {
        if (released) return@synchronized null
        pendingResumeMs = 0L
        val load = Load(automaticResumeEligible = !hasBegunLoad)
        hasBegunLoad = true
        active = load
        try {
            // Install the ticket and reset terminal classification as one transaction. An old END_FILE
            // must not see the new ticket while the terminal gate still accepts the previous source.
            resetTerminal()
        } catch (failure: Throwable) {
            retire(load)
            throw failure
        }
        load.takeIf(::accepts)
    }

    /** The existing audio-files clear/append commands belong to the same captured load. */
    fun commandForLoad(load: Load, arguments: Array<String>): Boolean = synchronized(lock) {
        if (!accepts(load) || load.dispatched) return@synchronized false
        try {
            command(arguments)
        } catch (failure: Throwable) {
            retire(load)
            throw failure
        }
        accepts(load)
    }

    fun load(load: Load, url: String, resumeMs: Long): Boolean = synchronized(lock) {
        if (!accepts(load) || load.dispatched) return@synchronized false
        load.dispatched = true
        // Arm before dispatch: the command boundary may synchronously admit a warm callback.
        pendingResumeMs = if (load.automaticResumeEligible && !load.manualOverride) {
            resumeMs.coerceAtLeast(0L)
        } else 0L
        try {
            command(arrayOf("loadfile", url, "replace"))
        } catch (failure: Throwable) {
            retire(load)
            throw failure
        }
        accepts(load)
    }

    fun onWarm() = synchronized(lock) {
        val load = active ?: return@synchronized
        if (!accepts(load)) return@synchronized
        val target = pendingResumeMs
        pendingResumeMs = 0L
        if (target <= RESUME_FLOOR_MS) return@synchronized
        val duration = durationMs()
        if (duration > 0L && target >= duration - RESUME_TAIL_GUARD_MS) return@synchronized
        // Recheck after the injected state read as well: reentrant manual/release/load wins too.
        if (!accepts(load) || load.manualOverride) return@synchronized
        command(arrayOf("seek", (target / 1000.0).toString(), "absolute"))
    }

    fun seekTo(positionMs: Long) = manualSeek(positionMs.coerceAtLeast(0L), "absolute")

    fun seekBy(deltaMs: Long) = manualSeek(deltaMs, "relative")

    private fun manualSeek(valueMs: Long, mode: String) = synchronized(lock) {
        if (released) return@synchronized
        pendingResumeMs = 0L
        active?.manualOverride = true
        // Keep the monitor until native dispatch finishes: a consumed auto target cannot overtake
        // an accepted manual command, including zero and relative commands during load preparation.
        command(arrayOf("seek", (valueMs / 1000.0).toString(), mode))
    }

    /** Rejected/duplicate/stale callbacks and a continuing redirect do not retire a current load. */
    fun <T : Any> onTerminal(retiresLoad: Boolean = true, accept: () -> T?): T? = synchronized(lock) {
        val load = active
        val result = accept()
        if (result != null && load != null && retiresLoad) retire(load)
        result
    }

    fun release() = synchronized(lock) {
        released = true
        pendingResumeMs = 0L
        active?.retired = true
    }

    private fun accepts(load: Load): Boolean = !released && active === load && !load.retired

    private fun retire(load: Load) {
        load.retired = true
        if (active === load) pendingResumeMs = 0L
    }

    companion object {
        private const val RESUME_FLOOR_MS = 5_000L
        private const val RESUME_TAIL_GUARD_MS = 10_000L
    }
}
