package com.vortx.android.trickplay

import java.util.concurrent.atomic.AtomicLong

/** Revokes every contribution admission made before an opt-out. */
internal class TrickplayConsentGate {
    private val generation = AtomicLong(0L)

    fun admit(): Long = generation.get()

    fun permits(admission: Long): Boolean = generation.get() == admission

    fun revoke() {
        generation.incrementAndGet()
    }
}
