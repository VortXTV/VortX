package com.vortx.android.player.subtitles

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * One automatic pooled-file attempt bound to the original engine/source/choice and owner receipt.
 * No authority is recaptured after suspension. Download and mount cancellation/errors propagate.
 *
 * [permits] is a cheap current-owner check, not an atomic final native-mount admission. [mount] must
 * await its actual mount job and serialize its own final receipt check with revocation on the existing
 * engine boundary. The caller supplies account/profile/engine admission through these callbacks.
 */
internal suspend fun <Receipt : Any> runAutomaticPooledSubtitleSelection(
    capture: () -> Receipt?,
    permits: (Receipt) -> Boolean,
    download: suspend () -> String?,
    mount: suspend (String, Receipt) -> Unit,
): Boolean {
    currentCoroutineContext().ensureActive()
    val original = capture() ?: return false
    if (!permits(original)) return false
    currentCoroutineContext().ensureActive()
    val local = download()
    currentCoroutineContext().ensureActive()
    if (local == null || !permits(original)) return false
    currentCoroutineContext().ensureActive()
    mount(local, original)
    currentCoroutineContext().ensureActive()
    val current = permits(original)
    currentCoroutineContext().ensureActive()
    return current
}
