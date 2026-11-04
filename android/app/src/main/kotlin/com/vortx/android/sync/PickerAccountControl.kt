package com.vortx.android.sync

/** Opaque original account-control authority. Never render or log the retained session object. */
internal class PickerAccountSnapshot internal constructor(
    private val issuer: Any,
    private val authGeneration: Long,
    private val sessionGeneration: Long,
    private val ownerEpoch: Long,
    private val sessionIdentity: Any?,
    val account: VortXSyncManager.Account?,
) {
    internal fun matchesAuthority(manager: Any, auth: Long, session: Long): Boolean =
        issuer === manager && authGeneration == auth && sessionGeneration == session
    internal fun matchesOwner(manager: Any, epoch: Long, current: Any?): Boolean =
        issuer === manager && ownerEpoch == epoch && sessionIdentity === current
    internal fun <T> invalidate(coordinator: SessionOperationCoordinator, manager: Any,
        validate: () -> Boolean, mutation: () -> T): SessionMutationResult<T> =
        if (issuer !== manager) SessionMutationResult.Stale else
            coordinator.invalidateIfAuthorityCurrent(authGeneration, sessionGeneration, validate, mutation)
    override fun toString() = "PickerAccountSnapshot"
}
internal enum class PickerSignOutResult { SIGNED_OUT, STALE, STORAGE_UNAVAILABLE }

/** UI retirement may synchronously publish another owner. It never grants replacement authority. */
internal fun runPickerSignOut(
    isCurrent: () -> Boolean,
    retireUi: () -> Unit,
    signOut: () -> PickerSignOutResult,
): PickerSignOutResult {
    if (!isCurrent()) return PickerSignOutResult.STALE
    retireUi()
    if (!isCurrent()) return PickerSignOutResult.STALE
    return signOut()
}

/** Optional result collector; no callback executes under adoption locks and no credential is exposed. */
class PickerAuthCompletion internal constructor() {
    @Volatile private var captured: PickerAccountSnapshot? = null
    internal val owner: PickerAccountSnapshot? get() = captured
    internal fun record(owner: PickerAccountSnapshot) { if (captured == null) captured = owner }
    override fun toString() = "PickerAuthCompletion"
}
