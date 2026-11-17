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
    private val diagnosticAdmission: () -> Boolean = { false },
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
    // Sharing a scrubbed recovery log must not require a healthy native runtime.
    internal fun allowsDiagnosticExport(): Boolean = diagnosticAdmission()

    // Never include SwitchAccount's credential in diagnostics or Compose keys.
    override fun toString(): String = "ProfileSelectionRequest"
}

fun captureProfileSelection(
    store: ProfileStore,
    profile: UserProfile,
    outcome: ProfileStore.SwitchOutcome,
    nativeAdmission: ((() -> Unit) -> Boolean)? = null,
): ProfileSelectionRequest = ContinueWatchingOwnerGate.serialized { revision ->
    var roster = store.profiles
    val selected = checkNotNull(store.active?.takeIf { it.id == profile.id }) { "Choose the profile again." }
    var generation = store.selectionRevision
    val account = if (selected.isOwner || !selected.usesOwnAccount) roster.firstOrNull { it.isOwner } else selected
    val admit = checkNotNull(nativeAdmission) { "Choose the profile again." }
    fun stillSelected() = store.selectionRevision == generation && store.profiles === roster && store.activeID == selected.id
    ProfileSelectionRequest(selected, outcome, account?.email?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }, revision,
        stillSelected = { stillSelected() && admit {} },
        bind = { email ->
            if (account != null && account.email.isNullOrBlank()) {
                val principal = checkNotNull(email?.trim()?.takeIf { it.isNotEmpty() }) { "The account did not return an email. Try again." }
                store.update(account.copy(email = principal))
                roster = store.profiles
                generation = store.selectionRevision
                true
            } else false
        }, completed = {
            ContinueWatchingOwnerGate.serialized {
                check(stillSelected() && admit(store::completePickerSelection)) { "Choose the profile again." }
            }
        },
        diagnosticAdmission = { ContinueWatchingOwnerGate.serialized { currentRevision ->
            currentRevision == revision && store.selectionRevision == generation &&
                store.profiles === roster && store.activeID == selected.id
        } })
}
