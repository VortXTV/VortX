package com.vortx.android.profile

/** Account-owned roster, history/cache, and active profile projection keys cannot travel via local files. */
internal fun isProfileBearingSettingsKey(key: String): Boolean =
    key == "stremiox.profiles" || key.startsWith("stremiox.profiles.") || key.startsWith("stremiox.profile.")

/** Filter only the export snapshot, never the live preferences or original backup. */
internal fun <T> localSettingsBackupInput(nativeEngineEnabled: Boolean, preferences: Map<String, T>): Map<String, T> =
    if (nativeEngineEnabled) preferences.filterKeys { !isProfileBearingSettingsKey(it) } else preferences

/** File backups are not authenticated native account imports. Refuse the entire profile-bearing file. */
internal fun <T> withLocalSettingsRestoreAdmission(
    nativeEngineEnabled: Boolean,
    keys: Set<String>,
    restore: () -> T,
): T {
    // ProfileStore's roster/selection/clock/deletes, WatchOverlayStore/LastStreamStore's profile
    // cache keys, and the active profile's disabled-addons/Kids projections all belong to the account.
    require(!nativeEngineEnabled || keys.none(::isProfileBearingSettingsKey)) {
        "This backup contains profiles or watch history. Sign in to your VortX account and restore your account data instead. No settings have been changed."
    }
    return restore()
}

/** Returning true means native authority handled reload; failure must not permit a legacy fallback. */
internal fun refreshNativeProfilesForReload(nativeEngineEnabled: Boolean, refreshNative: () -> Unit): Boolean {
    if (!nativeEngineEnabled) return false
    refreshNative()
    return true
}
