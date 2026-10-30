package com.vortx.android.engine

import java.security.MessageDigest
import java.util.UUID

/** Volatile receipt metadata only. No tokens, account keys, or complete account bodies are retained. */
internal class NativePlaylistCloudReceiptLedger {
    internal data class Fingerprint(private val bytes: List<Byte>) {
        companion object {
            fun of(canonicalRegister: ByteArray): Fingerprint =
                Fingerprint(MessageDigest.getInstance("SHA-256").digest(canonicalRegister).toList())
        }
    }
    internal data class Ticket(val id: UUID, val field: String, val fingerprint: Fingerprint)
    internal data class Frozen(val id: UUID, val field: String, val fingerprint: Fingerprint)
    internal sealed interface State {
        data object Unknown : State
        data object Pending : State
        data class Saved(val version: Long) : State
    }
    private data class Entry(val owner: Any, val ticket: Ticket, var original: ByteArray?, var version: Long? = null)
    private val entries = LinkedHashMap<UUID, Entry>()
    private var pendingBytes = 0

    /** Caller must validate the complete raw register and original target before invoking. */
    @Synchronized fun register(owner: Any, edit: UUID, field: String, canonicalRegister: ByteArray): Ticket? {
        if (!field.startsWith("playlist.v1.") || field.length > 512 ||
            field.toByteArray(Charsets.UTF_8).size > 512 || canonicalRegister.size > MAX_REGISTER_BYTES ||
            entries.containsKey(edit)) return null
        val bytes = canonicalRegister.copyOf()
        val ticket = Ticket(edit, field, Fingerprint.of(bytes))
        entries[ticket.id] = Entry(owner, ticket, bytes)
        pendingBytes += bytes.size
        evict()
        return ticket.takeIf { entries.containsKey(it.id) }
    }
    /** Only these identities may be acknowledged by an upload that starts after this call. */
    @Synchronized fun freeze(): List<Frozen> = entries.values.asSequence().filter { it.version == null }
        .map { Frozen(it.ticket.id, it.ticket.field, it.ticket.fingerprint) }.toList()
    @Synchronized fun owner(frozen: Frozen): Any? = entries[frozen.id]?.takeIf {
        it.version == null && it.ticket.field == frozen.field && it.ticket.fingerprint == frozen.fingerprint
    }?.owner
    /** Caller owns original target and exact accepted candidate/version admission. */
    @Synchronized fun acknowledge(frozen: Frozen, acceptedCanonicalRegister: ByteArray, version: Long): Boolean {
        if (version < 0 || acceptedCanonicalRegister.size > MAX_REGISTER_BYTES) return false
        val entry = entries[frozen.id] ?: return false
        val original = entry.original ?: return false
        if (entry.version != null || entry.ticket.field != frozen.field || entry.ticket.fingerprint != frozen.fingerprint ||
            !MessageDigest.isEqual(original, acceptedCanonicalRegister)) return false
        entry.version = version
        pendingBytes -= original.size
        entry.original = null
        return true
    }
    @Synchronized fun state(owner: Any, ticket: Ticket, current: Fingerprint): State {
        val entry = entries[ticket.id] ?: return State.Unknown
        if (entry.owner !== owner || entry.ticket != ticket || ticket.fingerprint != current) return State.Unknown
        return entry.version?.let(State::Saved) ?: State.Pending
    }
    @Synchronized fun retire() { entries.clear(); pendingBytes = 0 }
    @Synchronized fun retire(owner: Any) {
        val iterator = entries.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next().value
            if (entry.owner === owner) { pendingBytes -= entry.original?.size ?: 0; iterator.remove() }
        }
    }
    private fun evict() {
        while (entries.size > MAX_ENTRIES || pendingBytes > MAX_PENDING_BYTES) {
            val iterator = entries.entries.iterator()
            if (!iterator.hasNext()) break
            val item = iterator.next().value
            pendingBytes -= item.original?.size ?: 0
            iterator.remove()
        }
    }
    companion object {
        private const val MAX_ENTRIES = 64
        private const val MAX_PENDING_BYTES = 4 * 1024 * 1024
        private const val MAX_REGISTER_BYTES = 513 * 1024
    }
}
