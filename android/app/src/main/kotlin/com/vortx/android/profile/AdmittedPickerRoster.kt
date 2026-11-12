package com.vortx.android.profile

import com.vortx.android.sync.SessionOwnerSnapshot

/** The installed host roster belongs to this exact authenticated native mount. */
internal class AdmittedPickerRoster(
    val mount: Any,
    val account: SessionOwnerSnapshot.Account,
    val profiles: List<UserProfile>,
    val activeID: String,
    val selectionPending: Boolean,
    val launchConfirmed: Boolean,
) {
    val needsSelection: Boolean get() = selectionPending || (profiles.size > 1 && !launchConfirmed)
}

/** Launch-local only. A persisted active profile is not a completed chooser handoff. */
internal data class PickerLaunchSelection(val account: SessionOwnerSnapshot.Account, val profileID: String) {
    fun matches(current: SessionOwnerSnapshot.Account, activeID: String): Boolean =
        account == current && profileID == activeID
}

internal enum class ProfilePickerEntry { CONTENT, CHOOSE, UNAVAILABLE }

internal fun profilePickerEntry(
    nativeHost: Boolean,
    signedOut: Boolean,
    roster: AdmittedPickerRoster?,
): ProfilePickerEntry = when {
    !nativeHost || signedOut -> ProfilePickerEntry.CONTENT
    roster == null -> ProfilePickerEntry.UNAVAILABLE
    roster.needsSelection -> ProfilePickerEntry.CHOOSE
    else -> ProfilePickerEntry.CONTENT
}
