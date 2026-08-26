package com.vortx.android.player.mpv

/**
 * Typed mpv end-file classification. Values mirror mpv_end_file_reason from libmpv client.h (the
 * header vendored at android/mpv-seam/src/main/cpp/include/mpv/client.h: EOF=0, STOP=2, QUIT=3,
 * ERROR=4, REDIRECT=5). Any other native code maps here as [MpvTerminalReason.UNKNOWN] and is
 * handled fail-safe downstream.
 */
enum class MpvTerminalReason {
    EOF,
    ERROR,
    STOP,
    QUIT,
    REDIRECT,
    UNKNOWN,
    ;

    companion object {
        internal fun fromNative(value: Int): MpvTerminalReason = when (value) {
            0 -> EOF
            2 -> STOP
            3 -> QUIT
            4 -> ERROR
            5 -> REDIRECT
            else -> UNKNOWN
        }
    }
}

/**
 * Payload delivered by the :mpv-seam JNI bridge for MPV_EVENT_END_FILE. Since W1-B the seam carries
 * the REAL mpv_event_end_file fields: [reason] verbatim and [nativeError] set when mpv reported an
 * error termination (0 / absent otherwise), so every classification below is native fact, not
 * inference.
 *
 * [nativeError] is mpv_event_end_file.error unchanged. It is meaningful for [MpvTerminalReason.ERROR]
 * and retained for diagnostics instead of being collapsed into a Boolean.
 */
data class MpvTerminalEvent(
    val reason: MpvTerminalReason,
    val nativeError: Int? = null,
) {
    companion object {
        /// The single mapping from raw native callback values to the typed event. UNKNOWN covers any
        /// reason code this libmpv generation does not define; it never guesses a reason.
        internal fun fromNative(reason: Int, error: Int): MpvTerminalEvent = MpvTerminalEvent(
            reason = MpvTerminalReason.fromNative(reason),
            // client.h documents .error as present only for ERROR terminations (0 otherwise); keep
            // the payload honest by carrying it only when there is one.
            nativeError = if (reason == MPV_END_FILE_REASON_ERROR && error != 0) error else null,
        )

        /// client.h `mpv_end_file_reason` ERROR value (vendored header, mpv v0.41.0).
        private const val MPV_END_FILE_REASON_ERROR = 4
    }
}

/**
 * Per-source terminal reducer. The first terminal callback wins, making duplicate native callbacks
 * idempotent and preventing a later callback from changing ERROR into EOF.
 */
internal data class MpvTerminalState(
    val reason: MpvTerminalReason? = null,
    val nativeError: Int? = null,
    val hasEnded: Boolean = false,
    val hasError: Boolean = false,
    private val terminalConsumed: Boolean = false,
    private val suppressReplacementTerminal: Boolean = false,
) {
    fun onSourceReplacement(): MpvTerminalState = MpvTerminalState(
        suppressReplacementTerminal = true,
    )

    fun onSourceStarted(): MpvTerminalState = if (terminalConsumed) {
        this
    } else {
        copy(suppressReplacementTerminal = false)
    }

    fun onTerminal(event: MpvTerminalEvent): MpvTerminalState {
        if (terminalConsumed) return this
        if (suppressReplacementTerminal) return this

        return when (event.reason) {
            MpvTerminalReason.EOF -> copy(
                reason = event.reason,
                nativeError = event.nativeError,
                hasEnded = true,
                hasError = false,
                terminalConsumed = true,
                suppressReplacementTerminal = false,
            )
            MpvTerminalReason.ERROR,
            MpvTerminalReason.UNKNOWN,
            -> copy(
                reason = event.reason,
                nativeError = event.nativeError,
                hasEnded = false,
                hasError = true,
                terminalConsumed = true,
                suppressReplacementTerminal = false,
            )
            MpvTerminalReason.STOP,
            MpvTerminalReason.QUIT,
            MpvTerminalReason.REDIRECT,
            -> copy(
                reason = event.reason,
                nativeError = event.nativeError,
                hasEnded = false,
                hasError = false,
                terminalConsumed = true,
                suppressReplacementTerminal = false,
            )
        }
    }

    companion object {
        fun initialSource(): MpvTerminalState = MpvTerminalState()
    }
}
