package com.vortx.android.account

import com.vortx.android.profile.ProfileStore

/**
 * The single source of truth for "may we sync the CURRENTLY ACTIVE profile to the signed-in account's
 * external services (Trakt / SIMKL) right now?"
 *
 * The rule is the per-profile watch-history invariant (mirrored from the Apple `activeUsesEngineHistory`
 * and `ScrobbleCoordinator.passesOwnerGate`): the MAIN profile is engine-backed and its watch state syncs
 * to the account, so it may scrobble and mirror library changes to the account's Trakt/SIMKL. Every
 * OVERLAY profile reads/writes only the local overlay ([ProfileStore]'s watch overlay) and must NEVER
 * scrobble as the account or mutate the account's remote watchlist. This gate is what keeps one shared
 * device's guest/kids profile from pushing plays into the owner's Trakt history.
 *
 * A single call site so the rule is spelled ONCE and every account-mutating path (live scrobble in
 * [com.vortx.android.integrations.ScrobbleService], library->watchlist mirroring in
 * [com.vortx.android.sync.AccountLibrarySync]) consults the same predicate.
 *
 * Defaults OPEN ([activeProfileSyncsAccount] returns true) only when [ProfileStore] is not yet initialized
 * (previews, or before the launcher stands the owner up): there is no overlay profile in that state, and
 * the downstream `isSignedIn` gate still blocks any real network call, so an open default can never leak an
 * overlay's play to the account.
 */
internal object AccountSyncGate {

    /**
     * True when the active profile is the engine-backed MAIN profile, so account-scoped external sync
     * (scrobble, watchlist mirror) is permitted. False for every overlay profile.
     */
    fun activeProfileSyncsAccount(): Boolean =
        ProfileStore.sharedOrNull()?.activeUsesEngineHistory ?: true
}
