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

    fun invalidate(mutation: () -> Unit) {
        synchronized(mutationLock) {
            generation += 1
            if (nativeKeys == null) mutation()
            else check(NativeProviderAccess.capture(nativeKeys, mutation) != null) { "Provider account unavailable" }
        }
    }

    internal inner class Operation internal constructor(
        private val expectedGeneration: Long,
        private val nativeGuard: NativeProviderAccess.Guard?,
    ) {
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

internal data class CredentialOperationSnapshot<T>(
    val operation: CredentialMutationCoordinator.Operation,
    val value: T,
)

internal sealed interface CredentialMutationResult<out T> {
    data object Stale : CredentialMutationResult<Nothing>
    data class Applied<T>(val value: T) : CredentialMutationResult<T>
}
