package com.vortx.android.integrations

import com.vortx.android.account.AccountSyncGate
import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.CancellationException

internal enum class RatingProvider(val label: String, val toggle: String) {
    TRAKT("Trakt", ScrobbleService.KEY_TRAKT_RATINGS),
    SIMKL("SIMKL", ScrobbleService.KEY_SIMKL_RATINGS),
}

/** Contains no token. An account/profile transition invalidates even an A -> B -> A round trip. */
internal data class ExternalIntegrationOwner(
    val provider: RatingProvider,
    val sessionEpoch: Long,
    val profileId: String,
    val accountRevision: Long,
    val preferenceRevision: Long,
)

/** Injectable at the authenticated boundary, so offline tests exercise real paths and publication. */
internal interface ExternalIntegrationAccess {
    fun owner(provider: RatingProvider, ratings: Boolean = false): ExternalIntegrationOwner?
    fun current(owner: ExternalIntegrationOwner, ratings: Boolean = false): Boolean =
        owner(owner.provider, ratings) == owner
    fun <T> publish(owner: ExternalIntegrationOwner, ratings: Boolean = false, action: () -> T): T? =
        if (current(owner, ratings)) action() else null
    suspend fun request(owner: ExternalIntegrationOwner, method: String, path: String,
                        body: String? = null, ratings: Boolean = false): IntegrationsHttp.Response?
}

internal object ConnectedIntegrationAccess : ExternalIntegrationAccess {
    override fun <T> publish(owner: ExternalIntegrationOwner, ratings: Boolean, action: () -> T): T? =
        ContinueWatchingOwnerGate.serialized {
            if (!current(owner, ratings)) return@serialized null
            when (owner.provider) {
                RatingProvider.TRAKT -> TraktAuth.withSessionCurrent(owner.sessionEpoch, action)
                RatingProvider.SIMKL -> SIMKLAuth.withSessionCurrent(owner.sessionEpoch, action)
            }
        }

    override fun owner(provider: RatingProvider, ratings: Boolean): ExternalIntegrationOwner? =
        ContinueWatchingOwnerGate.serialized { revision ->
            if (!AccountSyncGate.activeProfileSyncsAccount()) return@serialized null
            if (ratings && !ScrobbleService.isToggleOn(provider.toggle, true)) return@serialized null
            val epoch = when (provider) {
                RatingProvider.TRAKT -> TraktAuth.currentSessionEpoch
                RatingProvider.SIMKL -> SIMKLAuth.currentSessionEpoch
            } ?: return@serialized null
            val profile = ProfileStore.sharedOrNull()?.activeProfileId ?: return@serialized null
            ExternalIntegrationOwner(provider, epoch, profile, revision,
                if (ratings) ScrobbleService.toggleChanges.value else 0L)
        }

    override suspend fun request(owner: ExternalIntegrationOwner, method: String, path: String,
                                 body: String?, ratings: Boolean): IntegrationsHttp.Response? {
        val allowed = { current(owner, ratings) }
        if (!allowed()) return null
        return try {
            when (owner.provider) {
                RatingProvider.TRAKT -> TraktAuth.sessionBoundRequest(method, path, owner.sessionEpoch, body, allowed)
                RatingProvider.SIMKL -> SIMKLAuth.sessionBoundRequest(method, path, owner.sessionEpoch, body, allowed)
            }?.takeIf { allowed() }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }
}
