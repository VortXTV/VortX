package com.vortx.android.profile

/** A selection already admitted by the picker (including its PIN), bound to one exact roster. */
class ProfileSelectionRequest internal constructor(
    val profile: UserProfile,
    val outcome: ProfileStore.SwitchOutcome,
    expectedEmail: String?,
    internal val ownerRevision: Long,
    private val stillSelected: () -> Boolean,
    private val bind: (String?) -> Boolean = { false },
    private val completed: () -> Unit = {},
) {
    internal var expectedEmail: String? = expectedEmail
        private set
    internal fun requireCurrent() = check(stillSelected()) {
        "The profile changed. Choose it again before signing in."
    }
    internal fun bindPrincipal(email: String?): Boolean {
        requireCurrent()
        val changed = bind(email)
        if (changed) expectedEmail = email?.trim()?.lowercase()
        return changed
    }
    internal fun complete() { requireCurrent(); completed() }

    // Never include SwitchAccount's credential in diagnostics or Compose keys.
    override fun toString(): String = "ProfileSelectionRequest"
}

fun captureProfileSelection(
    store: ProfileStore,
    profile: UserProfile,
    outcome: ProfileStore.SwitchOutcome,
    nativeAdmission: (() -> Boolean)? = null,
): ProfileSelectionRequest = ContinueWatchingOwnerGate.serialized { revision ->
    var roster = store.profiles
    val selected = checkNotNull(store.active?.takeIf { it.id == profile.id }) { "Choose the profile again." }
    var generation = store.selectionRevision
    val account = if (selected.isOwner || !selected.usesOwnAccount) roster.firstOrNull { it.isOwner } else selected
    if (com.vortx.android.BuildConfig.NATIVE_ENGINE_ENABLED) checkNotNull(nativeAdmission) { "Choose the profile again." }
    store.pickedThisLaunch = false
    store.selectionPending = true
    ProfileSelectionRequest(selected, outcome, account?.email?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }, revision,
        stillSelected = { store.selectionRevision == generation && store.profiles === roster && store.activeID == selected.id && (nativeAdmission?.invoke() != false) },
        bind = { email ->
            if (account != null && account.email.isNullOrBlank()) {
                val principal = checkNotNull(email?.trim()?.takeIf { it.isNotEmpty() }) { "The account did not return an email. Try again." }
                store.update(account.copy(email = principal))
                roster = store.profiles
                generation = store.selectionRevision
                true
            } else false
        }, completed = { store.pickedThisLaunch = true; store.selectionPending = false })
}
