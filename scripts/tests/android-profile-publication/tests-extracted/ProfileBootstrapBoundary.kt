package com.vortx.android.profile

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import com.vortx.android.sync.SessionOwnerSnapshot

internal enum class PlaylistScopeTransition { PROJECTION_REFRESH, AUTHORITY_BOUNDARY }

/** Immutable, already-admitted scalar witness for playlist receipt ownership decisions. */
internal data class PlaylistScopeEvidence(
    val selectedID: String?, val profileID: String?, val accountSlot: String, val usesEngineHistory: Boolean,
    val nativeAccountID: String?, val nativeAccountGeneration: Long?, val credentialEpoch: Long?,
)

internal fun playlistScopeTransition(
    before: PlaylistScopeEvidence, after: PlaylistScopeEvidence,
): PlaylistScopeTransition {
    val positivelyKnown = !before.selectedID.isNullOrBlank() && !before.profileID.isNullOrBlank() &&
        !before.accountSlot.isBlank() && !before.nativeAccountID.isNullOrBlank() && before.nativeAccountGeneration != null &&
        !after.selectedID.isNullOrBlank() && !after.profileID.isNullOrBlank() && !after.accountSlot.isBlank() &&
        !after.nativeAccountID.isNullOrBlank() && after.nativeAccountGeneration != null
    return if (positivelyKnown && before == after) PlaylistScopeTransition.PROJECTION_REFRESH
    else PlaylistScopeTransition.AUTHORITY_BOUNDARY
}


// Dispatchers are synthetic schedulers only; actual attach/reducer methods below are byte-identical.
internal object Dispatchers { lateinit var Main: CoroutineDispatcher; lateinit var IO: CoroutineDispatcher }
internal class FixturePrefs {
    val values = mutableMapOf<String,Any>()
    fun contains(key: String) = values.containsKey(key)
    fun getBoolean(key: String, fallback: Boolean) = values[key] as? Boolean ?: fallback
    fun edit() = Editor()
    inner class Editor {
        private val pending = mutableMapOf<String,Any>()
        fun putBoolean(key:String,value:Boolean) = apply { pending[key]=value }
        fun apply() { values.putAll(pending) }
    }
}
internal class ExtractedBootstrapStore {
    val prefs = FixturePrefs()
    var profiles: List<UserProfile> = emptyList()
    var activeID: String? = null
    var pickedThisLaunch = false
    val active get() = profiles.firstOrNull { it.id == activeID }
    val continueWatchingMigration = ContinueWatchingMigrationCheckpoint<SessionOwnerSnapshot.Account>()
    private var acknowledgedNativeAccount: SessionOwnerSnapshot.Account? = null
    private var acknowledgedNativeTraktEpoch: Long? = null
    private var nativeGateway: NativeProfileGateway? = null
    var applied = 0
    var onApply: () -> Unit = {}
    fun seed(value: NativeProfileGateway.Projection, account: SessionOwnerSnapshot.Account, epoch: Long) {
        profiles=value.profiles;activeID=value.activeID;acknowledgedNativeAccount=account;acknowledgedNativeTraktEpoch=epoch
    }
    private fun captureActiveProfileBinding() = activeID
    private fun notifyHomeTransitionListeners() {}
    private fun notifyPlaylistScopeListeners(transition: PlaylistScopeTransition) {}
    private fun publishActiveProfile() {}
    private fun notifySwitchListeners() {}
    private fun <T> withoutNativePreferenceCapture(action:()->T):T = action()
    private fun captureActiveProfileBinding(sourceProfiles: List<UserProfile>, selectedID: String?) =
        ActiveProfileBinding(selectedID, sourceProfiles.firstOrNull { it.id == selectedID }?.id,
            sourceProfiles.firstOrNull { it.id == selectedID }?.id ?: "primary",
            sourceProfiles.firstOrNull { it.id == selectedID }?.usesEngineHistory ?: true)
    private data class ActiveProfileBinding(val selectedID:String?,val profileID:String?,val accountSlot:String,val usesEngineHistory:Boolean)
    private fun playlistScopeEvidence(
        binding: ActiveProfileBinding,
        account: com.vortx.android.sync.SessionOwnerSnapshot.Account?,
        credentialEpoch: Long?,
    ): PlaylistScopeEvidence {
        return PlaylistScopeEvidence(binding.selectedID, binding.profileID, binding.accountSlot, binding.usesEngineHistory,
            account?.id, account?.generation, credentialEpoch)
    }
    private fun activateProfileState(profile:UserProfile,resetUnset:Boolean,playlistTransition: PlaylistScopeTransition = PlaylistScopeTransition.AUTHORITY_BOUNDARY) { applied++;onApply() }
    private val playlistScopeListeners = mutableListOf<(PlaylistScopeTransition) -> Unit>()
    private var nativeProjectionRequest = 0L
    private var nativeProjectionMount: Any? = null
    private var initialNativeMigrationProfile: UserProfile? = null
    private data class NativeProjectionBasis(
        val ownerRevision: Long,
        val profiles: List<UserProfile>, val activeID: String?,
        val previous: UserProfile?,
        val checkpoint: ContinueWatchingMigrationCheckpoint.State<com.vortx.android.sync.SessionOwnerSnapshot.Account>,
        val account: com.vortx.android.sync.SessionOwnerSnapshot.Account?, val traktEpoch: Long?,
        val flatSourcePresent: Boolean, val legacyEnabled: Boolean,
    )
    private data class NativeProjectionEffects(
        val account: com.vortx.android.sync.SessionOwnerSnapshot.Account?, val traktEpoch: Long?,
        val checkpoint: ContinueWatchingMigrationCheckpoint.State<com.vortx.android.sync.SessionOwnerSnapshot.Account>,
        val clearLegacy: Boolean,
        val providerRevision: Long,
        val legacyAcknowledgement: NativeLegacyAcknowledgement?,
    )
    private data class NativeLegacyAcknowledgement(
        val account: com.vortx.android.sync.SessionOwnerSnapshot.Account, val profileID: String,
        val traktEpoch: Long, val discovery: ProfileDiscoveryPreferences,
    )

    internal suspend fun attachNativeGateway(gateway: NativeProfileGateway, mountIdentity: Any, forceSettings: Boolean = false) {
        val request = withContext(Dispatchers.Main) {
            ContinueWatchingOwnerGate.serialized {
                if (nativeProjectionMount !== mountIdentity) {
                    val initial = nativeProjectionMount == null
                    if (initial) initialNativeMigrationProfile = active ?: initialNativeMigrationProfile
                    clearNativeProjection(retireLegacy = !initial, retireMigration = !initial)
                }
                nativeGateway = gateway
                nativeProjectionMount = mountIdentity
                ++nativeProjectionRequest
            }
        }
        var legacyAcknowledgement: NativeLegacyAcknowledgement? = null
        var attempt = 0
        while (true) {
            currentCoroutineContext().ensureActive()
            val basis = withContext(Dispatchers.Main) {
                ContinueWatchingOwnerGate.serialized { revision ->
                    if (nativeProjectionRequest != request) null else NativeProjectionBasis(
                        revision, profiles, activeID, active ?: initialNativeMigrationProfile, continueWatchingMigration.snapshot(),
                        acknowledgedNativeAccount, acknowledgedNativeTraktEpoch,
                        prefs.contains(com.vortx.android.home.CONTINUE_WATCHING_SOURCE_KEY),
                        prefs.getBoolean(com.vortx.android.integrations.ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING, false))
                }
            } ?: return
            var effects: NativeProjectionEffects? = null
            val prepared = withContext(Dispatchers.IO) {
                val operation = currentCoroutineContext()
                gateway.prepareProjection(mountIdentity) { value ->
                    operation.ensureActive()
                    effects = prepareNativeProjection(gateway, value, basis, legacyAcknowledgement)
                }
            }
            effects?.legacyAcknowledgement?.let { legacyAcknowledgement = it }
            var recoveryRequired = false
            val published = withContext(Dispatchers.Main) {
                ContinueWatchingOwnerGate.serialized { revision ->
                    if (nativeProjectionRequest != request) return@serialized true
                    // A host switch/edit during capture must obtain its own worker snapshot. No native
                    // read, secure credential capture or migration write is allowed below this line.
                    if (revision != basis.ownerRevision || profiles != basis.profiles || activeID != basis.activeID ||
                        continueWatchingMigration.snapshot() != basis.checkpoint ||
                        prefs.contains(com.vortx.android.home.CONTINUE_WATCHING_SOURCE_KEY) != basis.flatSourcePresent ||
                        prefs.getBoolean(com.vortx.android.integrations.ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING, false) != basis.legacyEnabled)
                        return@serialized false
                    var installed = false
                    prepared.publishIfCurrent {
                        val currentEffects = checkNotNull(effects)
                        if (com.vortx.android.integrations.NativeProviderAccess.revision.value == currentEffects.providerRevision) {
                            if (prepared.requiresRecovery) {
                                // Keep the exact qualified witness/pending edit even when the native
                                // save made its checkpoint uncertain. Do not publish a success roster.
                                continueWatchingMigration.restore(currentEffects.checkpoint)
                                recoveryRequired = true
                            } else applyPreparedNativeProjection(prepared.projection, currentEffects, forceSettings)
                            installed = true
                        }
                    } && installed
                }
            }
            check(!recoveryRequired) { "Native profile checkpoint requires recovery" }
            if (published) return
            // Native updates may keep arriving. Bound full-state recaptures, retain durable data and
            // qualified witness, and let the existing startup/sync error surface offer a fresh retry.
            check(++attempt < 4) { "Native profile changed while loading. Retry this account." }
            delay(50L * attempt)
        }
    }
    internal suspend fun refreshNativeProjectionInBackground(forceSettings: Boolean = false) {
        val (gateway, mount) = withContext(Dispatchers.Main) {
            checkNotNull(nativeGateway) to checkNotNull(nativeProjectionMount)
        }
        attachNativeGateway(gateway, mount, forceSettings)
    }
    private fun prepareNativeProjection(gateway: NativeProfileGateway, value: NativeProfileGateway.Projection, basis: NativeProjectionBasis,
        previousAcknowledgement: NativeLegacyAcknowledgement?): NativeProjectionEffects {
        val checkpoint = ContinueWatchingMigrationCheckpoint<com.vortx.android.sync.SessionOwnerSnapshot.Account>().also { it.restore(basis.checkpoint) }
        val previous = basis.previous
        val incoming = value.profiles.firstOrNull { it.id == value.activeID }
        val providerRevision = com.vortx.android.integrations.NativeProviderAccess.revision.value
        val captured = com.vortx.android.integrations.NativeProviderAccess.capture(
            com.vortx.android.integrations.NativeProviderCredentials.GROUPS[0]) { value }
        val guard = checkNotNull(captured?.first?.takeIf { captured.second == value }) {
            "Native provider authority is unavailable. Retry this account."
        }
        val epoch = com.vortx.android.integrations.TraktAuth.currentSessionEpoch
        var acknowledgement = previousAcknowledgement?.takeIf {
            it.account == guard.owner && it.traktEpoch == epoch && it.profileID == value.activeID && incoming?.discovery == it.discovery
        }
        var clearLegacy = previous != null && (previous.id != value.activeID || basis.account != guard.owner)
        if (clearLegacy) checkpoint.retire()
        if (checkpoint.witness == null && eligibleLegacyContinueWatchingMigration(previous, incoming, value.activeID,
                basis.flatSourcePresent, basis.legacyEnabled && !clearLegacy,
                sameContinueWatchingMigrationAuthority(basis.account, guard.owner, basis.traktEpoch, epoch))) {
            checkpoint.capture(value.activeID, guard.owner, checkNotNull(epoch))
        }
        checkpoint.attempt(incoming, value.activeID, guard.owner, epoch,
            save = { edited -> com.vortx.android.integrations.NativeProviderAccess.guarded(guard) {
                if (gateway.read() == value) gateway.save(edited, adding = false) else null
            } },
            authorityIsCurrent = { com.vortx.android.integrations.NativeProviderAccess.current(guard) &&
                com.vortx.android.integrations.TraktAuth.currentSessionEpoch == epoch },
            readbackIsCurrent = { saved -> gateway.read() == saved },
        )?.let { saved ->
            acknowledgement = NativeLegacyAcknowledgement(guard.owner, saved.activeID, checkNotNull(epoch),
                checkNotNull(saved.profiles.first { it.id == saved.activeID }.discovery))
        }
        clearLegacy = clearLegacy || acknowledgement != null
        return NativeProjectionEffects(guard.owner, epoch, checkpoint.snapshot(), clearLegacy, providerRevision, acknowledgement)
    }
    private fun applyPreparedNativeProjection(value: NativeProfileGateway.Projection, effects: NativeProjectionEffects, forceSettings: Boolean) {
        val beforeBinding = captureActiveProfileBinding(profiles, activeID)
        val transition = playlistScopeTransition(
            playlistScopeEvidence(beforeBinding, acknowledgedNativeAccount, acknowledgedNativeTraktEpoch),
            playlistScopeEvidence(captureActiveProfileBinding(value.profiles, value.activeID), effects.account, effects.traktEpoch),
        )
        continueWatchingMigration.restore(effects.checkpoint)
        withoutNativePreferenceCapture {
            if (effects.clearLegacy) prefs.edit().putBoolean(com.vortx.android.integrations.ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING, false).apply()
            if (forceSettings || profiles != value.profiles || activeID != value.activeID ||
                transition == PlaylistScopeTransition.AUTHORITY_BOUNDARY) {
                ContinueWatchingOwnerGate.transition(::captureActiveProfileBinding) {
                    profiles = value.profiles; activeID = value.activeID
                    active?.let { activateProfileState(it, resetUnset = true, playlistTransition = transition) }
                        ?: run { notifyHomeTransitionListeners(); notifyPlaylistScopeListeners(transition) }
                }
            }
        }
        acknowledgedNativeAccount = effects.account; acknowledgedNativeTraktEpoch = effects.traktEpoch
        initialNativeMigrationProfile = null
    }
    internal fun clearNativeProjection(retireLegacy: Boolean = true, retireMigration: Boolean = true) = ContinueWatchingOwnerGate.serialized {
        nativeProjectionRequest++
        nativeProjectionMount = null
        ContinueWatchingOwnerGate.transition(::captureActiveProfileBinding) {
            if (retireMigration) {
                continueWatchingMigration.retire()
                acknowledgedNativeAccount = null; acknowledgedNativeTraktEpoch = null
                initialNativeMigrationProfile = null
            }
            if (retireLegacy) prefs.edit().putBoolean(com.vortx.android.integrations.ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING, false).apply()
            profiles = emptyList(); activeID = null; pickedThisLaunch = false
            notifyHomeTransitionListeners(); notifyPlaylistScopeListeners(PlaylistScopeTransition.AUTHORITY_BOUNDARY)
            publishActiveProfile(); notifySwitchListeners()
        }
    }
}
