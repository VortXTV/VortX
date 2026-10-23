package com.vortx.android.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Account sync's native compatibility boundary, not a fallback or a checkpoint acknowledgement.
 * Ordinary exceptions retain the caller's policy; VM/fatal errors are never caught here.
 */
internal suspend fun runNativeAccountAttempt(
    onUnavailable: () -> Unit,
    operation: suspend () -> Boolean,
): Boolean = try {
    operation()
} catch (cancel: CancellationException) {
    throw cancel
} catch (_: LinkageError) {
    // A cancelled operation must not publish a retry notice just because JNI resolution lost too.
    currentCoroutineContext().ensureActive()
    onUnavailable()
    false
}
