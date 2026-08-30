package com.vortx.android.player.mpv

/// Single-lock terminal gate for one [MpvPlayer] instance: owns `released`, the per-source
/// [MpvTerminalState], and WHEN state may publish. Extracted verbatim from the player so the exact
/// production wiring -- teardown gating, replacement suppression windows, first-callback-wins
/// reduction, publication-under-the-same-lock-as-reset -- is unit-testable against scripted
/// adversarial callback sequences without a native handle.
///
/// The lock discipline this class enforces (and tests pin down):
///   - A late terminal after [release] is dropped entirely: teardown must never let an
///     already-dispatched native callback publish EOF into watched/auto-advance.
///   - [beginReplacementLoad] resets classification AND publishes the UI reset under ONE lock hold,
///     so a stale old-source terminal cannot slip between reset and publication.
///   - An old-source terminal arriving inside the replacement window (after the new load began,
///     before the new source's START_FILE re-arms classification) is suppressed: mpv guarantees the
///     old file's END_FILE is queued before the new file's START_FILE on the SAME client queue, and
///     this window is exactly that span observed from our side of the seam.
internal class MpvTerminalGate(
    private val publish: (
        hasEnded: Boolean,
        hasError: Boolean,
        isBuffering: Boolean,
        terminal: Boolean,
    ) -> Unit,
) {
    private val lock = Any()

    private var state = MpvTerminalState.initialSource()

    @Volatile
    private var released = false

    /// First load of this player instance: fresh classification + "connecting" publication.
    fun beginFirstLoad() {
        synchronized(lock) {
            state = MpvTerminalState.initialSource()
            publish(false, false, true, false)
        }
    }

    /// Replacement load (`loadfile replace` over a live instance): wipe the previous source's
    /// verdict, arm the suppression window for the old source's one remaining END_FILE, and publish
    /// the reset -- all under the same lock hold as [onTerminal]'s, so neither side can interleave.
    fun beginReplacementLoad() {
        synchronized(lock) {
            state = state.onSourceReplacement()
            publish(false, false, true, false)
        }
    }

    /// START_FILE of the (new) source: closes the replacement-suppression window so terminals can be
    /// classified again. No UI publication; START_FILE carries no verdict.
    fun onSourceStarted() {
        synchronized(lock) {
            state = state.onSourceStarted()
        }
    }

    /// One END_FILE-derived terminal callback. Returns the newly-applied state when THIS call changed
    /// it (so the caller can log the verdict), or null when the callback was dropped (teardown race,
    /// duplicate idempotence, or replacement suppression). Publication happens under the same lock
    /// as the state transition, which is what makes reset-vs-terminal ordering total.
    fun onTerminal(event: MpvTerminalEvent): MpvTerminalState? {
        synchronized(lock) {
            if (released) return null
            val next = state.onTerminal(event)
            if (next == state) return null
            state = next
            publish(next.hasEnded, next.hasError, false, true)
            return next
        }
    }

    /// Teardown gate. Called BEFORE observer unregistration / native destroy so an in-flight
    /// dispatched callback racing teardown can still acquire the lock but will observe released.
    fun release() {
        synchronized(lock) {
            released = true
        }
    }
}
