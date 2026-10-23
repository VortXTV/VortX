package com.vortx.android.diagnostics

import kotlinx.coroutines.CancellationException

/** Fixed, credential-free outcomes shared by Settings and the pre-Settings export action. */
internal enum class DiagnosticShareOutcome(val message: String?) {
    SHARED(null),
    NO_RECEIVER("No app on this device can receive the log."),
    FAILED("Could not share the diagnostic log. Please try again."),
    BLOCKED("The profile changed or is locked. Open it again before sharing the log."),
}

/** Only ordinary staging/share failures become UI copy. Cancellation and fatal errors still propagate. */
internal suspend fun <T> performDiagnosticShare(
    stage: suspend () -> T,
    present: (T) -> Boolean,
    mayShare: () -> Boolean = { true },
): DiagnosticShareOutcome = try {
    if (!mayShare()) DiagnosticShareOutcome.BLOCKED else {
        val export = stage()
        if (!mayShare()) DiagnosticShareOutcome.BLOCKED
        else if (present(export)) DiagnosticShareOutcome.SHARED else DiagnosticShareOutcome.NO_RECEIVER
    }
} catch (cancel: CancellationException) {
    throw cancel
} catch (_: Exception) {
    DiagnosticShareOutcome.FAILED
}
