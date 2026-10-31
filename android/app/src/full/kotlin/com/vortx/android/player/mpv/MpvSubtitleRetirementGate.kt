package com.vortx.android.player.mpv

/**
 * Source changes may discard old EOF/error evidence; they may not discard cleanup of the same
 * permanent native handle. Reserve before first close, release only from the real close receipt.
 * No callback, native operation or wait occurs under this state-only monitor.
 */
internal class MpvSubtitleRetirementGate<T> {
    class Ticket internal constructor(internal val owner: Any)
    sealed interface Resolution<out T> {
        data object None : Resolution<Nothing>
        data class Terminal<T>(val generation: Long, val verdict: T) : Resolution<T>
        data object HandleUnavailable : Resolution<Nothing>
    }

    private val lock = Any()
    private val owner = Any()
    private val pending = mutableSetOf<Ticket>()
    private var generation = 0L
    private var terminal: Resolution.Terminal<T>? = null
    private var retired = false
    private var unavailable = false

    val isUsable: Boolean get() = synchronized(lock) { !retired && !unavailable }

    fun beginSource(originalGeneration: Long): Boolean = synchronized(lock) {
        if (retired || unavailable) return@synchronized false
        generation = originalGeneration
        terminal = null
        true
    }

    fun beginRetirement(): Ticket? = synchronized(lock) {
        if (retired || unavailable) null else Ticket(owner).also(pending::add)
    }

    fun onTerminal(originalGeneration: Long, verdict: T): Resolution<T> = synchronized(lock) {
        if (retired || unavailable || originalGeneration != generation) return@synchronized Resolution.None
        val result = Resolution.Terminal(originalGeneration, verdict)
        if (pending.isEmpty()) result else { terminal = result; Resolution.None }
    }

    fun complete(ticket: Ticket, teardownRequested: Boolean): Resolution<T> = synchronized(lock) {
        if (ticket.owner !== owner || !pending.remove(ticket) || retired) return@synchronized Resolution.None
        if (teardownRequested) {
            unavailable = true
            terminal = null
            return@synchronized Resolution.HandleUnavailable
        }
        if (unavailable || pending.isNotEmpty()) return@synchronized Resolution.None
        terminal.also { terminal = null }?.takeIf { it.generation == generation } ?: Resolution.None
    }

    /** Host retirement only. This is not a claim that JNI/native source cleanup has quiesced. */
    fun retire() = synchronized(lock) { retired = true; terminal = null; pending.clear() }
}
