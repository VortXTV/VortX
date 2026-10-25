package com.vortx.android.player

import java.util.concurrent.atomic.AtomicBoolean

/**
 * One immutable player-owner lifetime. It contains no account ID, profile ID or credential and cannot
 * be renewed. The app passes the SAME one-way cell to its MPV native handle gate; only epoch writers
 * retire it. Already admitted old work may finish only on this old, never-rebound engine context.
 */
class PlaybackOwnerToken internal constructor() {
    internal val nativeLiveness = AtomicBoolean(true)
    val isActive: Boolean get() = nativeLiveness.get()
    internal fun retire() { nativeLiveness.set(false) }
}
