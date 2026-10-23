package com.vortx.android.player.mpv

/** Metadata-only correlation. Caller owns subtitleGenerationGate; native events arrive in FIFO order. */
internal class MpvMetadataLoadIdentity {
    data class Read internal constructor(val generation: Long, val entryID: Long)
    private var generation: Long? = null
    private var expected: Long? = null
    private var started: Long? = null
    private var loaded: Long? = null
    private var uncertain = false

    fun begin(generation: Long) {
        this.generation = generation
        expected = null; started = null; loaded = null; uncertain = false
    }

    fun commandReturned(generation: Long, entryID: Long?) {
        if (this.generation != generation) return
        expected = entryID?.takeIf { it >= 0L }
    }

    fun started(entryID: Long) {
        started = entryID.takeIf { generation != null && it >= 0L }
        loaded = null
    }

    fun loaded() { loaded = started }
    fun ended() { started = null; loaded = null }
    fun queueOverflow() { uncertain = true; ended() }
    fun retire() { generation = null; expected = null; ended() }

    fun capture(generation: Long, playingEntryID: Long?): Read? {
        val id = expected ?: return null
        if (uncertain || this.generation != generation || started != id || loaded != id ||
            playingEntryID != id) return null
        return Read(generation, id)
    }

    fun accepts(read: Read, generation: Long, playingEntryID: Long?): Boolean =
        capture(generation, playingEntryID) == read
}
