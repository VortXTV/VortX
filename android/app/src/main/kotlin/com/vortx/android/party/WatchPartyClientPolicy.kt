package com.vortx.android.party

/** No credentials, player objects, I/O, or Android dependencies in admission. */
internal data class WatchPartyOwnerStamp(
    val generation: String,
    val outerSessionId: Long,
    val sourceRevision: Long,
    val titleToken: String,
    val accountId: String,
    val profileId: String,
    val ownerEpoch: Long,
) { override fun toString() = "WatchPartyOwner(redacted)" }
internal data class WatchPartyProof(val nonce: String, val room: String, val term: Long, val sequence: Long, val remainingMs: Long)
internal data class WatchPartyApplyPermit(val owner: WatchPartyOwnerStamp, val clockEpoch: String, val room: String, val term: Long, val sequence: Long)

/** A rollback retires this clock epoch permanently; a later forward observation cannot resurrect it. */
internal class WatchPartyClientPolicy(
    val owner: WatchPartyOwnerStamp, val clockEpoch: String,
    val room: String, val term: Long, initialSequence: Long, startedAt: Long,
) {
    var sequence: Long = initialSequence; private set
    var deadline: Long = startedAt; private set
    var lastTime: Long = startedAt; private set
    var cancelled = false; private set
    private var appliedSequence: Long? = null
    var anchored = false; private set
    init { require(WatchPartyWire.opaque(room) && term in 1..MAX_SAFE_INTEGER && initialSequence in 0..MAX_SAFE_INTEGER && startedAt >= 0) }
    fun observe(now: Long): Boolean {
        if (cancelled || now < 0 || now < lastTime) { cancelled = true; return false }
        lastTime = now; return true
    }
    fun acceptProof(proof: WatchPartyProof, expectedNonce: String, startedAt: Long, now: Long, bootstrap: Boolean): Boolean {
        if (!observe(now) || proof.nonce != expectedNonce || proof.room != room || proof.term != term ||
            startedAt < 0 || startedAt > now || proof.remainingMs !in 1000..30_000 ||
            proof.sequence !in 0..MAX_SAFE_INTEGER || (if (bootstrap) proof.sequence < sequence else proof.sequence != sequence) ||
            startedAt > Long.MAX_VALUE - proof.remainingMs || now >= startedAt + proof.remainingMs) return false
        sequence = proof.sequence; deadline = startedAt + proof.remainingMs; anchored = true
        return true
    }
    /** Transport acknowledgement is not a proof and cannot grant or extend a lease. */
    fun connectedBaseline(room: String, term: Long, sequence: Long, now: Long): Boolean {
        if (!observe(now) || anchored || room != this.room || term != this.term ||
            sequence < this.sequence || sequence > MAX_SAFE_INTEGER) return false
        this.sequence = sequence; return true
    }
    /** Bootstrap deliberately discards controls; only the subsequent nonce proof grants a baseline. */
    fun bootstrapEvent(room: String, term: Long, sequence: Long, now: Long): Boolean {
        if (!observe(now) || anchored || room != this.room || term != this.term || sequence <= this.sequence || sequence > MAX_SAFE_INTEGER) return false
        this.sequence = sequence; return true
    }
    fun admitEvent(room: String, term: Long, sequence: Long, now: Long): Boolean {
        if (!observe(now) || !anchored || now >= deadline || room != this.room || term != this.term ||
            this.sequence >= MAX_SAFE_INTEGER || sequence != this.sequence + 1) return false
        this.sequence = sequence; return true
    }
    fun permit(control: WatchPartyWire.Control, now: Long): WatchPartyApplyPermit? =
        if (!observe(now) || !anchored || now >= deadline || control.mediaId != owner.titleToken) null
        else WatchPartyApplyPermit(owner, clockEpoch, room, term, sequence)
    /** Caller holds its real owner monitor and immediately mutates the player without suspension. */
    fun consume(permit: WatchPartyApplyPermit, current: WatchPartyOwnerStamp?, now: Long): Boolean {
        if (!observe(now) || now >= deadline || !anchored || current != owner || permit.owner != owner ||
            permit.clockEpoch != clockEpoch || permit.room != room || permit.term != term ||
            permit.sequence != sequence || appliedSequence == sequence) return false
        appliedSequence = sequence; return true
    }
    fun live(now: Long): Boolean = observe(now) && anchored && now < deadline
    fun cancel() { cancelled = true; anchored = false }
    companion object {
        /** Refresh at most five seconds apart and always before a previously clamped member deadline. */
        fun refreshDelay(now: Long, deadline: Long): Long = ((deadline - now) / 3).coerceIn(100L, 5000L)
    }
}


/** An older HTTP completion cannot discharge a lease event observed while it was suspended. */
internal class WatchPartyRefreshLedger {
    var required: Long = 0; private set
    var covered: Long = 0; private set
    fun leaseObserved(sequence: Long) { require(sequence in 1..MAX_SAFE_INTEGER); required = maxOf(required, sequence) }
    fun beginRefresh(): Long = required
    fun completeRefresh(obligation: Long) { require(obligation in 0..required); covered = maxOf(covered, obligation) }
    val needsRefresh: Boolean get() = required > covered
}

/** Bounded exact historical duplicates only. Unknown or evicted nonces never gain ignore authority. */
internal class WatchPartyRetiredNonces(private val capacity: Int = 32) {
    private val values = java.util.ArrayDeque<String>()
    init { require(capacity in 1..64) }
    fun retire(nonce: String) {
        require(WatchPartyWire.opaque(nonce))
        if (!values.contains(nonce)) values.addLast(nonce)
        while (values.size > capacity) values.removeFirst()
    }
    fun contains(nonce: String): Boolean = values.contains(nonce)
}
