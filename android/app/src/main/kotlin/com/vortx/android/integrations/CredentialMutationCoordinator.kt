package com.vortx.android.integrations

/**
 * Orders durable credential publication against explicit sign-out.
 *
 * An operation captures one generation before its asynchronous work starts. Network work runs without
 * holding [mutationLock], then publication rechecks the generation while holding that same lock. Sign-out
 * advances the generation before clearing durable state, so an older response can never restore credentials.
 */
internal class CredentialMutationCoordinator {
    private val mutationLock = Any()
    private var generation = 0L

    fun operation(): Operation = synchronized(mutationLock) {
        Operation(generation)
    }

    fun <T> snapshot(read: () -> T): CredentialOperationSnapshot<T> =
        synchronized(mutationLock) {
            CredentialOperationSnapshot(Operation(generation), read())
        }

    fun invalidate(mutation: () -> Unit) {
        synchronized(mutationLock) {
            generation += 1
            mutation()
        }
    }

    internal inner class Operation internal constructor(
        private val expectedGeneration: Long,
    ) {
        fun isCurrent(): Boolean = synchronized(mutationLock) {
            generation == expectedGeneration
        }

        fun <T> mutate(mutation: () -> T): CredentialMutationResult<T> =
            synchronized(mutationLock) {
                if (generation != expectedGeneration) {
                    CredentialMutationResult.Stale
                } else {
                    CredentialMutationResult.Applied(mutation())
                }
            }

        suspend fun <T, R> publishAfter(
            awaitValue: suspend () -> T,
            publish: (T) -> R,
        ): CredentialMutationResult<R> {
            val value = awaitValue()
            return mutate { publish(value) }
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
