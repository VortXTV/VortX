package com.vortx.android.sync
import kotlinx.coroutines.flow.MutableStateFlow
internal sealed interface SessionOwnerSnapshot {
    data class Account(val id: String, val generation: Long) : SessionOwnerSnapshot
}
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


// Synthetic auth/session storage collaborators; identity and capture method below are exact production source.
internal class VortXSyncManager {
    enum class SessionUiState { UnknownOrUnavailable, SignedOut, SignedIn }
    internal class Operations {
        var generation=1L
        fun <T> snapshot(action:(Long)->T):T=action(generation)
    }
    internal class SessionState {
        var value:Any?=null;var ownerEpoch=1L
        fun <T> serialized(action:()->T):T=action()
    }
    val operations=Operations();val sessionState=SessionState()
    val _sessionUiState=MutableStateFlow(SessionUiState.SignedOut)
    internal fun captureLocalLibraryMutationAuthority(): LocalLibraryMutationAuthority? =
        operations.snapshot { generation ->
            sessionState.serialized {
                if (_sessionUiState.value == SessionUiState.UnknownOrUnavailable) return@serialized null
                val expected = sessionState.value
                val epoch = sessionState.ownerEpoch
                val identity = LocalLibraryMutationIdentity(this, expected, generation, epoch)
                LocalLibraryMutationAuthority(identity) { dispatch ->
                    operations.snapshot { currentGeneration ->
                        sessionState.serialized {
                            currentGeneration == generation && sessionState.ownerEpoch == epoch &&
                                sessionState.value === expected && dispatch()
                        }
                    }
                }
            }
        }

}
