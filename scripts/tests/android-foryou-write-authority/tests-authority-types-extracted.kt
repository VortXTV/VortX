package com.vortx.android.sync

/** Stable identity of the exact captured command scope; deliberately has no value-bearing toString. */
internal class LocalLibraryMutationIdentity(
    private val manager: Any,
    private val session: Any?,
    private val operationGeneration: Long,
    private val ownerEpoch: Long,
) {
    override fun equals(other: Any?): Boolean = other is LocalLibraryMutationIdentity &&
        manager === other.manager && session === other.session &&
        operationGeneration == other.operationGeneration && ownerEpoch == other.ownerEpoch
    override fun hashCode(): Int = (((System.identityHashCode(manager) * 31 + System.identityHashCode(session)) * 31 +
        operationGeneration.hashCode()) * 31 + ownerEpoch.hashCode())
}

/** A command gate and its independently comparable original identity; neither can be refreshed in place. */
internal class LocalLibraryMutationAuthority internal constructor(
    internal val identity: Any,
    private val admission: (() -> Boolean) -> Boolean,
) {
    fun admit(action: () -> Boolean): Boolean = admission(action)
}
