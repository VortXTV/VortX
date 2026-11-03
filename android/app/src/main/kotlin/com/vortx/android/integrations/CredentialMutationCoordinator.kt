package com.vortx.android.integrations

import com.vortx.android.security.AccountFileProviderWriters
import com.vortx.android.sync.SessionOwnerSnapshot

/**
 * Orders durable credential publication against explicit sign-out.
 *
 * An operation captures one generation before its asynchronous work starts. Network work runs without
 * holding [mutationLock], then publication rechecks the generation while holding that same lock. Sign-out
 * advances the generation before clearing durable state, so an older response can never restore credentials.
 */
internal class CredentialMutationCoordinator(private val nativeKeys: Set<String>? = null) {
    private val mutationLock = Any()
    private var generation = 0L
    private val outbound = mutableSetOf<ProviderCallTicket>()

    fun operation(): Operation = synchronized(mutationLock) {
        Operation(generation, nativeKeys?.let { runCatching { NativeProviderAccess.capture(it) {}?.first }.getOrNull() })
    }

    fun <T> snapshot(read: () -> T): CredentialOperationSnapshot<T> =
        synchronized(mutationLock) {
            if (nativeKeys == null) CredentialOperationSnapshot(Operation(generation, null), read())
            else runCatching { NativeProviderAccess.capture(requireNotNull(nativeKeys), read) }.getOrNull()?.let { (guard, value) ->
                CredentialOperationSnapshot(Operation(generation, guard), value)
            } ?: CredentialOperationSnapshot(Operation(generation, null), read())
        }

    /** Credential lock precedes native provider owner admission. An unavailable original
     * never invokes the read against a replacement owner. */
    fun <T> snapshotForOwner(expected: SessionOwnerSnapshot.Account, read: () -> T): CredentialOperationSnapshot<T>? =
        synchronized(mutationLock) {
            val keys = nativeKeys ?: return@synchronized null
            runCatching { NativeProviderAccess.captureForOwner(expected, keys, read) }.getOrNull()?.let { (guard, value) ->
                CredentialOperationSnapshot(Operation(generation, guard), value)
            }
        }

    fun snapshotRetryForOwner(
        expected: SessionOwnerSnapshot.Account,
        persistedOwnerEpoch: Long,
        dataKey: ByteArray,
        provider: ProviderRetryCredentialProof.Provider,
        eligible: (NativeProviderAccess.RetryCredential) -> Boolean,
    ): DurableProviderMirrorCredential? = synchronized(mutationLock) {
        if (nativeKeys != provider.keys.toSet()) return@synchronized null
        val captured = NativeProviderAccess.captureRetryCredential(expected, persistedOwnerEpoch, dataKey, provider)
            ?: return@synchronized null
        var handedOff = false
        try {
            if (!eligible(captured)) return@synchronized null
            DurableProviderMirrorCredential(captured, Operation(generation, captured.guard), eligible).also {
                handedOff = true
            }
        } finally {
            if (!handedOff) captured.close()
        }
    }

    fun invalidate(mutation: () -> Unit) {
        synchronized(mutationLock) {
            generation += 1
            outbound.forEach(ProviderCallTicket::retire)
            outbound.clear()
            if (nativeKeys == null) mutation()
            else check(NativeProviderAccess.capture(nativeKeys, mutation) != null) { "Provider account unavailable" }
        }
    }

    internal inner class Operation internal constructor(
        private val expectedGeneration: Long,
        private val nativeGuard: NativeProviderAccess.Guard?,
    ) {
        fun ownsRetryGuard(guard: NativeProviderAccess.Guard): Boolean =
            guard.isExistingOnlyRetry && nativeGuard === guard

        fun isCurrent(): Boolean = synchronized(mutationLock) {
            generation == expectedGeneration && (nativeKeys == null || nativeGuard?.let { runCatching { NativeProviderAccess.current(it) }.getOrDefault(false) } == true)
        }

        fun <T> mutate(mutation: () -> T): CredentialMutationResult<T> =
            synchronized(mutationLock) {
                if (generation != expectedGeneration) {
                    CredentialMutationResult.Stale
                } else if (nativeKeys != null) {
                    nativeGuard?.let { guard -> NativeProviderAccess.guarded(guard) { CredentialMutationResult.Applied(mutation()) } }
                        ?: CredentialMutationResult.Stale
                } else {
                    CredentialMutationResult.Applied(mutation())
                }
            }

        fun attachOutbound(ticket: ProviderCallTicket): Boolean = synchronized(mutationLock) {
            val guard = nativeGuard ?: return@synchronized false
            generation == expectedGeneration && NativeProviderAccess.attachOutbound(guard, ticket) && outbound.add(ticket)
        }

        fun claimOutbound(ticket: ProviderCallTicket, claim: () -> Boolean): Boolean = synchronized(mutationLock) {
            val guard = nativeGuard ?: return@synchronized false
            generation == expectedGeneration && ticket in outbound && NativeProviderAccess.claimOutbound(guard, ticket, claim)
        }

        fun closeOutbound(ticket: ProviderCallTicket) {
            synchronized(mutationLock) {
                outbound.remove(ticket)
                NativeProviderAccess.detachOutbound(ticket)
            }
        }

        /** Only a read after acquiring the provider's single-flight mutex may reuse a peer winner. */
        fun <T> readCurrentOwner(read: () -> T): CredentialMutationResult<T> = synchronized(mutationLock) {
            if (generation != expectedGeneration) CredentialMutationResult.Stale
            else if (nativeKeys == null) CredentialMutationResult.Applied(read())
            else nativeGuard?.let { guard -> NativeProviderAccess.readCurrentOwner(guard) { CredentialMutationResult.Applied(read()) } }
                ?: CredentialMutationResult.Stale
        }

        suspend fun <T, R> publishAfter(
            awaitValue: suspend () -> T,
            publish: (T) -> R,
        ): CredentialMutationResult<R> {
            if (nativeGuard?.isExistingOnlyRetry == true) return CredentialMutationResult.Stale
            if (nativeKeys == null) {
                val value = awaitValue()
                return mutate { publish(value) }
            }
            // A device poll may consume its code and a refresh can rotate a remote token
            // before the response arrives. Keep Restore out through structured cleanup and
            // the same owner-fenced publication. Neither admission monitor spans the await.
            return AccountFileProviderWriters.withEffectfulWriter<CredentialMutationResult<R>>(
                CredentialMutationResult.Stale,
            ) {
                if (!isCurrent()) return@withEffectfulWriter CredentialMutationResult.Stale
                val value = awaitValue()
                mutate { publish(value) }
            }
        }
    }
}

/** One provider's exact captured original, its ordinary retirement generation, and a live expiry gate. */
internal class DurableProviderMirrorCredential(
    private val captured: NativeProviderAccess.RetryCredential,
    val operation: CredentialMutationCoordinator.Operation,
    private val eligible: (NativeProviderAccess.RetryCredential) -> Boolean,
) : AutoCloseable {
    init { require(operation.ownsRetryGuard(captured.guard)) }

    val guard: NativeProviderAccess.Guard get() = captured.guard
    val bearer: String get() = captured.accessToken
    fun copyProof(): ByteArray? = captured.copyProof()

    /** The operation separately rechecks exact owner, vault, selected events and local creation time. */
    fun matches(): Boolean = captured.isOpen() && eligible(captured)
    override fun close() { captured.close() }
}

internal data class CredentialOperationSnapshot<T>(
    val operation: CredentialMutationCoordinator.Operation,
    val value: T,
)

internal sealed interface CredentialMutationResult<out T> {
    data object Stale : CredentialMutationResult<Nothing>
    data class Applied<T>(val value: T) : CredentialMutationResult<T>
}
