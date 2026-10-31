package com.vortx.android.profile
data class ProfileDiscoveryPreferences(
    val hiddenCatalogs: List<String>? = null,
    val catalogOrder: List<String>? = null,
    val hiddenHubCategories: List<String>? = null,
    val regionOverrideCaptured: Boolean? = null,
    val regionOverride: String? = null,
    val filtersCaptured: Boolean? = null,
    /** Base64 of the existing UTF-8 Discover-filter JSON, matching Swift Data JSON encoding. */
    val filtersData: String? = null,
    val selectedProviders: List<Int>? = null,
    val providerOrder: List<Int>? = null,
    val tabVisibilityCaptured: Boolean? = null,
    val hideLiveTab: Boolean? = null,
    val hideDiscoverTab: Boolean? = null,
    val hideLibraryTab: Boolean? = null,
    val hideSearchTab: Boolean? = null,
    val showCollectionsHome: Boolean? = null,
    val showCollectionsDiscover: Boolean? = null,
    val continueWatchingSource: String? = null,
    val continueWatchingWindow: String? = null,
)

/** Migration requires both exact acknowledged records and a passive, connected account witness. */
internal fun eligibleLegacyContinueWatchingMigration(
    previous: UserProfile?, incoming: UserProfile?, acknowledgedProfileID: String,
    flatSourcePresent: Boolean, legacyEnabled: Boolean, accountAndSessionKnown: Boolean,
): Boolean = previous != null && incoming != null && previous.id == acknowledgedProfileID && incoming.id == acknowledgedProfileID &&
    previous.usesEngineHistory && incoming.usesEngineHistory && previous.discovery?.continueWatchingSource == null &&
    incoming.discovery?.continueWatchingSource == null && !flatSourcePresent && legacyEnabled && accountAndSessionKnown

internal fun <T> sameContinueWatchingMigrationAuthority(previousAccount: T?, currentAccount: T?, previousSession: Long?, currentSession: Long?): Boolean =
    previousAccount != null && previousAccount == currentAccount && previousSession != null && previousSession == currentSession

/** A failed checkpoint retains only this exact qualified capture; it cannot adopt another owner on retry. */
internal class ContinueWatchingMigrationCheckpoint<T> {
    data class Witness<T>(val profileID: String, val account: T, val traktEpoch: Long)
    data class State<T>(val witness: Witness<T>?, val pendingDiscovery: ProfileDiscoveryPreferences?)
    var witness: Witness<T>? = null
        private set
    private var pendingDiscovery: ProfileDiscoveryPreferences? = null
    fun snapshot(): State<T> = State(witness, pendingDiscovery)
    fun restore(state: State<T>) { witness = state.witness; pendingDiscovery = state.pendingDiscovery }
    fun capture(profileID: String, account: T, epoch: Long) { pendingDiscovery = null; witness = Witness(profileID, account, epoch) }
    fun retire() { witness = null; pendingDiscovery = null }
    /** Retained only with this witness, so a later fresh projection cannot erase a failed local edit. */
    fun retainDiscoveryCapture(profile: UserProfile, flat: ProfileDiscoveryPreferences) {
        if (witness?.profileID == profile.id)
            pendingDiscovery = pendingContinueWatchingDiscoveryCapture(profile, flat).discovery
    }
    fun attempt(incoming: UserProfile?, profileID: String, account: T?, epoch: Long?,
        save: (UserProfile) -> NativeProfileGateway.Projection?, authorityIsCurrent: () -> Boolean,
        readbackIsCurrent: (NativeProfileGateway.Projection) -> Boolean = { true }): NativeProfileGateway.Projection? {
        val captured = witness ?: return null
        if (incoming == null || profileID != captured.profileID || incoming.id != captured.profileID ||
            account != captured.account || epoch != captured.traktEpoch || incoming.discovery?.continueWatchingSource != null) {
            retire(); return null
        }
        val discovery = pendingDiscovery ?: incoming.discovery ?: ProfileDiscoveryPreferences()
        val edited = incoming.copy(discovery = discovery.copy(
            continueWatchingSource = "trakt", continueWatchingWindow = discovery.continueWatchingWindow ?: "20"))
        val saved = try { if (authorityIsCurrent()) save(edited) else null }
        catch (failure: Exception) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            null // A failed durable checkpoint retains the exact witness and pending discovery.
        }
        if (!authorityIsCurrent()) { retire(); return null }
        if (saved?.activeID != captured.profileID || saved.profiles.firstOrNull { it.id == captured.profileID }?.discovery != edited.discovery || !readbackIsCurrent(saved)) return null
        if (!authorityIsCurrent()) { retire(); return null }
        retire(); return saved
    }
}

internal fun pendingContinueWatchingDiscoveryCapture(profile: UserProfile, flat: ProfileDiscoveryPreferences): UserProfile =
    profile.copy(discovery = flat.copy(continueWatchingSource = null, continueWatchingWindow = profile.discovery?.continueWatchingWindow))
