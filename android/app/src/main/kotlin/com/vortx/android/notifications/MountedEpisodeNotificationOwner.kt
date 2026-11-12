package com.vortx.android.notifications

import com.vortx.android.VortXApplication
import com.vortx.android.engine.NativeAccountCoordinator
import com.vortx.android.engine.VortxNativeSession
import com.vortx.android.player.PlaybackOwnerEpoch
import com.vortx.android.player.PlaybackOwnerToken
import com.vortx.android.profile.ContinueWatchingOwnerGate
import com.vortx.android.profile.NativeProfileGateway
import com.vortx.android.profile.ProfileStore
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.sync.VortXSyncManager
import kotlinx.coroutines.CancellationException

internal sealed interface EpisodeNotificationOwnerObservation {
    data object Unavailable : EpisodeNotificationOwnerObservation
    data object SignedOut : EpisodeNotificationOwnerObservation
    class Mounted(
        val owner: EpisodeNotificationOwner,
        private val app: VortXApplication,
        private val manager: VortXSyncManager,
        private val coordinator: NativeAccountCoordinator,
        private val session: VortxNativeSession,
        private val account: SessionOwnerSnapshot.Account,
        private val store: ProfileStore,
        private val ownerEpoch: PlaybackOwnerToken,
        private val prepared: NativeProfileGateway.PreparedProjection,
    ) : EpisodeNotificationOwnerObservation {
        /** Ordinary playback may advance the native update stamp while a sweep fetches metadata. */
        fun refreshForScheduling(): Mounted? {
            if (!PlaybackOwnerEpoch.isCurrent(ownerEpoch)) return null
            val fresh = captureEpisodeNotificationOwner(app) as? Mounted ?: return null
            return fresh.takeIf {
                it.owner == owner && it.ownerEpoch === ownerEpoch && it.session === session && it.account == account
            }
        }

        /** Match profile writes: host owner -> Session -> authenticated admission -> mounted lifecycle. */
        fun publishIfCurrent(action: () -> Unit): Boolean = ContinueWatchingOwnerGate.serialized {
            synchronized(session) {
                var published = false
                prepared.publishIfCurrent {
                    if (PlaybackOwnerEpoch.isCurrent(ownerEpoch) && app.syncManager === manager &&
                        coordinator.isPickerMountCurrent(session, account) &&
                        ProfileStore.sharedOrNull() === store && store.activeProfile.value?.id == owner.profileId) {
                        action()
                        published = true
                    }
                } && published
            }
        }
    }
}

/** Called only on the workers' IO lane. A missing mount or profile is transient until proved otherwise. */
internal fun captureEpisodeNotificationOwner(app: VortXApplication): EpisodeNotificationOwnerObservation {
    val unavailable = EpisodeNotificationOwnerObservation.Unavailable
    return try {
        val ownerEpoch = PlaybackOwnerEpoch.capture() ?: return unavailable
        val manager = app.syncManager ?: return unavailable
        val account = when (val state = manager.sessionOwnerSnapshot()) {
            is SessionOwnerSnapshot.Account -> state
            is SessionOwnerSnapshot.SignedOutLocal -> return EpisodeNotificationOwnerObservation.SignedOut
            is SessionOwnerSnapshot.UnknownOrUnavailable -> return unavailable
        }
        val coordinator = app.nativeStreamingAccounts()
        val session = coordinator.session()
        if (!coordinator.isPickerMountCurrent(session, account)) return unavailable
        val prepared = coordinator.captureProfilePresentation(session)
        val store = ProfileStore.sharedOrNull() ?: return unavailable
        val active = store.activeProfile.value ?: return unavailable
        if (prepared.requiresRecovery || prepared.projection.activeID != active.id ||
            prepared.projection.profiles.none { it.id == active.id }) return unavailable
        val owner = EpisodeNotificationOwner.parse(session.scope.digest, active.id) ?: return unavailable
        if (!PlaybackOwnerEpoch.isCurrent(ownerEpoch) || !coordinator.isPickerMountCurrent(session, account))
            return unavailable
        EpisodeNotificationOwnerObservation.Mounted(
            owner, app, manager, coordinator, session, account, store, ownerEpoch, prepared,
        )
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        unavailable
    } catch (_: LinkageError) {
        unavailable
    }
}
