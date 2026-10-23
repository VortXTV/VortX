package com.vortx.android.engine

import kotlinx.coroutines.CancellationException

/** The caller still owns reservation release inside [close]; a failed close is never acknowledged here. */
internal fun runNativeRetirementAttempt(close: () -> Unit, onUnconfirmed: () -> Unit) {
    try {
        close()
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (_: Exception) {
        onUnconfirmed()
    }
}
