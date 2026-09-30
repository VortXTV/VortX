package com.vortx.android.data

import com.vortx.android.downloads.WatchedDownloadReclaimRequest
import com.vortx.android.model.PlaybackContext

/**
 * One local-play cleanup latch. It intentionally accepts facts in either order, but invokes [verifyAndReclaim]
 * exactly once only after it has an exact committed-watch receipt and the player reports its resources
 * are no longer held. Every current-state check happens at that final boundary, not at play launch.
 */
internal class DurableWatchReclaimCoordinator(
    private val request: WatchedDownloadReclaimRequest,
    private val capturedOwner: ContinueWatchingOwner,
    private val verifyAndReclaim: (DurableWatchedPlaybackReceipt, WatchedDownloadReclaimRequest) -> Boolean,
) {
    private val lock = Any()
    private var durableWatch: DurableWatchedPlaybackReceipt? = null
    private var resourcesReleased = false
    private var flushed = false

    fun onDurableWatch(receipt: DurableWatchedPlaybackReceipt) = synchronized(lock) {
        if (receipt.owner != capturedOwner || !request.matches(receipt.context)) return@synchronized
        durableWatch = receipt
        flushIfReady()
    }

    fun onResourcesReleased() = synchronized(lock) {
        resourcesReleased = true
        flushIfReady()
    }

    private fun flushIfReady() {
        val receipt = durableWatch ?: return
        if (!resourcesReleased || flushed) return
        flushed = true
        verifyAndReclaim(receipt, request)
    }
}

private fun WatchedDownloadReclaimRequest.matches(context: PlaybackContext): Boolean =
    context.owner == owner &&
        context.contentId == contentId &&
        context.videoId == videoId &&
        context.type == type &&
        context.title == title &&
        context.season == season &&
        context.episode == episode

/**
 * Counts every decoder and lease installed during one outer player mount. A source or episode
 * replacement may dispose an old holder before it constructs a new one, so its request callback is
 * retained as an immutable generation registration and is released only after the *outer* player has
 * gone away and every holder from every replacement has finished. This deliberately trades immediate
 * deletion after a replacement for proof that no current holder can still reference the local file.
 */
internal class PlayerResourceReleaseGate {
    private val lock = Any()
    private var boundDecoders = 0
    private var boundLeases = 0
    private var sessionDisposed = false
    private var fired = false
    private val releaseCallbacks = LinkedHashMap<Any, () -> Unit>()

    /** Captures the callback once for this exact source/episode generation; it is never updated. */
    fun registerReleaseCallback(generation: Any, onReleased: () -> Unit) = synchronized(lock) {
        releaseCallbacks.putIfAbsent(generation, onReleased)
    }

    fun decoderBound() = synchronized(lock) { boundDecoders += 1 }
    fun decoderReleased() = synchronized(lock) {
        if (boundDecoders > 0) boundDecoders -= 1
        releaseIfReady()
    }
    fun leaseBound() = synchronized(lock) { boundLeases += 1 }
    fun leaseReleased() = synchronized(lock) {
        if (boundLeases > 0) boundLeases -= 1
        releaseIfReady()
    }
    fun sessionDisposed() = synchronized(lock) {
        sessionDisposed = true
        releaseIfReady()
    }

    private fun releaseIfReady() {
        if (!fired && sessionDisposed && boundLeases == 0 && boundDecoders == 0) {
            fired = true
            releaseCallbacks.values.forEach { it() }
        }
    }
}
