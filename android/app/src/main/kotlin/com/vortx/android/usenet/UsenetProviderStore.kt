package com.vortx.android.usenet

import android.content.Context
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.security.FailClosedCredentialStore
import com.vortx.android.security.PersistentCredentialAvailability
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/** A coherent owner-scoped read, bound to a process revision for stale-resolution rejection. */
internal sealed interface UsenetProviderRead {
    val owner: DebridOwnerToken?
    data class Available(override val owner: DebridOwnerToken, val servers: UsenetProviderServerList, val revision: Long) : UsenetProviderRead
    data class Missing(override val owner: DebridOwnerToken, val revision: Long) : UsenetProviderRead
    /** Non-empty ciphertext that cannot be decoded, or an unavailable owner/backend. Never auto-overwrite it. */
    data class UnavailableOrCorrupt(override val owner: DebridOwnerToken?, val revision: Long) : UsenetProviderRead
}

/**
 * Coordinates the two locks that protect a saved-server document.  The credential-owner transaction is
 * always outermost: it fences an account transition for the entire document operation, and prevents a
 * resolver read (store -> owner) racing a settings save (owner -> store) from deadlocking.
 */
internal object UsenetProviderOwnerTransaction {
    fun <T : Any> run(
        owner: DebridOwnerToken,
        mutateCurrentOwner: (DebridOwnerToken, () -> Boolean) -> Boolean,
        storeLock: Any,
        rejected: () -> T,
        operation: () -> T,
    ): T {
        var value: T? = null
        val accepted = mutateCurrentOwner(owner) {
            synchronized(storeLock) {
                value = operation()
            }
            true
        }
        return if (accepted) checkNotNull(value) else rejected()
    }
}

/**
 * Encrypted owner-scoped source of truth for saved NNTP accounts. The whole priority list is one document;
 * all mutations include an expected revision, preventing an edit from erasing another server list change.
 */
internal class UsenetProviderStore(
    context: Context,
    private val currentOwner: () -> DebridOwnerToken?,
    private val mutateCurrentOwner: (DebridOwnerToken, () -> Boolean) -> Boolean = { owner, mutation ->
        if (UsenetCredentialOwnerPolicy.permits(owner, currentOwner())) mutation() else false
    },
) {
    private val store = FailClosedCredentialStore(context, ENCRYPTED_FILE, PLAIN_FALLBACK_FILE, TAG)

    fun snapshot(owner: DebridOwnerToken? = currentOwner()): UsenetProviderRead {
        owner ?: return UsenetProviderRead.UnavailableOrCorrupt(null, 0)
        return UsenetProviderOwnerTransaction.run(
            owner = owner,
            mutateCurrentOwner = mutateCurrentOwner,
            storeLock = lock(owner),
            rejected = { UsenetProviderRead.UnavailableOrCorrupt(owner, revision(owner)) },
        ) {
            val currentRevision = revision(owner)
            val confirmed = store.confirmedSnapshot(storageKey(owner))
            // A read outage is not evidence of absence. Only a persistent, confirmed null may be displayed
            // as Missing or accepted by a subsequent mutation.
            if (confirmed.availability != PersistentCredentialAvailability.AVAILABLE) {
                UsenetProviderRead.UnavailableOrCorrupt(owner, currentRevision)
            } else {
                val raw = confirmed.values[storageKey(owner)]
                if (raw == null) UsenetProviderRead.Missing(owner, currentRevision)
                else UsenetProviderServerList.decode(raw)?.let { UsenetProviderRead.Available(owner, it, currentRevision) }
                    ?: UsenetProviderRead.UnavailableOrCorrupt(owner, currentRevision)
            }
        }
    }

    /** Compatibility read for the old single-provider settings surfaces. */
    fun load(owner: DebridOwnerToken? = currentOwner()): UsenetProviderCredentials? =
        (snapshot(owner) as? UsenetProviderRead.Available)?.servers?.firstEnabledCredentials

    fun isConfigured(owner: DebridOwnerToken? = currentOwner()): Boolean = load(owner) != null

    /**
     * Save a complete list only if based on [expectedRevision]. A corrupt non-empty encrypted value returns
     * false: it is deliberately not reclassified as an empty list and cannot be overwritten by this call.
     */
    fun saveServers(
        servers: List<UsenetProviderServer>,
        expectedRevision: Long,
        owner: DebridOwnerToken? = currentOwner(),
    ): Boolean {
        owner ?: return false
        val next = UsenetProviderServerList(servers = servers)
        if (!UsenetProviderServerList.isValid(next)) return false
        return UsenetProviderOwnerTransaction.run(
            owner = owner,
            mutateCurrentOwner = mutateCurrentOwner,
            storeLock = lock(owner),
            rejected = { false },
        ) {
            if (revision(owner) != expectedRevision) {
                false
            } else {
                val confirmed = store.confirmedSnapshot(storageKey(owner))
                val raw = confirmed.values[storageKey(owner)]
                if (confirmed.availability != PersistentCredentialAvailability.AVAILABLE ||
                    (raw != null && UsenetProviderServerList.decode(raw) == null)
                ) {
                    false
                } else {
                    val saved = store.set(mapOf(storageKey(owner) to next.toJson().toString()))
                    if (saved) bump(owner)
                    saved
                }
            }
        }
    }

    /** Old one-server writes update the first server in-place and preserve every fallback after it. */
    fun save(credentials: UsenetProviderCredentials, owner: DebridOwnerToken? = currentOwner()): Boolean {
        if (!credentials.isValid) return false
        val read = snapshot(owner)
        val revision = when (read) {
            is UsenetProviderRead.Available -> read.revision
            is UsenetProviderRead.Missing -> read.revision
            is UsenetProviderRead.UnavailableOrCorrupt -> return false
        }
        val old = (read as? UsenetProviderRead.Available)?.servers?.servers.orEmpty()
        // Legacy callers mean “the active single provider”; retain their old behaviour by replacing the
        // first enabled server, while still preserving every other server and its priority slot.
        val first = old.firstOrNull { it.enabled } ?: old.firstOrNull()
        val replacement = UsenetProviderServer(
            id = first?.id ?: UsenetProviderServer.LEGACY_ID,
            name = first?.name?.takeIf { it.isNotBlank() } ?: credentials.host.trim(),
            host = credentials.host, port = credentials.port, username = credentials.username,
            password = credentials.password, maxConnections = credentials.maxConnections, useSSL = credentials.useSSL,
            enabled = first?.enabled ?: true,
        )
        return saveServers(
            if (first == null) listOf(replacement) else old.map { if (it.id == first.id) replacement else it },
            revision,
            owner,
        )
    }

    fun clear(owner: DebridOwnerToken? = currentOwner()): Boolean {
        val read = snapshot(owner)
        val revision = when (read) {
            is UsenetProviderRead.Available -> read.revision
            is UsenetProviderRead.Missing -> return true
            is UsenetProviderRead.UnavailableOrCorrupt -> return false
        }
        return saveServers(emptyList(), revision, owner)
    }

    fun isCurrent(owner: DebridOwnerToken, expectedRevision: Long): Boolean =
        UsenetCredentialOwnerPolicy.permits(owner, currentOwner()) && revision(owner) == expectedRevision

    private fun storageKey(owner: DebridOwnerToken): String = UsenetCredentialOwnerPolicy.storageKey(PREFIX, owner)
    private fun revision(owner: DebridOwnerToken): Long = revisions.getOrPut(storageKey(owner)) { AtomicLong() }.get()
    private fun bump(owner: DebridOwnerToken) { revisions.getOrPut(storageKey(owner)) { AtomicLong() }.incrementAndGet() }

    companion object {
        const val TAG = "UsenetProviderStore"
        const val ENCRYPTED_FILE = "vortx_usenet_credentials"
        const val PLAIN_FALLBACK_FILE = "${ENCRYPTED_FILE}_plain"
        const val PREFIX = "vortx.usenet.provider."
        private val revisions = ConcurrentHashMap<String, AtomicLong>()
        private val locks = ConcurrentHashMap<String, Any>()
        private fun lock(owner: DebridOwnerToken): Any = locks.getOrPut("$PREFIX${owner.scope.storageSuffix}") { Any() }
    }
}
