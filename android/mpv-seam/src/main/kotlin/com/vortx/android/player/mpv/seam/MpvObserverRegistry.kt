package com.vortx.android.player.mpv.seam

/** Callbacks may synchronously remove themselves during native teardown. Never iterate the live list. */
internal class MpvObserverRegistry<T> {
    private val observers = mutableListOf<T>()

    fun add(observer: T) = synchronized(observers) { observers.add(observer) }

    fun remove(observer: T) = synchronized(observers) { observers.remove(observer) }

    fun dispatch(callback: (T) -> Unit) {
        val snapshot = synchronized(observers) { observers.toList() }
        // No registry lock crosses client code. Changes take effect on the next dispatch.
        for (observer in snapshot) callback(observer)
    }
}
