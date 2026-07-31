package com.vortx.android.iptv

import com.vortx.android.data.CatalogRepository
import com.vortx.android.model.InstalledAddon
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

internal data class IPTVCleanupActions(
    val installedAddons: suspend () -> Result<List<InstalledAddon>>,
    val removeAddon: suspend (InstalledAddon) -> Result<Unit>,
    val revoke: suspend (String) -> Boolean,
)

internal fun iptvCleanupActions(repo: CatalogRepository): IPTVCleanupActions =
    IPTVCleanupActions(
        installedAddons = repo::installedAddons,
        removeAddon = repo::removeAddon,
        revoke = IPTVConverterClient::revoke,
    )

/**
 * Testable application-start seam. The supplied scope owns the work beyond any screen lifetime; production
 * supplies the Application's supervised IO scope. Initialization and replay stay ordered in the same child.
 */
internal fun launchIPTVStartupCleanup(
    scope: CoroutineScope,
    initialize: () -> Unit,
    resumeAll: suspend () -> Boolean,
    onFailure: (Throwable) -> Unit,
): Job = scope.launch {
    try {
        initialize()
        resumeAll()
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        onFailure(error)
    }
}

internal sealed interface IPTVAddOutcome {
    data class Added(val cleanupJournalPending: Boolean) : IPTVAddOutcome
    data class Failed(
        val message: String,
        val cleanupState: IPTVCleanupFailureState,
    ) : IPTVAddOutcome
}

internal enum class IPTVCleanupFailureState {
    NONE,
    JOURNALED,
    UNCONFIRMED,
}

/**
 * Completes a Worker registration as a journaled transaction. The rollback intent is durable before add-on
 * installation starts. A successful local add is not reported until that intent is durably marked committed.
 */
internal class IPTVAddCoordinator(
    private val store: IPTVPlaylistStore,
    private val installAddon: suspend (String) -> Result<Unit>,
    private val cleanupActions: IPTVCleanupActions,
) {
    suspend fun complete(
        registration: IPTVRegistration,
        playlist: IPTVPlaylist,
        credentials: IPTVCredentials,
    ): IPTVAddOutcome {
        when (store.registrationSlot(registration.slug)) {
            IPTVRegistrationSlot.CONFLICT ->
                return IPTVAddOutcome.Failed(
                    message = "This playlist registration already exists. Nothing changed.",
                    cleanupState = IPTVCleanupFailureState.NONE,
                )
            IPTVRegistrationSlot.UNAVAILABLE ->
                return IPTVAddOutcome.Failed(
                    message = "Could not verify secure playlist storage. It was not installed or revoked.",
                    cleanupState = IPTVCleanupFailureState.UNCONFIRMED,
                )
            IPTVRegistrationSlot.AVAILABLE -> Unit
        }
        val pending = IPTVPendingCleanup(
            slug = registration.slug,
            transportUrl = registration.manifestUrl,
            origin = IPTVCleanupOrigin.ADD_ROLLBACK,
        )
        if (!store.beginCleanup(pending)) {
            val revoked = attemptRevoke(cleanupActions, registration.slug)
            return IPTVAddOutcome.Failed(
                message = if (revoked) {
                    "Could not safely stage this playlist. It was not installed. Try again."
                } else {
                    "Could not safely stage this playlist or confirm removal of its hosted link. It was not installed."
                },
                cleanupState = if (revoked) {
                    IPTVCleanupFailureState.NONE
                } else {
                    IPTVCleanupFailureState.UNCONFIRMED
                },
            )
        }

        val install = try {
            installAddon(registration.manifestUrl)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Result.failure(error)
        }
        if (install.isFailure) {
            val cleaned = IPTVCleanupCoordinator(store, cleanupActions).resume(registration.slug)
            return IPTVAddOutcome.Failed(
                message = install.exceptionOrNull()?.message ?: "Could not install this playlist.",
                cleanupState = if (cleaned) {
                    IPTVCleanupFailureState.NONE
                } else {
                    IPTVCleanupFailureState.JOURNALED
                },
            )
        }

        val saved = store.add(playlist, credentials)
        val committed = saved && store.markCleanupCommitted(registration.slug)
        if (!committed) {
            val cleaned = IPTVCleanupCoordinator(store, cleanupActions).resume(registration.slug)
            return IPTVAddOutcome.Failed(
                message = "Could not securely save this playlist. It was not added. Try again.",
                cleanupState = if (cleaned) {
                    IPTVCleanupFailureState.NONE
                } else {
                    IPTVCleanupFailureState.JOURNALED
                },
            )
        }

        return IPTVAddOutcome.Added(cleanupJournalPending = !store.finishCleanup(registration.slug))
    }
}

/**
 * Resumes the durable nonsecret cleanup journal one idempotent stage at a time. Each stage is recorded only
 * after its side effect succeeds. Cancellation or process exit therefore repeats at most one idempotent
 * uninstall/revoke operation and never loses the slug needed for a later retry.
 */
internal class IPTVCleanupCoordinator(
    private val store: IPTVPlaylistStore,
    private val actions: IPTVCleanupActions,
) {
    suspend fun resumeAll(): Boolean {
        var complete = true
        val cleanups = when (val state = store.pendingCleanupState()) {
            is IPTVPendingCleanupRead.Available -> state.cleanups
            IPTVPendingCleanupRead.Absent -> return true
            IPTVPendingCleanupRead.UnavailableOrCorrupt -> return false
        }
        for (cleanup in cleanups) {
            if (!resume(cleanup.slug)) complete = false
        }
        return complete
    }

    suspend fun resume(slug: String): Boolean {
        var cleanup = when (val state = current(slug)) {
            is CurrentCleanup.Found -> state.cleanup
            CurrentCleanup.Absent -> return true
            CurrentCleanup.Unavailable -> return false
        }
        if (cleanup.disposition == IPTVCleanupDisposition.COMMITTED) {
            return store.finishCleanup(slug)
        }

        if (!cleanup.localRemoved) {
            if (!store.remove(slug)) return false
            if (!store.markCleanupLocalRemoved(slug)) return false
            cleanup = (current(slug) as? CurrentCleanup.Found)?.cleanup ?: return false
        }

        if (!cleanup.addonRemoved) {
            val addons = try {
                actions.installedAddons().getOrElse { return false }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                return false
            }
            val installed = addons.firstOrNull { it.transportUrl == cleanup.transportUrl }
            if (installed != null) {
                val removed = try {
                    actions.removeAddon(installed)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    return false
                }
                if (removed.isFailure) return false
            }
            if (!store.markCleanupAddonRemoved(slug)) return false
            cleanup = (current(slug) as? CurrentCleanup.Found)?.cleanup ?: return false
        }

        if (!cleanup.workerRevoked) {
            if (!attemptRevoke(actions, slug)) return false
            if (!store.markCleanupWorkerRevoked(slug)) return false
        }

        return store.finishCleanup(slug)
    }

    private fun current(slug: String): CurrentCleanup =
        when (val state = store.pendingCleanupState()) {
            is IPTVPendingCleanupRead.Available ->
                state.cleanups.firstOrNull { it.slug == slug }
                    ?.let(CurrentCleanup::Found)
                    ?: CurrentCleanup.Absent
            IPTVPendingCleanupRead.Absent -> CurrentCleanup.Absent
            IPTVPendingCleanupRead.UnavailableOrCorrupt -> CurrentCleanup.Unavailable
        }

    private sealed interface CurrentCleanup {
        data class Found(val cleanup: IPTVPendingCleanup) : CurrentCleanup
        data object Absent : CurrentCleanup
        data object Unavailable : CurrentCleanup
    }
}

private suspend fun attemptRevoke(actions: IPTVCleanupActions, slug: String): Boolean =
    try {
        actions.revoke(slug)
    } catch (error: CancellationException) {
        throw error
    } catch (_: Exception) {
        false
    }
