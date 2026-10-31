package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.diagnostics.DiagnosticsLog
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.NativeAccountGateway
import com.vortx.android.sync.NativeAccountReadCapture
import com.vortx.android.sync.NativeAccountExport
import com.vortx.android.sync.NativeAccountMountToken
import com.vortx.android.sync.NativeAccountUploadCurrency
import com.vortx.android.sync.NativePlaylistProfileGateway
import com.vortx.android.sync.NativeXperienceProfileGateway
import com.vortx.android.sync.NativeHostUploadAcknowledgment
import com.vortx.android.xperience.XperienceImportNamespace
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.sync.LocalLibraryMutationAuthority
import com.vortx.android.sync.VortXSyncDoc
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.ConcurrentLinkedQueue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.json.JSONArray

/** Owns the process writer. It never infers account ownership from the global ProfileStore. */
internal class NativeAccountCoordinator(
    private val bindings: VortxRuntimeBindings,
    private val checkpoints: VortxCheckpointStore,
    private val transport: () -> VortxResourceTransport,
    private val accountCurrent: (SessionOwnerSnapshot.Account) -> Boolean,
    private val dispose: (() -> Unit) -> Unit,
    private val project: suspend (VortxNativeSession) -> Unit,
    private val onMutation: (SessionOwnerSnapshot.Account) -> Unit = {},
    private val onRetired: () -> Unit = {},
    private val ownCredentials: NativeOwnAccountCredentials? = null,
    private val ownProducer: NativeOwnAccountProducer = NativeOwnAccountProducer(),
    private val watchedProducer: NativeWatchedMigrationProducer = NativeWatchedMigrationProducer(),
    private val captureOwnAccountAdmission: (SessionOwnerSnapshot.Account) -> (((() -> Boolean) -> Boolean)?) = { null },
    private val onAuthorityChanged: () -> Unit = {},
    /** A committed playback-progress report; defaults to the ordinary mutation callback. */
    private val onProgressMutation: (SessionOwnerSnapshot.Account) -> Unit = onMutation,
    private val historyBindings: NativeOwnerHistoryBindings = NativeOwnerHistoryJniBindings,
    /** Read-only metadata admission, captured on IO. Never reused for a native mutation. */
    private val captureProfilePresentationAdmission: (SessionOwnerSnapshot.Account) -> (((() -> Boolean) -> Boolean)?) = captureOwnAccountAdmission,
    /** For You command identity includes auth/session/operation scope, independent of read stamps. */
    private val captureForYouAccountAuthority: (SessionOwnerSnapshot.Account) -> LocalLibraryMutationAuthority? = { null },
) : NativeAccountGateway, NativePlaylistProfileGateway, NativeXperienceProfileGateway {
    private data class Mounted(val account: SessionOwnerSnapshot.Account, val session: VortxNativeSession) {
        private var retired = false
        private var authenticatedRead: NativeAccountReadCapture? = null
        private var sourceNativeProjection: ByteArray? = null

        @Synchronized fun retain(read: NativeAccountReadCapture, projection: ByteArray): Boolean {
            if (retired || read.account != account) return false
            val old = authenticatedRead
            authenticatedRead = read
            sourceNativeProjection?.fill(0)
            sourceNativeProjection = projection.copyOf()
            if (old !== read) old?.retire()
            return true
        }

        @Synchronized fun clearRead(expected: NativeAccountReadCapture? = null) {
            if (expected == null || authenticatedRead === expected) {
                authenticatedRead?.retire()
                authenticatedRead = null
                sourceNativeProjection?.fill(0); sourceNativeProjection = null
            }
        }

        @Synchronized fun retireRead() {
            retired = true
            authenticatedRead?.retire()
            authenticatedRead = null
            sourceNativeProjection?.fill(0); sourceNativeProjection = null
        }
        @Synchronized fun readIdentity(): NativeAccountReadCapture? = authenticatedRead.takeUnless { retired }
        @Synchronized fun sourceProjection(): ByteArray? = sourceNativeProjection?.copyOf().takeUnless { retired }
        @Synchronized fun <T> withRead(expected: NativeAccountReadCapture, action: (ByteArray, ByteArray) -> T): T {
            check(!retired && authenticatedRead === expected) { "Authenticated raw observation changed" }
            val raw = expected.copyRawForApply(account)
            val projection = checkNotNull(sourceNativeProjection).copyOf()
            return try { action(raw, projection) } finally { raw.fill(0); projection.fill(0) }
        }
    }
    @Volatile private var playlistAccountProducer: com.vortx.android.sync.NativePlaylistAccountProducer? = null
    override fun installPlaylistAccountProducer(producer: com.vortx.android.sync.NativePlaylistAccountProducer) {
        playlistAccountProducer = producer
    }
    private val mounted = AtomicReference<Mounted?>()
    private val retired = ConcurrentLinkedQueue<VortxNativeSession>()
    private val lifecycleLock = Any()
    private val mutex = Mutex()
    /** Native cleanup uncertainty survives retire/sign-out in this process; never open a rival. */
    private val uncertainHistoryAccounts = mutableSetOf<String>()
    private data class PendingImport(val id: UUID, val account: SessionOwnerSnapshot.Account, val document: JSONObject,
                                     val profiles: List<UserProfile>, val isCurrent: () -> Boolean,
                                     val sources: List<NativeOwnAccountSource>, val preflight: NativeMigrationPreflight)
    @Volatile private var pendingImport: PendingImport? = null
    internal data class StreamingProfile(val profile: UserProfile, val pendingImport: Boolean, val pendingOverlay: Boolean)
    internal class StreamingTarget internal constructor(internal val account: SessionOwnerSnapshot.Account,
        val profile: UserProfile, internal val session: VortxNativeSession?, internal val owner: VortxNativeOwner?, internal val pendingID: UUID?)
    internal class OwnerAuthTarget internal constructor(internal val account: SessionOwnerSnapshot.Account,
        internal val session: VortxNativeSession, internal val owner: VortxNativeOwner,
        internal val selection: NativeOwnAccountCredentials.OwnerSelection, val hasCredential: Boolean) {
        val canManage get() = owner.profileID == owner.scope.ownerProfileID
        val verifiedUID get() = selection.verifiedUID.takeIf { hasCredential }
        fun matches(other: OwnerAuthTarget) = account == other.account && session === other.session && owner == other.owner &&
            selection.raw == other.selection.raw && hasCredential == other.hasCredential
    }
    /** Revocation never calls Session/auth/lifecycle while holding this scalar monitor. */
    private class PlaylistLifetime {
        private val lock = Any()
        private var active = true
        fun admit(action: () -> Boolean): Boolean = synchronized(lock) { active && action() }
        fun revoke() = synchronized(lock) { active = false }
    }
    private class CapturedPlaylistTarget(
        val account: SessionOwnerSnapshot.Account,
        val session: VortxNativeSession,
        val owner: VortxNativeOwner,
        val installation: Mounted,
        val admission: (() -> Boolean) -> Boolean,
        val lifetime: PlaylistLifetime,
        override val receiptOwner: CapturedReceiptOwner,
        val originalRead: NativeAccountReadCapture?,
        val producer: com.vortx.android.sync.NativePlaylistAccountProducer?,
    ) : NativePlaylistProfileGateway.Target {
        override val accountId get() = account.id
        override val profileId get() = owner.profileID
    }
    private class CapturedReceiptOwner(
        val account: SessionOwnerSnapshot.Account,
        val session: VortxNativeSession,
        val owner: VortxNativeOwner,
        val installation: Mounted,
        val admission: (() -> Boolean) -> Boolean,
        val profileEpoch: Long,
        val lifetime: PlaylistLifetime = PlaylistLifetime(),
    ) : NativePlaylistProfileGateway.ReceiptOwner
    private class CapturedPlaylistSnapshot(
        override val target: CapturedPlaylistTarget,
        rawRegisters: JSONObject,
        override val receipt: NativePlaylistCloudReceiptLedger.Ticket? = null,
    ) : NativePlaylistProfileGateway.Snapshot {
        private val acceptedRegisters = JSONObject(rawRegisters.toString())
        override val registers get() = JSONObject(acceptedRegisters.toString())
        fun matches(fields: JSONObject) = NativeHostPreferences.equal(acceptedRegisters, fields)
    }
    private data class DetachedPlaylistEdit(val field: String, val expectedRegister: JSONObject?, val value: Any)
    private class CapturedXperienceTarget(
        val account: SessionOwnerSnapshot.Account,
        val session: VortxNativeSession,
        val owner: VortxNativeOwner,
        val installation: Mounted,
        val admission: (() -> Boolean) -> Boolean,
        val lifetime: PlaylistLifetime,
        val originalRead: NativeAccountReadCapture?,
        val producer: com.vortx.android.sync.NativePlaylistAccountProducer,
        val context: String,
    ) : NativeXperienceProfileGateway.Target {
        override val accountId get() = account.id
        override val profileId get() = owner.profileID
    }
    private class CapturedXperienceSnapshot(
        override val target: CapturedXperienceTarget,
        fields: Map<String, ByteArray>,
    ) : NativeXperienceProfileGateway.Snapshot {
        private val raw = fields.mapValues { it.value.copyOf() }
        override fun registers() = raw.mapValues { it.value.copyOf() }
        fun matches(fields: Map<String, ByteArray>) = raw.keys == fields.keys &&
            raw.all { (key, value) -> value.contentEquals(fields.getValue(key)) }
    }
    private val playlistReceipts = NativePlaylistCloudReceiptLedger()
    override val playlistReceiptChanges = MutableStateFlow(0L)

    val changes = MutableStateFlow(0L)
    private val playlistMountRevisions = MutableStateFlow(0L)
    override val playlistChanges = channelFlow {
        playlistMountRevisions.collectLatest {
            val current = mounted.get()
            if (current == null || !accountCurrent(current.account)) send(Unit)
            else current.session.playlistUpdates.collect {
                if (mounted.get() === current && accountCurrent(current.account)) send(Unit)
            }
        }
    }

    internal data class MigrationStatus(val pendingRows: Int, val setupRequired: Boolean, val watchlistPending: Int = 0)
    internal class MigrationTarget internal constructor(internal val account: SessionOwnerSnapshot.Account,
        internal val scope: VortxAccountScope, internal val document: JSONObject, internal val session: VortxNativeSession?,
        internal val owner: VortxNativeOwner?, internal val update: Long?, internal val pendingID: UUID?)
    fun migrationStatus(): MigrationStatus? {
        mounted.get()?.takeIf { accountCurrent(it.account) }?.let { current ->
            val document = current.session.read().state.optJSONObject("hostDocument")
            val count = NativeWatchedMigrationStorage.unresolvedCountForStatus(document)
            val candidates = document?.optJSONObject("nativeOwnAccountCandidates")?.length() ?: 0
            val watchlists = document?.optJSONArray("nativeWatchlistMigrationPending")?.length() ?: 0
            return MigrationStatus(count, false, watchlists).takeIf { count > 0 || candidates > 0 || watchlists > 0 }
        }
        val pending = pendingImport?.takeIf { it.isCurrent() && accountCurrent(it.account) } ?: return null
        return MigrationStatus(NativeWatchedMigrationStorage.unresolvedCountForStatus(pending.document), true,
            pending.document.optJSONArray("nativeWatchlistMigrationPending")?.length() ?: 0)
    }
    fun captureMigrationTarget(): MigrationTarget {
        mounted.get()?.let { current ->
            val read = current.session.read()
            return current.session.owned(read.owner) {
                check(accountCurrent(current.account) && mounted.get() === current)
                MigrationTarget(current.account, read.owner.scope, read.state.getJSONObject("hostDocument"), current.session,
                    read.owner, current.session.updates.value, null)
            }
        }
        val pending = checkNotNull(pendingImport) { "No authenticated migration is pending" }
        check(pending.isCurrent() && accountCurrent(pending.account))
        return MigrationTarget(pending.account, pending.preflight.scope,
            NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(pending.document)), null, null, null, pending.id)
    }
    private fun migrationTargetCurrent(target: MigrationTarget): Boolean = accountCurrent(target.account) &&
        if (target.session != null) mounted.get()?.let { it.account == target.account && it.session === target.session } == true &&
            target.session.updates.value == target.update
        else pendingImport?.let { it.id == target.pendingID && it.account == target.account && it.isCurrent() } == true

    suspend fun retryMigration(target: MigrationTarget): Boolean = mutex.withLock {
        val operationJob = currentCoroutineContext()[Job]
        val current = { operationJob?.isActive != false && migrationTargetCurrent(target) }
        check(current()) { "Migration target changed" }
        val history = watchedProducer.retryPending(target.scope, NativeWatchedMigrationStorage.read(target.document), current)
        val retained = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(target.document))
        history.storage().writeTo(retained)
        check(current()) { "Migration target changed" }
        // Retrying A never grants authority to import A into a changed B. Current B gets its own
        // capture/batch; historical A evidence is only retained for exact source-bound replay.
        val sources = pendingImport?.takeIf { it.id == target.pendingID }?.sources.orEmpty()
        val applied = applyDocumentLocked(target.account, target.document, { accountCurrent(target.account) }, sources, retained,
            operationCurrent = current)
        val session = target.session
        if (applied && session != null) {
            // Rebind only the active, previously unlocked profile and the exact pending binding.
            // Any reconciliation that changed its owner epoch requires a new user gesture.
            session.owned(requireNotNull(target.owner)) {
                check(mounted.get()?.session === session)
            }
            val pendingLink = session.read().state.optJSONObject("hostDocument")?.optJSONObject("nativeOwnAccountCandidates")?.has(target.owner.profileID) == true
            if (pendingLink) {
                NativeStreamingAccountLink(checkNotNull(ownCredentials), ownProducer, watchedProducer).retry(session, target.account, target.owner,
                    checkNotNull(captureOwnAccountAdmission(target.account))) { action -> withMountedSession(session, target.account, action) }
                project(session)
            }
        }
        changes.value += 1
        applied && migrationStatus() == null
    }

    /** Optional owner credentials are not VortX login state and never relabel the native owner. */
    fun ownerAuthTarget(): OwnerAuthTarget {
        val current = checkNotNull(mounted.get()) { "Open the authenticated native account first" }
        val read = current.session.read()
        val credentials = checkNotNull(ownCredentials)
        val admission = checkNotNull(captureOwnAccountAdmission(current.account))
        return current.session.owned(read.owner) {
            val selection = credentials.ownerSelection(current.account, read.owner.scope.ownerProfileID, admission)
            val capture = credentials.captureOwner(current.account, selection, admission)
            check(withMountedSession(current.session, current.account) { true }) { "Native account changed" }
            OwnerAuthTarget(current.account, current.session, read.owner, selection, capture != null)
        }
    }
    fun <T> withOwnerAuthTarget(target: OwnerAuthTarget, action: () -> T): T = target.session.owned(target.owner) {
        check(ownerAuthTarget().matches(target)) { "Owner streaming account changed" }
        var result: Result<T>? = null
        check(withProfileMutation(target.session, target.account) { result = runCatching(action); true }) { "Native account changed" }
        requireNotNull(result).getOrThrow()
    }
    suspend fun signInOwner(target: OwnerAuthTarget, email: String, password: String) {
        val operationJob = currentCoroutineContext()[Job]
        require(target.canManage) { "Open Main and unlock its PIN to manage this account" }
        val credentials = checkNotNull(ownCredentials)
        val admission = checkNotNull(captureOwnAccountAdmission(target.account))
        target.session.owned(target.owner) {
            check(withMountedSession(target.session, target.account) { true }) { "Native account changed" }
        }
        val candidate = ownProducer.signIn(credentials, target.account, target.owner.scope.ownerProfileID,
            email, password, admission, "owner:${UUID.randomUUID()}")
        try {
            target.session.owned(target.owner) {
                credentials.selectOwner(target.account, target.selection, candidate) { action ->
                    withMountedSession(target.session, target.account) { operationJob?.ensureActive(); action() }
                }
            }
        } finally { changes.value += 1 }
    }
    fun signOutOwner(target: OwnerAuthTarget) {
        require(target.canManage) { "Open Main and unlock its PIN to manage this account" }
        val admission = checkNotNull(captureOwnAccountAdmission(target.account))
        try {
            target.session.owned(target.owner) {
                checkNotNull(ownCredentials).clearOwner(target.account, target.selection, admission) { action ->
                    withMountedSession(target.session, target.account, action)
                }
            }
        } finally { changes.value += 1 }
    }
    fun streamingProfiles(): List<StreamingProfile> {
        val current = mounted.get()
        if (current != null && accountCurrent(current.account)) {
            val read = current.session.read()
            val pending = read.state.optJSONObject("hostDocument")?.optJSONObject("nativeOwnAccountPending")
            return NativeProfileAccess.projection(read).profiles.filter { it.usesOwnAccount && !it.isOwner }.map {
                StreamingProfile(it, false, pending?.has(it.id) == true)
            }
        }
        val pending = pendingImport?.takeIf { it.isCurrent() && accountCurrent(it.account) } ?: return emptyList()
        val verified = pending.sources.filter { runCatching { it.withActive {} }.isSuccess }.map { it.profileID }.toSet()
        return pending.profiles.filter { it.usesOwnAccount && !it.isOwner }.map { StreamingProfile(it, it.id !in verified, true) }
    }
    /** Opaque identity only, with no native read or credential/session monitor. */
    internal fun streamingPresentationIdentity(): Any? = mounted.get() ?: pendingImport

    /** Read-only picker metadata. This is never a selection, credential or mutation capability. */
    internal class StreamingPresentation internal constructor(
        val projection: com.vortx.android.profile.NativeProfileGateway.Projection?,
        val streaming: List<StreamingProfile>,
        val migration: MigrationStatus?,
        private val admission: (() -> Unit) -> Boolean,
    ) {
        fun publishIfCurrent(action: () -> Unit): Boolean = admission(action)
    }

    /** Captured while Session is held by the worker, admitted later without reacquiring it.
     * The exact Mounted object, authenticated generation and both monotone stamps reject ABA. */
    internal fun captureProfilePresentation(session: VortxNativeSession): com.vortx.android.profile.NativeProfileGateway.PreparedProjection =
        synchronized(session) {
            // Read-only failure handoff also retains a qualified migration witness after checkpoint
            // uncertainty. It never grants a command capability or reports recovery as success.
            val read = session.read()
            val current = checkNotNull(mounted.get()) { "Native account changed" }
            check(current.session === session && accountCurrent(current.account)) { "Native account changed" }
            val epoch = changes.value
            val version = session.updates.value
            val recovery = session.requiresRecovery()
            val authenticated = captureProfilePresentationAdmission(current.account)
            check(authenticated != null || ownCredentials == null) { "Native profile authentication unavailable" }
            com.vortx.android.profile.NativeProfileGateway.PreparedProjection(NativeProfileAccess.projection(read), recovery) { action ->
                val publish = {
                    synchronized(lifecycleLock) {
                        if (mounted.get() === current && changes.value == epoch && session.updates.value == version) {
                            action(); true
                        } else false
                    }
                }
                // Production admission is already captured. Neither secure persistence nor Session
                // is consulted in the Main window. The fallback is for deterministic fixtures only.
                if (authenticated != null) authenticated(publish) else accountCurrent(current.account) && publish()
            }
        }

    /** Expensive work belongs to the caller's background refresh lane, never a Compose/init callback.
     * One native read supplies all three views. Final publication checks only auth, mount identity
     * and the atomic update stamp; it does not reacquire Session or serialize state on Main. */
    internal fun captureStreamingPresentation(): StreamingPresentation {
        val epoch = changes.value
        val current = mounted.get()
        if (current != null && accountCurrent(current.account)) {
            return synchronized(current.session) {
                // Presentation stays readable during checkpoint uncertainty, exactly like read().
                // This metadata never grants mutation authority through withCurrentRead/owned.
                val read = current.session.read()
                check(mounted.get() === current && accountCurrent(current.account)) { "Native account changed" }
                val version = current.session.updates.value
                val projection = NativeProfileAccess.projection(read)
                val document = read.state.optJSONObject("hostDocument")
                val pending = document?.optJSONObject("nativeOwnAccountPending")
                val streaming = projection.profiles.filter { it.usesOwnAccount && !it.isOwner }.map {
                    StreamingProfile(it, false, pending?.has(it.id) == true)
                }
                val rows = NativeWatchedMigrationStorage.unresolvedCountForStatus(document)
                val watchlists = document?.optJSONArray("nativeWatchlistMigrationPending")?.length() ?: 0
                val candidates = document?.optJSONObject("nativeOwnAccountCandidates")?.length() ?: 0
                val migration = MigrationStatus(rows, false, watchlists).takeIf { rows > 0 || candidates > 0 || watchlists > 0 }
                StreamingPresentation(projection, streaming, migration) { action ->
                    withStreamingPresentationAdmission(current.account) {
                        synchronized(lifecycleLock) {
                            if (mounted.get() === current && changes.value == epoch && current.session.updates.value == version) {
                                action(); true
                            } else false
                        }
                    }
                }
            }
        }
        val pending = pendingImport?.takeIf { it.isCurrent() && accountCurrent(it.account) }
        if (pending != null) {
            val verified = pending.sources.filter { runCatching { it.withActive {} }.isSuccess }.map { it.profileID }.toSet()
            val streaming = pending.profiles.filter { it.usesOwnAccount && !it.isOwner }.map {
                StreamingProfile(it, it.id !in verified, true)
            }
            val migration = MigrationStatus(NativeWatchedMigrationStorage.unresolvedCountForStatus(pending.document), true,
                pending.document.optJSONArray("nativeWatchlistMigrationPending")?.length() ?: 0)
            return StreamingPresentation(null, streaming, migration) { action ->
                withStreamingPresentationAdmission(pending.account) {
                    if (!pending.isCurrent()) false else synchronized(lifecycleLock) {
                        if (mounted.get() == null && pendingImport === pending && changes.value == epoch) {
                            action(); true
                        } else false
                    }
                }
            }
        }
        return StreamingPresentation(null, emptyList(), null) { action ->
            synchronized(lifecycleLock) {
                if (mounted.get() == null && pendingImport == null && changes.value == epoch) { action(); true }
                else false
            }
        }
    }

    /** Same authenticated account fence as mutations, but stale metadata returns false. The
     * caller enters lifecycle next and must never call a Session while this admission is held. */
    private fun withStreamingPresentationAdmission(account: SessionOwnerSnapshot.Account, action: () -> Boolean): Boolean {
        val admission = captureOwnAccountAdmission(account)
        if (admission == null) {
            if (ownCredentials != null || !accountCurrent(account)) return false
            return action() // Legacy deterministic fixtures only; production always supplies admission.
        }
        return admission { accountCurrent(account) && action() }
    }

    fun captureStreamingTarget(profileID: String): StreamingTarget {
        mounted.get()?.takeIf { accountCurrent(it.account) }?.let { current ->
            val read = current.session.read()
            require(read.owner.profileID == profileID) { "Open this profile through its PIN gate before linking" }
            val profile = NativeProfileAccess.projection(read).profiles.single { it.id == profileID }
            require(profile.usesOwnAccount && !profile.isOwner)
            return StreamingTarget(current.account, profile, current.session, read.owner, null)
        }
        val pending = checkNotNull(pendingImport) { "No authenticated profile setup pending" }
        check(pending.isCurrent() && accountCurrent(pending.account))
        val profile = pending.profiles.single { it.id == profileID && it.usesOwnAccount && !it.isOwner }
        return StreamingTarget(pending.account, profile, null, null, pending.id)
    }
    fun requireStreamingTargetCurrent(target: StreamingTarget) {
        val session = target.session
        if (session != null) session.owned(requireNotNull(target.owner)) {
            check(mounted.get()?.let { it.account == target.account && it.session === session } == true)
            check(NativeProfileAccess.projection(session.read()).profiles.singleOrNull { it.id == target.profile.id } == target.profile)
        } else {
            val pending = checkNotNull(pendingImport)
            check(pending.id == target.pendingID && pending.account == target.account && pending.isCurrent() && accountCurrent(target.account))
            check(pending.profiles.singleOrNull { it.id == target.profile.id } == target.profile)
        }
    }
    /** Caller already holds ContinueWatchingOwnerGate -> Session, never acquire either inside auth. */
    fun withProfileMutation(session: VortxNativeSession, account: SessionOwnerSnapshot.Account, action: () -> Boolean): Boolean =
        withAccountAdmission(account, { true }) { withMountedSession(session, account, action) }

    /**
     * Playlist lock order is Session -> captured authenticated account admission -> mounted
     * lifecycle -> captured consumer lifetime. Session.dispatch is reentrant at the tail. Target
     * revocation takes only its lifetime monitor, so a commit already inside that monitor
     * linearizes before revocation; a revocation that wins first prevents the commit. The admitted
     * helper is called only while Session is held with its single validated presentation read.
     */
    private fun <T> withAdmittedPlaylistTarget(
        target: CapturedPlaylistTarget,
        read: VortxNativeRead,
        action: (VortxNativeRead) -> T,
    ): T {
        var result: Result<T>? = null
        val admitted = target.admission {
            if (!accountCurrent(target.account)) false else synchronized(lifecycleLock) {
                if (mounted.get() !== target.installation) false else target.lifetime.admit {
                    if (read.owner != target.owner) false else {
                        result = runCatching { action(read) }
                        true
                    }
                }
            }
        }
        check(admitted) { "Native playlist target changed" }
        return requireNotNull(result).getOrThrow()
    }

    private fun <T> withCapturedPlaylistTarget(target: CapturedPlaylistTarget, action: (VortxNativeRead) -> T): T =
        target.session.withCompleteAccountExportOwner(target.owner, target.originalRead != null) { read ->
            check(target.originalRead == null || (target.installation.readIdentity() === target.originalRead &&
                playlistAccountProducer === target.producer)) { "Original complete-account observation changed" }
            withAdmittedPlaylistTarget(target, read, action)
        }

    /** The acknowledged carrier has already crossed complete host validation. Clone only this
     * bounded family so callers cannot mutate Session-owned JSON or rewrite unknown siblings. */
    private fun playlistFields(read: VortxNativeRead, profileID: String): JSONObject {
        val profiles = read.state.getJSONObject("nativeHostPreferenceState").getJSONObject("document")
            .getJSONObject("profiles")
        val bucket = profiles.optJSONObject(NativeHostPreferences.canonicalProfileID(profileID)) ?: return JSONObject()
        val fields = bucket.getJSONObject("fields")
        return JSONObject().also { detached ->
            fields.keys().asSequence().filter { it.startsWith(NativePlaylist.PREFIX) }.forEach { field ->
                detached.put(field, JSONObject(fields.getJSONObject(field).toString()))
            }
        }
    }

    private fun playlistSnapshot(target: CapturedPlaylistTarget, read: VortxNativeRead): CapturedPlaylistSnapshot =
        CapturedPlaylistSnapshot(target, playlistFields(read, target.profileId))

    private inline fun <T> playlistResult(action: () -> T): Result<T> = try {
        Result.success(action())
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Result.failure(error)
    }

    override fun capturePlaylistProfile(): Result<NativePlaylistProfileGateway.Snapshot> = playlistResult {
        val installation = checkNotNull(mounted.get()) { "Native account has not completed authenticated bootstrap" }
        // This exact closure freezes sync operation generation, account owner epoch and session.
        // Playlist authority is unavailable rather than falling back to accountCurrent alone.
        val admission = checkNotNull(captureOwnAccountAdmission(installation.account)) {
            "Native playlist account admission unavailable"
        }
        val originalRead = installation.readIdentity()
        val producer = playlistAccountProducer
        installation.session.withPlaylistReceiptCapture(originalRead != null && producer != null) { read, receiptEpoch ->
            val receiptOwner = CapturedReceiptOwner(installation.account, installation.session, read.owner,
                installation, admission, receiptEpoch)
            val target = CapturedPlaylistTarget(installation.account, installation.session, read.owner,
                installation, admission, PlaylistLifetime(), receiptOwner, originalRead, producer)
            withAdmittedPlaylistTarget(target, read) { playlistSnapshot(target, it) }
        }
    }

    override fun playlistTargetIsCurrent(target: NativePlaylistProfileGateway.Target): Boolean {
        val captured = target as? CapturedPlaylistTarget ?: return false
        return runCatching { withCapturedPlaylistTarget(captured) { true } }.getOrDefault(false)
    }

    override fun playlistSnapshot(target: NativePlaylistProfileGateway.Target): Result<NativePlaylistProfileGateway.Snapshot> {
        val captured = target as? CapturedPlaylistTarget
            ?: return Result.failure(IllegalArgumentException("Invalid native playlist target"))
        return playlistResult { withCapturedPlaylistTarget(captured) { read -> playlistSnapshot(captured, read) } }
    }

    override fun publishPlaylistIfCurrent(snapshot: NativePlaylistProfileGateway.Snapshot, publication: () -> Unit): Boolean {
        val capturedSnapshot = snapshot as? CapturedPlaylistSnapshot ?: return false
        val captured = capturedSnapshot.target
        return runCatching { withCapturedPlaylistTarget(captured) { read ->
            if (!capturedSnapshot.matches(playlistFields(read, captured.profileId))) false
            else { publication(); true }
        } }.getOrDefault(false)
    }

    override fun retirePlaylistTarget(target: NativePlaylistProfileGateway.Target) {
        (target as? CapturedPlaylistTarget)?.lifetime?.revoke()
    }
    override fun retirePlaylistReceiptOwner(owner: NativePlaylistProfileGateway.ReceiptOwner) {
        (owner as? CapturedReceiptOwner)?.let {
            it.lifetime.revoke(); playlistReceipts.retire(it); playlistReceiptChanges.update { value -> value + 1 }
        }
    }

    private fun <T> withReceiptOwner(target: CapturedReceiptOwner, action: () -> T): T =
        target.session.withPlaylistReceiptEpoch(target.owner, target.profileEpoch) {
            var result: Result<T>? = null
            check(target.admission {
                if (!accountCurrent(target.account)) false else synchronized(lifecycleLock) {
                    if (mounted.get() !== target.installation) false else target.lifetime.admit {
                        result = runCatching(action); true
                    }
                }
            }) { "Native playlist target changed" }
            requireNotNull(result).getOrThrow()
        }

    override fun playlistReceiptState(owner: NativePlaylistProfileGateway.ReceiptOwner,
        ticket: NativePlaylistCloudReceiptLedger.Ticket,
        current: NativePlaylistCloudReceiptLedger.Fingerprint): NativePlaylistCloudReceiptLedger.State {
        val captured = owner as? CapturedReceiptOwner ?: return NativePlaylistCloudReceiptLedger.State.Unknown
        return runCatching { withReceiptOwner(captured) { playlistReceipts.state(captured, ticket, current) } }
            .getOrDefault(NativePlaylistCloudReceiptLedger.State.Unknown)
    }

    override fun freezePlaylistReceipts(account: SessionOwnerSnapshot.Account): Any? =
        playlistReceipts.freeze().filter { (playlistReceipts.owner(it) as? CapturedReceiptOwner)?.account == account }

    override fun acceptPlaylistReceipts(account: SessionOwnerSnapshot.Account, frozen: Any?,
        acceptedCandidate: String, version: Long) {
        if (acceptedCandidate.length > 7 * 1024 * 1024 || version < 0) return
        val entries = (frozen as? List<*>)?.filterIsInstance<NativePlaylistCloudReceiptLedger.Frozen>() ?: return
        if (entries.size > 64) return
        val host = runCatching { JSONObject(acceptedCandidate).getJSONObject("nativeHostPreferences") }.getOrNull() ?: return
        val firstOwner = entries.firstNotNullOfOrNull { playlistReceipts.owner(it) as? CapturedReceiptOwner } ?: return
        val scope = firstOwner.owner.scope
        if (runCatching { NativeHostPreferences.validate(scope, host) }.isFailure) return
        val profiles = host.getJSONObject("profiles")
        val profileIndex = NativeHostPreferences.profileKeyIndex(profiles)
        val groups = entries.mapNotNull { entry ->
            (playlistReceipts.owner(entry) as? CapturedReceiptOwner)?.let { it to entry }
        }.groupBy({ it.first }, { it.second })
        for ((session, owners) in groups.entries.groupBy { it.key.session }) {
            runCatching {
                synchronized(session) {
                    val read = session.read()
                    val currentFields = playlistFields(read, read.owner.profileID)
                    for ((target, ownedEntries) in owners) {
                        if (target.account != account || target.owner.scope != scope) continue
                        runCatching { withReceiptOwner(target) {
                            if (read.owner.profileID != target.owner.profileID) return@withReceiptOwner
                            val profileKey = profileIndex[NativeHostPreferences.canonicalProfileID(target.owner.profileID)]
                                ?: return@withReceiptOwner
                            val acceptedFields = profiles.getJSONObject(profileKey).getJSONObject("fields")
                            for (entry in ownedEntries) {
                                val accepted = acceptedFields.optJSONObject(entry.field) ?: continue
                                val current = currentFields.optJSONObject(entry.field) ?: continue
                                val acceptedBytes = NativePlaylist.canonicalReceiptRegister(accepted) ?: continue
                                val currentBytes = NativePlaylist.canonicalReceiptRegister(current) ?: continue
                                if (java.security.MessageDigest.isEqual(acceptedBytes, currentBytes) &&
                                    playlistReceipts.acknowledge(entry, acceptedBytes, version))
                                    playlistReceiptChanges.update { value -> value + 1 }
                            }
                        } }
                    }
                }
            }
        }
    }

    /** Validate before the first JSON serialization, then validate the detached immutable copy
     * again so a queued operation never observes later caller mutation. */
    private fun detachPlaylistEdit(field: String, expectedRegister: JSONObject?, value: Any,
                                   fields: JSONObject): DetachedPlaylistEdit {
        NativePlaylist.validateMutation(field, expectedRegister, value, fields)
        val expected = expectedRegister?.let { JSONObject(it.toString()) }
        val detachedValue = when (value) {
            JSONObject.NULL -> JSONObject.NULL
            is JSONObject -> JSONObject(value.toString())
            else -> throw IllegalArgumentException("Invalid playlist value")
        }
        NativePlaylist.validateMutation(field, expected, detachedValue, fields)
        return DetachedPlaylistEdit(field, expected, detachedValue)
    }

    override suspend fun compareAndSetPlaylistField(
        target: NativePlaylistProfileGateway.Target,
        editId: String,
        field: String,
        expectedRegister: JSONObject?,
        value: Any,
    ): Result<NativePlaylistProfileGateway.Snapshot> {
        val captured = target as? CapturedPlaylistTarget
            ?: return Result.failure(IllegalArgumentException("Invalid native playlist target"))
        val edit = runCatching { UUID.fromString(editId).takeIf { it.toString() == editId } }.getOrNull()
            ?: return Result.failure(IllegalArgumentException("Invalid playlist edit identity"))
        var accountWrite: com.vortx.android.sync.NativePlaylistAccountWrite? = null
        var originalCheckpoint: NativeCheckpointRead? = null
        val prepared = playlistResult {
            withCapturedPlaylistTarget(captured) { read ->
                val detached = detachPlaylistEdit(field, expectedRegister, value, playlistFields(read, captured.profileId))
                originalCheckpoint = captured.session.captureGenericPlaylistCheckpoint(captured.owner)
                if (!captured.session.hasOwnerHistory()) {
                    accountWrite = checkNotNull(captured.producer?.capture(captured.account)) {
                        "Complete account write admission unavailable"
                    }
                }
                detached
            }
        }.getOrElse { accountWrite?.close(); return Result.failure(it) }
        val operationJob = currentCoroutineContext()[Job]
        return try { withContext(Dispatchers.IO) {
            playlistResult {
                operationJob?.ensureActive()
                withCapturedPlaylistTarget(captured) { read ->
                    operationJob?.ensureActive()
                    val liveFields = playlistFields(read, captured.profileId)
                    NativePlaylist.validateMutation(prepared.field, prepared.expectedRegister, prepared.value, liveFields)
                    captured.session.dispatchBudgetedPlaylist(captured.owner,
                        JSONObject().put(prepared.field, prepared.value),
                        prospectiveGlobalChanges = accountWrite?.pendingGlobalValues(),
                        genericCheckpoint = originalCheckpoint,
                        genericAdmission = accountWrite?.let { write -> { native: ByteArray, host: ByteArray, commit: () -> Unit ->
                            captured.installation.withRead(checkNotNull(captured.originalRead)) { raw, projection ->
                                write.commitCandidate(raw, projection, native, host) {
                                    operationJob?.ensureActive()
                                    check(mounted.get() === captured.installation && accountCurrent(captured.account) &&
                                        playlistAccountProducer === captured.producer)
                                    NativePlaylist.validateMutation(prepared.field, prepared.expectedRegister, prepared.value,
                                        playlistFields(captured.session.read(), captured.profileId))
                                    commit()
                                }
                            }
                        } }, beforeCommit = {
                            operationJob?.ensureActive()
                            check(mounted.get() === captured.installation && accountCurrent(captured.account)) {
                                "Native playlist target changed"
                            }
                            // Session is still on the original state here. This is the final raw
                            // register CAS/domain admission after candidate construction and before
                            // its complete-account checkpoint is allowed to replace durable state.
                            NativePlaylist.validateMutation(prepared.field, prepared.expectedRegister, prepared.value,
                                playlistFields(captured.session.read(), captured.profileId))
                        })
                    val acceptedRead = captured.session.read()
                    check(acceptedRead.owner == captured.owner) { "Native playlist owner changed during commit" }
                    val acceptedFields = playlistFields(acceptedRead, captured.profileId)
                    val register = acceptedFields.optJSONObject(prepared.field)
                        ?: error("Native playlist register was not acknowledged")
                    check(NativeHostPreferences.equal(register.opt("value"), prepared.value)) {
                        "Native playlist register readback did not match"
                    }
                    val receipt = runCatching { NativePlaylist.canonicalReceiptRegister(register)?.let {
                        playlistReceipts.register(captured.receiptOwner, edit, prepared.field, it)
                    } }.getOrNull()
                    // The ordinary Session notification has already fired. Re-arm after registration
                    // under this original admission so a fast earlier upload cannot miss this edit.
                    if (receipt != null) {
                        playlistReceiptChanges.update { value -> value + 1 }
                        runCatching { onMutation(captured.account) }
                    }
                    CapturedPlaylistSnapshot(captured, acceptedFields, receipt)
                }
            }
        } } finally { accountWrite?.close() }
    }

    /** The Session -> original auth admission -> mount -> lifetime order matches other writers.
     * No callback samples a new account, producer, owner, GET or logical registry on resume. */
    private fun <T> withCapturedXperienceTarget(target: CapturedXperienceTarget, action: (VortxNativeRead) -> T): T =
        target.session.withCompleteAccountExportOwner(target.owner, target.originalRead != null) { read ->
            check(target.installation.readIdentity() === target.originalRead && playlistAccountProducer === target.producer) {
                "Original Xperience account observation changed"
            }
            check(target.session.xperienceContext(read) == target.context) { "Original Xperience context changed" }
            var result: Result<T>? = null
            check(target.admission {
                if (!accountCurrent(target.account)) false else synchronized(lifecycleLock) {
                    if (mounted.get() !== target.installation) false else target.lifetime.admit {
                        result = runCatching { action(read) }; true
                    }
                }
            }) { "Original Xperience target changed" }
            requireNotNull(result).getOrThrow()
        }

    private fun xperienceSnapshot(target: CapturedXperienceTarget) = CapturedXperienceSnapshot(target,
        target.session.xperienceFields(target.owner))

    private class XperienceOpening(val issuer: NativeAccountCoordinator, val installation: Mounted,
        val update: Long, val originalRead: NativeAccountReadCapture?,
        val producer: com.vortx.android.sync.NativePlaylistAccountProducer, val admission: (() -> Boolean) -> Boolean) : NativeXperienceCatalogGateway.OpeningStage {
        val live = java.util.concurrent.atomic.AtomicBoolean(true)
        val used = java.util.concurrent.atomic.AtomicBoolean(false)
        override fun close() { live.set(false) }
    }
    /** Scalars only on the UI event lane. Do NOT enter Session or durable auth/file admission. */
    internal fun stageXperienceOpening(): NativeXperienceCatalogGateway.OpeningStage? {
        val installation = mounted.get() ?: return null
        val update = installation.session.updates.value
        val originalRead = installation.readIdentity()
        val producer = playlistAccountProducer ?: return null
        val admission = captureOwnAccountAdmission(installation.account) ?: return null
        return if (mounted.get() === installation && installation.session.updates.value == update &&
            installation.readIdentity() === originalRead && playlistAccountProducer === producer)
            XperienceOpening(this, installation, update, originalRead, producer, admission) else null
    }
    /** IO caller consumes one original stage. A→B→A, update, mount/read/producer or auth drift
     * cannot be replaced by whichever account happens to be current after the hop. */
    internal fun openXperienceSnapshot(stage: NativeXperienceCatalogGateway.OpeningStage): NativeXperienceProfileGateway.Snapshot {
        val original = stage as? XperienceOpening ?: error("Invalid Xperience opening")
        check(original.issuer === this && original.live.get() && original.used.compareAndSet(false, true))
        val installation = original.installation
        fun current() = original.live.get() && mounted.get() === installation &&
            installation.session.updates.value == original.update && installation.readIdentity() === original.originalRead &&
            playlistAccountProducer === original.producer
        var created: CapturedXperienceTarget? = null
        var transferred = false
        return try { installation.session.withCompleteAccountExportRead(original.originalRead != null) { read ->
            var snapshot: NativeXperienceProfileGateway.Snapshot? = null
            check(original.admission {
                if (!current() || !accountCurrent(installation.account)) false else {
                    val target = CapturedXperienceTarget(installation.account, installation.session, read.owner, installation,
                        original.admission, PlaylistLifetime(), original.originalRead, original.producer, installation.session.xperienceContext(read))
                    created = target
                    snapshot = withCapturedXperienceTarget(target) { xperienceSnapshot(target) }
                    current()
                }
            }) { "Original Xperience opening changed" }
            check(current()) { "Original Xperience opening changed" }
            checkNotNull(snapshot).also { transferred = true }
        } } finally { if (!transferred) created?.lifetime?.revoke() }
    }

    /** Read-only adapter admission. Target context does NOT contain saved raw registers: the
     * genuine original Snapshot must also match before and after the synchronous callback. */
    internal fun <T> withXperienceSnapshotRead(snapshot: NativeXperienceProfileGateway.Snapshot,
        action: (VortxNativeSession, VortxNativeRead) -> T): T {
        val original = snapshot as? CapturedXperienceSnapshot ?: error("Invalid Xperience snapshot")
        return withCapturedXperienceTarget(original.target) { read ->
            fun current(): Boolean {
                val fields = original.target.session.xperienceFields(original.target.owner)
                return try { original.matches(fields) } finally { fields.values.forEach { it.fill(0) } }
            }
            check(current()) { "Original Xperience snapshot changed" }
            action(original.target.session, read).also {
                check(current()) { "Original Xperience snapshot changed" }
            }
        }
    }

    override fun captureXperienceProfile(): Result<NativeXperienceProfileGateway.Snapshot> = playlistResult {
        val installation = checkNotNull(mounted.get()) { "Open the authenticated native account first" }
        val admission = checkNotNull(captureOwnAccountAdmission(installation.account)) { "Xperience account admission unavailable" }
        val originalRead = installation.readIdentity()
        val producer = checkNotNull(playlistAccountProducer) { "Complete account write admission unavailable" }
        installation.session.withCompleteAccountExportRead(originalRead != null) { read ->
            val target = CapturedXperienceTarget(installation.account, installation.session, read.owner, installation,
                admission, PlaylistLifetime(), originalRead, producer, installation.session.xperienceContext(read))
            withCapturedXperienceTarget(target) { xperienceSnapshot(target) }
        }
    }
    override fun xperienceSnapshot(target: NativeXperienceProfileGateway.Target): Result<NativeXperienceProfileGateway.Snapshot> =
        playlistResult {
            val captured = target as? CapturedXperienceTarget ?: error("Invalid Xperience target")
            withCapturedXperienceTarget(captured) { xperienceSnapshot(captured) }
        }
    override fun xperienceTargetIsCurrent(target: NativeXperienceProfileGateway.Target): Boolean =
        (target as? CapturedXperienceTarget)?.let { runCatching { withCapturedXperienceTarget(it) { true } }.getOrDefault(false) } ?: false
    override fun publishXperienceIfCurrent(snapshot: NativeXperienceProfileGateway.Snapshot, publication: () -> Unit): Boolean {
        val captured = snapshot as? CapturedXperienceSnapshot ?: return false
        return runCatching { withCapturedXperienceTarget(captured.target) {
            if (!captured.matches(captured.target.session.xperienceFields(captured.target.owner))) false
            else { publication(); true }
        } }.getOrDefault(false)
    }
    override fun retireXperienceTarget(target: NativeXperienceProfileGateway.Target) {
        (target as? CapturedXperienceTarget)?.lifetime?.revoke()
    }
    override suspend fun writeXperience(target: NativeXperienceProfileGateway.Target,
        edit: XperienceImportNamespace.Edit): Result<NativeXperienceProfileGateway.Snapshot> =
        persistXperience(target) { NativeXperienceWrite.Change.edit(edit) }
    override suspend fun deleteXperience(target: NativeXperienceProfileGateway.Target,
        saved: XperienceImportNamespace.Saved): Result<NativeXperienceProfileGateway.Snapshot> =
        persistXperience(target) { NativeXperienceWrite.Change.delete(saved) }

    private suspend fun persistXperience(target: NativeXperienceProfileGateway.Target,
        change: () -> NativeXperienceWrite.Change): Result<NativeXperienceProfileGateway.Snapshot> {
        val captured = target as? CapturedXperienceTarget ?: return Result.failure(IllegalArgumentException("Invalid Xperience target"))
        var accountWrite: com.vortx.android.sync.NativePlaylistAccountWrite? = null
        val operation = playlistResult {
            withCapturedXperienceTarget(captured) {
                // Capture both the actual complete-account producer and exact Session checkpoint
                // before the first suspension. Typed and generic routes share this requirement.
                accountWrite = checkNotNull(captured.producer.capture(captured.account)) { "Complete account write admission unavailable" }
                captured.session.captureXperienceOperation(captured.owner, captured.context, change(), captured.originalRead != null)
            }
        }.getOrElse { accountWrite?.close(); return Result.failure(it) }
        val write = checkNotNull(accountWrite)
        val operationJob = currentCoroutineContext()[Job]
        return try { withContext(Dispatchers.IO) {
            playlistResult {
                operationJob?.ensureActive()
                withCapturedXperienceTarget(captured) {
                    fun recheck() {
                        operationJob?.ensureActive()
                        // Re-enter only this target, whose exact original admission/lifetime is
                        // still held across the full budget preview and durable callback.
                        withCapturedXperienceTarget(captured) { }
                    }
                    captured.session.dispatchXperience(operation, write.pendingGlobalValues(),
                        genericAdmission = { native, host, commit ->
                            captured.installation.withRead(checkNotNull(captured.originalRead)) { raw, projection ->
                                write.commitXperienceCandidate(raw, projection, native, host) { recheck(); commit() }
                            }
                        },
                        typedAdmission = { account, host, commit ->
                            write.commitPreparedCandidate(account, host) { recheck(); commit() }
                        }, beforeCommit = { recheck() })
                    // Session has checked exact raw register readback AFTER the existing
                    // authenticated checkpoint readback/native acceptance and in-memory swap.
                    check(captured.session.read().owner == captured.owner) { "Xperience owner changed during commit" }
                    xperienceSnapshot(captured)
                }
            }
        } } finally { operation.close(); write.close() }
    }

    suspend fun signInStreaming(target: StreamingTarget, email: String, password: String): Boolean = mutex.withLock {
        val credentials = checkNotNull(ownCredentials) { "Native streaming sign-in unavailable" }
        val admission = checkNotNull(captureOwnAccountAdmission(target.account)) { "Native account authentication changed" }
        val session = target.session
        if (session != null) {
            check(mounted.get()?.let { it.account == target.account && it.session === session } == true)
            val linked = NativeStreamingAccountLink(credentials, ownProducer, watchedProducer).signIn(session, target.account, target.profile.id, email, password,
                admission, { action -> withMountedSession(session, target.account, action) }, requireNotNull(target.owner))
            project(session)
            check(accountCurrent(target.account) && mounted.get()?.session === session)
            changes.value += 1
            return@withLock linked
        }
        val pending = checkNotNull(pendingImport)
        check(pending.id == target.pendingID && pending.account == target.account && pending.isCurrent() && accountCurrent(target.account))
        val capture = ownProducer.signIn(credentials, target.account, target.profile.id, email, password, admission, UUID.randomUUID().toString())
        // An arbitrary newly entered account cannot attest to historical UUID overlay ownership.
        val source = ownProducer.fetch(capture, JSONObject(), witnessedOverlay = false)
        check(pendingImport === pending && pending.isCurrent() && accountCurrent(target.account))
        val applied = applyDocumentLocked(target.account, pending.document, pending.isCurrent,
            pending.sources.filterNot { it.profileID == target.profile.id } + source)
        if (applied) onMutation(target.account)
        applied
    }
    fun session(): VortxNativeSession = checkNotNull(mounted.get()) { "Native account has not completed authenticated bootstrap" }
        .also { check(accountCurrent(it.account)) { "Native account changed" } }.session
    /** Captures only a still-mounted identity; callers perform account authentication outside this lock. */
    internal fun accountFor(session: VortxNativeSession): SessionOwnerSnapshot.Account? = synchronized(lifecycleLock) {
        mounted.get()?.takeIf { it.session === session }?.account
    }
    internal class ForYouMutationAdmission(val identity: Any, private val admission: (() -> Boolean) -> Boolean) {
        fun admit(action: () -> Boolean): Boolean = admission(action)
    }

    /** Capture under Session. Retain full account generation, exact mount and auth/session/operation scope. */
    internal fun captureForYouMutationAdmission(session: VortxNativeSession): ForYouMutationAdmission {
        check(Thread.holdsLock(session)) { "For You capture must hold Session" }
        val current = checkNotNull(mounted.get()) { "Native account changed" }
        check(current.session === session && accountCurrent(current.account)) { "Native account changed" }
        val account = current.account
        val authenticated = captureForYouAccountAuthority(account)
        check(authenticated != null || ownCredentials == null) { "For You authentication unavailable" }
        val identity = listOf(com.vortx.android.foryou.ForYouIdentityRef(current), account,
            authenticated?.identity ?: com.vortx.android.foryou.ForYouIdentityRef(current))
        return ForYouMutationAdmission(identity) { action ->
            val mountedAction = {
                synchronized(lifecycleLock) { if (mounted.get() === current) action() else false }
            }
            if (authenticated != null) authenticated.admit(mountedAction)
            else accountCurrent(account) && mountedAction() // deterministic fixtures only
        }
    }
    /**
     * Final reclaim fence. Deliberately contains no auth or session calls: writers enter in the
     * established Session -> authenticated-admission -> lifecycle order and retire never waits
     * for a session while it owns this lock.
     */
    internal fun withMountedSession(session: VortxNativeSession, account: SessionOwnerSnapshot.Account, action: () -> Boolean): Boolean = synchronized(lifecycleLock) {
        if (mounted.get()?.let { it.session === session && it.account == account } == true) action() else false
    }
    override fun retire() {
        pendingImport = null
        val old = synchronized(lifecycleLock) {
            // Purge volatile register bytes before authority/retirement callbacks can expose the
            // transition. Lifecycle -> ledger matches the captured admission lock order.
            playlistReceipts.retire()
            onAuthorityChanged()
            if (mounted.get() != null) com.vortx.android.player.PlaybackOwnerEpoch.invalidate()
            mounted.getAndSet(null).also { if (it != null) { it.retireRead(); retired.add(it.session) } }
        }
        playlistReceiptChanges.update { value -> value + 1 }
        if (old != null) playlistMountRevisions.value += 1
        changes.value += 1
        onRetired()
        if (old != null) {
            dispose { old.session.close(); retired.remove(old.session) }
        }
    }

    override fun currentMountToken(account: SessionOwnerSnapshot.Account): NativeAccountMountToken? {
        val current = mounted.get()?.takeIf { it.account == account && accountCurrent(account) } ?: return null
        if (current.session.requiresRecovery()) return null
        val revision = current.session.updates.value
        return if (mounted.get() === current && accountCurrent(account)) NativeAccountMountToken(current, revision) else null
    }

    override suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): Boolean =
        reopenCheckpoint(account, isCurrent, null)

    private suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean,
        onInstalled: ((Mounted) -> Unit)?): Boolean = mutex.withLock {
        check(isCurrent() && accountCurrent(account)) { "Native account changed" }
        check(account.id !in uncertainHistoryAccounts) { "Owner history writer retirement unconfirmed" }
        mounted.get()?.takeIf { it.account == account && !it.session.requiresRecovery() }?.let { return@withLock true }
        retire()
        while (true) { val prior = retired.peek() ?: break; prior.close(); retired.remove(prior) }
        val namespace = "account.${UUID.fromString(account.id).toString().lowercase()}"
        val scope = checkpoints.discover(namespace) ?: run {
            val retained = checkpoints.readPreflight(namespace) ?: return@withLock false
            if (checkpoints.readRetained(retained.scope) != null) retained.scope // State committed before locator publication.
            else {
                restorePreflight(account, retained, isCurrent)
                changes.value += 1
                return@withLock false
            }
        }
        val raw = checkNotNull(checkpoints.readRetained(scope))
        val typed = if (NativeOwnerHistorySessionAdapter.isEnvelope(raw))
            NativeOwnerHistoryCoordinator.decodeEnvelope(raw.toByteArray(Charsets.UTF_8), scope) else null
        val state = if (typed == null) scope.validateSnapshot(raw) else null
        val ownerName = if (typed != null) {
            val retained = OHJson.Obj(typed.snapshot)
            retained.obj("roster").obj("profiles").obj(scope.ownerProfileID).text("name")
        } else requireNotNull(state).getJSONObject("roster").getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getString("name")
        state?.optJSONObject("hostDocument")?.optJSONObject("nativeLegacyMembershipPending")?.let { journal ->
            nativeLegacyMembershipJournal(scope, journal, JSONArray(),
                state.getJSONObject("roster").getJSONObject("profiles").keys().asSequence().toSet())
        }
        if (state != null) requireNotNull(state.getJSONObject("nativeSync").optJSONObject("legacyImport")) { "Native account requires a verified legacy baseline receipt" }
        val resources = transport()
        val candidate = try { VortxNativeSession.open(scope, ownerName, bindings, checkpoints, resources,
            onMutation = { onMutation(account) }, beforeOwnerChange = onAuthorityChanged,
            onProgressMutation = { onProgressMutation(account) }, ownerHistoryBindings = historyBindings,
            ownerHistoryAuthority = ownerHistoryAuthority(account) { accountCurrent(account) }) { accountCurrent(account) } }
            catch (error: Throwable) {
                if (error is NativeOwnerHistoryCoordinator.Uncertain) uncertainHistoryAccounts.add(account.id)
                (resources as? AutoCloseable)?.close(); throw error
            }
        try { withAccountAdmission(account, isCurrent) { checkpoints.remember(scope) } }
        catch (error: Throwable) { retireUnpublished(account, candidate); throw error }
        publish(account, candidate, isCurrent, onInstalled)
    }

    override suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): JSONObject =
        prepareEmptyAccount(account, isCurrent, null)

    private suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean,
        onInstalled: ((Mounted) -> Unit)?): JSONObject {
        if (reopenCheckpoint(account, isCurrent, onInstalled)) {
            require(!session().hasOwnerHistory()) { "Existing owner-history backup disappeared" }
            val read = session().read()
            return session().owned(read.owner) {
                check(isCurrent() && accountCurrent(account))
                val baseline = read.state.getJSONObject("hostDocument")
                require(baseline.optString("nativeAccountBootstrap") == "authenticated-empty-v1") { "Existing account backup disappeared" }
                nativeMigrationSourceDocument(baseline).put("nativeSync", read.state.getJSONObject("nativeSync"))
                    .put("nativeHostPreferences", read.state.getJSONObject("nativeHostPreferenceState").getJSONObject("document"))
            }
        }
        val scope = VortxAccountScope("account.${UUID.fromString(account.id).toString().lowercase()}", UserProfile.OWNER_ID)
        checkpoints.read(scope)?.let { snapshot ->
            // Recover a first-creation crash after state commit but before locator publication.
            // This exact account+fixed-owner encrypted file is evidence; an arbitrary old owner is not.
            val retained = scope.validateSnapshot(snapshot)
            val baseline = retained.getJSONObject("hostDocument")
            require(baseline.optString("nativeAccountBootstrap") == "authenticated-empty-v1") { "Existing account backup disappeared" }
            check(mutex.withLock { applyDocumentLocked(account, baseline, isCurrent, onInstalled = onInstalled) })
            return prepareEmptyAccount(account, isCurrent, onInstalled)
        }
        checkpoints.verifyFreshAccount(scope)
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
        val document = JSONObject().put("nativeAccountBootstrap", "authenticated-empty-v1")
            .put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode().put("addonPreferences", JSONObject())))
                .put("rosterModified", 0).put("library", JSONArray()).put("addons", JSONArray()))
        // A candidate is not an account until create-only PUT(0) is acknowledged. In particular,
        // do not poison the owner locator/import receipt before discovering a concurrent winner.
        VortxNativeRuntime.create(bindings, scope.ownerProfileID, "Main").use { candidate ->
            val material = nativeLegacyMaterial(document, listOf(owner), 0.0)
            for (action in listOf(JSONObject().put("type", "bind_sync_scope").put("scope", scope.accountID),
                JSONObject().put("type", "import_legacy_sync").put("scope", scope.accountID)
                    .put("ownerProfileId", scope.ownerProfileID).put("material", material))) {
                check(JSONObject(candidate.dispatch(action.toString())).getBoolean("ok")) { "Native account seed unavailable" }
            }
            check(isCurrent() && accountCurrent(account)) { "Native account changed" }
            return document.put("nativeSync", JSONObject(candidate.stateJson()).getJSONObject("nativeSync"))
                .put("nativeHostPreferences", NativeHostPreferences.empty(scope))
        }
    }

    /** Keep the exact unpublished writer until close is confirmed, including cancellation and
     * projection failures. A failed close must not make a rival writer eligible for this account. */
    private fun retireUnpublished(account: SessionOwnerSnapshot.Account, candidate: VortxNativeSession) {
        if (!retired.contains(candidate)) retired.add(candidate)
        try { candidate.close(); retired.remove(candidate) }
        catch (failure: Throwable) {
            uncertainHistoryAccounts.add(account.id)
            throw failure
        }
    }

    private suspend fun publish(account: SessionOwnerSnapshot.Account, candidate: VortxNativeSession, isCurrent: () -> Boolean,
        onInstalled: ((Mounted) -> Unit)? = null): Boolean {
        try { currentCoroutineContext().ensureActive() }
        catch (error: Throwable) { retireUnpublished(account, candidate); throw error }
        val next = Mounted(account, candidate)
        // Authentication may take its own lock; never invoke it while holding lifecycleLock.
        val current = isCurrent() && accountCurrent(account)
        val installed = current && synchronized(lifecycleLock) {
            onAuthorityChanged()
            if (mounted.get() != null) false else {
                com.vortx.android.player.PlaybackOwnerEpoch.invalidate()
                mounted.compareAndSet(null, next).also { if (it) onInstalled?.invoke(next) }
            }
        }
        if (!installed) {
            retireUnpublished(account, candidate); error("Native account changed")
        }
        try {
            project(candidate)
            check(isCurrent() && accountCurrent(account) && mounted.get() === next) { "Native account changed" }
            playlistMountRevisions.value += 1
            changes.value += 1
            return true
        } catch (error: Throwable) {
            val removed = synchronized(lifecycleLock) {
                if (mounted.get() !== next) false else {
                    com.vortx.android.player.PlaybackOwnerEpoch.invalidate()
                    mounted.compareAndSet(next, null)
                }
            }
            if (removed) retireUnpublished(account, candidate)
            throw error
        }
    }

    override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean = mutex.withLock {
        require(!document.has(NativeOwnerHistoryAccount.ARCHIVE) && document.optJSONObject("nativeSync")?.optInt("schemaVersion") != 6) {
            "Original authenticated account bytes required"
        }
        require(nativeMigrationSidecars.none(document::has) && !document.has("websiteAddonEditPending")) { "Device-local migration evidence is not an authenticated cloud source" }
        applyDocumentLocked(account, document, isCurrent)
    }

    /** Retain provenance only on the exact accepted generic mount; it is not mutation authority. */
    private fun retainAuthenticatedRead(
        account: SessionOwnerSnapshot.Account,
        captured: NativeAccountReadCapture,
        isCurrent: () -> Boolean,
    ): Boolean {
        if (captured.account != account || !isCurrent() || !accountCurrent(account)) return false
        val current = mounted.get()?.takeIf {
            it.account == account && !it.session.requiresRecovery() && !it.session.hasOwnerHistory()
        } ?: return false
        val retained = runCatching { captured.retainedCopyFor(account) }.getOrNull() ?: return false
        val raw = captured.copyRawForApply(account)
        val projection = try {
            val native = NativeProfileOverlayWitness.parseAccountDocument(raw).getJSONObject("nativeSync")
            // Same public generic create/bind/merge path used by NativeOwnAccountBaseline.validate.
            // This is the source-only projection, before any local pending state was merged into it.
            VortxNativeRuntime.create(bindings, current.session.scope.ownerProfileID, "Owner").use { runtime ->
                for (action in listOf(JSONObject().put("type", "bind_sync_scope").put("scope", current.session.scope.accountID),
                    JSONObject().put("type", "merge_native_sync").put("document", native))) {
                    check(JSONObject(runtime.dispatch(action.toString())).getBoolean("ok")) { "Generic source projection rejected" }
                }
                JSONObject(runtime.stateJson()).getJSONObject("nativeSync").toString().toByteArray(Charsets.UTF_8)
            }
        } catch (cancelled: CancellationException) { retained.retire(); throw cancelled }
        catch (failure: Throwable) { retained.retire(); return false }
        finally { raw.fill(0) }
        try { if (!current.retain(retained, projection)) { retained.retire(); return false } }
        finally { projection.fill(0) }
        if (mounted.get() !== current || !isCurrent() || !accountCurrent(account)) {
            current.clearRead(retained)
            return false
        }
        return true
    }

    override suspend fun applyRawDocument(account: SessionOwnerSnapshot.Account, raw: ByteArray, isCurrent: () -> Boolean): Boolean =
        applyRawDocumentInternal(account, raw, null, isCurrent)

    override suspend fun applyRawDocument(
        account: SessionOwnerSnapshot.Account,
        captured: NativeAccountReadCapture,
        isCurrent: () -> Boolean,
    ): Boolean {
        val raw = captured.copyRawForApply(account)
        return try {
            applyRawDocumentInternal(account, raw, captured, isCurrent)
        } finally {
            raw.fill(0)
            captured.retire()
        }
    }

    private suspend fun applyRawDocumentInternal(
        account: SessionOwnerSnapshot.Account,
        raw: ByteArray,
        captured: NativeAccountReadCapture?,
        isCurrent: () -> Boolean,
    ): Boolean = mutex.withLock {
        if (captured != null) check(captured.account == account) { "Authenticated account read owner changed" }
        check(account.id !in uncertainHistoryAccounts) { "Owner history writer retirement unconfirmed" }
        check(isCurrent() && accountCurrent(account)) { "Native account changed" }
        // Revoke the exact current mount's old baseline before parsing into any mutation path.
        // A later native dispatch/projection/checkpoint failure must not leave old provenance usable.
        mounted.get()?.takeIf { it.account == account }?.clearRead()
        val exact = NativeOwnerHistoryAccount(raw)
        // Retain the original register bytes BEFORE decoding the account presentation.
        val originalHostPreferences = exact.raw("nativeHostPreferences")
        val document = NativeProfileOverlayWitness.parseAccountDocument(raw)
        require(nativeMigrationSidecars.none(document::has) && !document.has("websiteAddonEditPending")) { "Device-local evidence is not a cloud source" }
        val namespace = "account.${UUID.fromString(account.id).toString().lowercase()}"
        val located = checkpoints.discover(namespace)
        val current = mounted.get()?.takeIf { it.account == account && !it.session.requiresRecovery() }
        val localTyped = current?.session?.hasOwnerHistory() == true || located?.let { scope ->
            checkpoints.readRetained(scope)?.let(NativeOwnerHistorySessionAdapter::isEnvelope)
        } == true
        val incoming = exact.raw("nativeSync")?.let { OHJson.Obj(it) }
        val schema = incoming?.let { OHJson.integer(it.raw("schemaVersion")) }
        if (schema != 6L && exact.raw(NativeOwnerHistoryAccount.ARCHIVE) == null && !localTyped)
            return@withLock applyDocumentLocked(account, document, isCurrent,
                originalHostPreferences = originalHostPreferences).let { applied ->
                if (!applied) return@let false
                // The primary sync apply has already succeeded. Baseline retention is optional and
                // limited to known schema 1–5; it must not make ordinary sync acceptance fail.
                if (captured != null && schema?.let { it in 1L..5L } == true) retainAuthenticatedRead(account, captured, isCurrent)
                true
            }
        val native = requireNotNull(incoming) { "Owner-history native carrier missing" }
        require(native.text("scope") == namespace)
        val scope = VortxAccountScope(namespace, native.text("ownerProfileId"))
        located?.let { require(it == scope) { "Native account owner changed" } }
        val job = currentCoroutineContext()[Job]
        val active = { job?.isActive != false && isCurrent() && accountCurrent(account) }
        val original = ownerHistoryAuthority(account, active)
        val mountedCurrent = { accountCurrent(account) }
        val mountedAuthority = ownerHistoryAuthority(account, mountedCurrent)
        val remoteHost = document.optJSONObject("nativeHostPreferences")
        if (document.has("nativeHostPreferences")) requireNotNull(remoteHost)
        remoteHost?.let { NativeHostPreferences.validate(scope, it) }
        if (current != null) {
            require(current.session.scope == scope)
            val read = current.session.read()
            current.session.owned(read.owner) {
                original.withActive {
                    check(withMountedSession(current.session, account) {
                        current.session.receiveOwnerHistory(exact, original, historyBindings, remoteHost); true
                    }) { "Native account changed" }
                }
            }
            applyTypedWebsiteEvents(current.session, account, document, active)
            project(current.session)
            check(active() && mounted.get() === current)
            current.clearRead()
            pendingImport = null
            return@withLock true
        }
        retire()
        while (true) { val prior = retired.peek() ?: break; prior.close(); retired.remove(prior) }
        val stored = checkpoints.captureCheckpoint(scope)
        val resources = transport()
        var candidate: VortxNativeSession? = null
        try {
            candidate = if (stored.plaintext != null) {
                if (NativeOwnerHistorySessionAdapter.isEnvelope(stored.plaintext)) {
                    VortxNativeSession.openOwnerHistory(scope,
                        NativeOwnerHistoryCoordinator.decodeEnvelope(stored.plaintext.toByteArray(Charsets.UTF_8), scope), stored,
                        bindings, historyBindings, checkpoints, resources, mountedAuthority, { onMutation(account) }, onAuthorityChanged,
                        { onProgressMutation(account) }, mountedCurrent, original)
                } else VortxNativeSession.openForOwnerHistoryTransfer(scope, stored, bindings, checkpoints, resources,
                    { onMutation(account) }, onAuthorityChanged, { onProgressMutation(account) }, mountedCurrent, mountedAuthority)
            } else {
                // Original absence is create-only. Preserve unresolved older setup in the SAME
                // typed envelope and leave its original encrypted preflight file untouched.
                val preflight = checkpoints.readPreflight(namespace)?.also { require(it.scope == scope) }
                checkpoints.verifyOwnerHistoryAbsence(scope, stored, preflight)
                val carrier = requireNotNull(exact.raw(NativeOwnerHistoryAccount.ARCHIVE))
                val uid = NativeOwnerHistorySources.readOwnerUID(scope, carrier)
                val host = NativeHostPreferences.merge(scope, NativeHostPreferences.local(scope), remoteHost)
                val rawHost = NativeRawHostPreferences.reconcile(scope, null, host, remoteHost, originalHostPreferences)
                val archiveInput = JSONObject(document.toString()).also { it.remove("nativeSync"); it.remove(NativeOwnerHistoryAccount.ARCHIVE) }
                val archive = preflight?.archive ?: NativeHostDocument.archive(archiveInput)
                val localObject = OHJson.Obj().set("hostDocument", archive.getJSONObject("document").toString().toByteArray(Charsets.UTF_8))
                    .set("excludedCredentialPaths", archive.getJSONArray("excludedCredentialPaths").toString().toByteArray(Charsets.UTF_8))
                    .set("nativeHostPreferenceState", rawHost)
                preflight?.let { localObject.set("nativeMigrationPreflightRetained", OHJson.quote(it.raw)) }
                val local = localObject.encoded()
                val prepared = NativeOwnerHistoryCoordinator.prepareColdPeer(scope,
                    NativeOwnerHistoryCoordinator.Target(scope.ownerProfileID, uid), exact, rawHost,
                    historyBindings, original, { NativeOwnerHistoryAccount(it).validateBudget(true) },
                    { NativeOwnerHistorySessionAdapter.projection(scope, it) }, local)
                val committed = original.withActive {
                    checkpoints.verifyOwnerHistoryAbsence(scope, stored, preflight)
                    checkpoints.compareAndCommitCheckpoint(scope, stored, OHJson.utf8(prepared.envelope()))
                }
                VortxNativeSession.openOwnerHistory(scope, prepared, committed, bindings, historyBindings, checkpoints, resources,
                    mountedAuthority, { onMutation(account) }, onAuthorityChanged, { onProgressMutation(account) }, mountedCurrent, original)
            }
            // First peer was fully admitted by prepareColdPeer; other mounts must join it against
            // the original local state rather than replacing an existing native checkpoint.
            val session = requireNotNull(candidate)
            if (stored.plaintext != null) session.receiveOwnerHistory(exact, original, historyBindings, remoteHost)
            applyTypedWebsiteEvents(session, account, document, active)
            original.withActive { checkpoints.remember(scope) }
            pendingImport = null
            publish(account, session, active)
            mounted.get()?.takeIf { it.account == account }?.clearRead()
            true
        } catch (failure: Throwable) {
            if (failure is NativeOwnerHistoryCoordinator.Uncertain) uncertainHistoryAccounts.add(account.id)
            candidate?.let { owned -> runCatching { retireUnpublished(account, owned) }.onFailure { failure.addSuppressed(it) } }
                ?: (resources as? AutoCloseable)?.close()
            throw failure
        }
    }
    private fun applyTypedWebsiteEvents(session: VortxNativeSession, account: SessionOwnerSnapshot.Account,
                                        document: JSONObject, active: () -> Boolean) {
        NativeWebsiteProfileEdits.events(document).forEach { session.applyWebsiteProfileEdit(it) }
        session.applyWebsiteAddonEdits(NativeWebsiteAddonEdits.events(document, session.scope), beforeCommit = {
            check(active() && accountCurrent(account)) { "Native website account changed" }
        })
        document.opt("profileEdits")?.takeIf { it != JSONObject.NULL }?.let { session.applyLegacyWebsiteAggregate(it) }
    }
    private fun ownerHistoryAuthority(account: SessionOwnerSnapshot.Account, active: () -> Boolean): NativeOwnerHistoryAuthority {
        val original = captureOwnAccountAdmission(account)
        check(ownCredentials == null || original != null) { "Native account admission unavailable" }
        return object : NativeOwnerHistoryAuthority {
            override fun <T> withActive(block: () -> T): T {
                check(active() && accountCurrent(account)) { "Native account changed" }
                if (original == null) return block().also { check(active() && accountCurrent(account)) }
                var result: Result<T>? = null
                check(original { if (!active() || !accountCurrent(account)) false else { result = runCatching(block); true } }) { "Native account changed" }
                return requireNotNull(result).getOrThrow()
            }
        }
    }
    private suspend fun applyDocumentLocked(account: SessionOwnerSnapshot.Account, incomingDocument: JSONObject, isCurrent: () -> Boolean,
                                           suppliedSources: List<NativeOwnAccountSource> = emptyList(),
                                           retainedWatched: JSONObject? = null,
                                           operationCurrent: () -> Boolean = isCurrent,
                                           originalHostPreferences: ByteArray? = null,
                                           onInstalled: ((Mounted) -> Unit)? = null): Boolean {
        check(account.id !in uncertainHistoryAccounts) { "Owner history writer retirement unconfirmed" }
        check(isCurrent() && operationCurrent() && accountCurrent(account)) { "Native account changed" }
        // All callers share this transaction helper. Revoke the old authenticated baseline before
        // it can dispatch or checkpoint any native mutation, including calls outside raw sync apply.
        mounted.get()?.takeIf { it.account == account }?.clearRead()
        val operationJob = currentCoroutineContext()[Job]
        val document = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(incomingDocument))
        val parsed = VortXSyncDoc.parse(document)
        val resolved = SettingsBackup.resolveRosterForPull(document.opt("settings"),
            parsed.roster.takeIf { parsed.rosterIsLossless }, parsed.rosterModifiedSeconds, parsed.rosterIsLossless)
        val roster = checkNotNull(resolved.roster) { "Authenticated full profile roster required for native migration" }
        val owner = roster.filter { it.isOwner }.single()
        require(roster.map { it.id }.distinct().size == roster.size)
        val namespace = "account.${UUID.fromString(account.id).toString().lowercase()}"
        val scope = VortxAccountScope(namespace, owner.id)
        checkpoints.discover(namespace)?.let { require(it == scope) { "Native account owner changed" } }
        val remoteHost = document.optJSONObject("nativeHostPreferences")
        if (document.has("nativeHostPreferences")) requireNotNull(remoteHost) { "Invalid native host preferences" }
        remoteHost?.let { NativeHostPreferences.validate(scope, it) }
        val remote = document.optJSONObject("nativeSync")
        if (document.has("nativeSync")) requireNotNull(remote) { "Invalid native sync document" }
        if (remote != null) {
            require(remote.getString("scope") == namespace && remote.getString("ownerProfileId") == owner.id)
            requireNotNull(remote.optJSONObject("legacyImport")) { "Native account requires a verified legacy baseline receipt" }
        }
        // This carrier is immutable source evidence. It is deliberately not folded into the
        // historical aggregate before native reconciliation; each entry owns its own receipt.
        val websiteEvents = NativeWebsiteProfileEdits.events(document)
        val websiteAddonEvents = NativeWebsiteAddonEdits.events(document, scope)
        val legacyAggregate = document.opt("profileEdits").takeIf { value -> value != null && value != JSONObject.NULL &&
            (value !is JSONObject || value.length() > 0) }
        // The historical aggregate must never be folded by the broad legacy importer. Its narrow
        // original-baseline reducer runs after the immutable host archive has durably committed.
        // Credentials in host-only settings may be excluded from the sealed archive. Immutable
        // library/add-on/watch source values may not: stripping a nested encoded secret there
        // would bless a different descriptor or migration receipt than the authenticated input.
        val sourceFields = JSONObject()
        for (key in listOf("addons", "library", "addonOrder", "webAddonRemovals", "webProgress", "webAddonEdits"))
            if (document.has(key)) sourceFields.put(key, document.get(key))
        document.optJSONObject("vortx")?.let { original ->
            val fields = JSONObject()
            for (key in listOf("addons", "library", "byProfile", "ownerWatched", "deletedAddonsTs", "deletedAddons",
                "deletedLibraryTs", "deletedLibrary", "deletedProfiles")) if (original.has(key)) fields.put(key, original.get(key))
            sourceFields.put("vortx", fields)
        }
        NativeHostDocument.requireCredentialFree(sourceFields)
        val archive = NativeHostDocument.archive(document)
        nativeMigrationSidecars.forEach(archive.getJSONObject("document")::remove)
        val watchlists = nativeLegacyWatchlists(document, roster.map { it.id }.toSet())
        archive.getJSONObject("document").put("nativeWatchlistMigrationPending", watchlists.pending)
        val materialDocument = nativeMigrationSourceDocument(archive.getJSONObject("document")).also { it.remove("profileEdits") }
        val old = mounted.get()
        val capturedRead = old?.takeIf { it.account == account && it.session.scope == scope && !it.session.requiresRecovery() }?.session?.read()
        val capturedUpdate = capturedRead?.let { old!!.session.updates.value }
        val retained = capturedRead?.state
            ?: checkpoints.read(scope)?.let(scope::validateSnapshot)
        // Bound the complete immutable source union before installing even the base merge. A
        // pruned cloud queue never discards a local unacknowledged historical source.
        NativeWebsiteAddonEdits.union(scope, retained?.optJSONObject("websiteAddonEditPending") ?: NativeWebsiteAddonEdits.emptyPending(), websiteAddonEvents)
        val native = remote ?: retained?.optJSONObject("nativeSync")
        val hasNative = native != null
        val preflight = checkpoints.readPreflight(namespace)?.also { require(it.scope == scope) { "Native setup owner changed" } }
        val priorArchive = retainedWatched ?: retained?.optJSONObject("hostDocument") ?: preflight?.archive?.getJSONObject("document")
        val legacyOwn = roster.filter { it.usesOwnAccount }.map { it.id }.toSet()
        val recovered = if (!hasNative && preflight != null) recoverPreflightSources(account, preflight) else emptyList()
        val sources = (suppliedSources + recovered.filterNot { recoveredSource -> suppliedSources.any { it.profileID == recoveredSource.profileID } })
            .filter { it.profileID in legacyOwn }
        sources.forEach { require(it.accountID == namespace) }
        val retainedSources = priorArchive?.optJSONObject("authenticatedOwnAccountSources")
        val sourceBytes = retainedSources?.keys()?.asSequence()?.associateWith {
            java.util.Base64.getDecoder().decode(retainedSources.getJSONObject(it).getString("sourceDocumentBase64"))
        }.orEmpty()
        val ownBaseline = if (legacyOwn.isNotEmpty() && native != null &&
            maxOf(native.optInt("schemaVersion"), retained?.optJSONObject("nativeSync")?.optInt("schemaVersion") ?: 0) >= 3)
            NativeOwnAccountBaseline.validate(bindings, scope, native, sourceBytes, activeBindings = false,
                priorDocument = retained?.optJSONObject("nativeSync").takeIf { remote != null },
                retainedSourceUIDs = retainedSources?.keys()?.asSequence()?.associateWith {
                    retainedSources.getJSONObject(it).getString("verifiedStreamingUid")
                }.orEmpty()) else null
        val unavailable = legacyOwn - sources.map { it.profileID }.toSet() - ownBaseline?.profileIDs().orEmpty()
        val pendingOverlays = legacyOwn.filter { id ->
            if (id in unavailable) true else sources.singleOrNull { it.profileID == id }?.let { source ->
                runCatching { source.requireOverlayUnchanged(materialDocument) }.isFailure
            } ?: runCatching { requireNotNull(ownBaseline).requireOverlayUnchanged(materialDocument, id) }.isFailure
        }.toSet()
        // Current authenticated legacy material is reconciled against the kernel's acknowledged
        // baseline. Unsupported/missing causal evidence rejects the complete candidate transaction.
        val migrationCurrent = {
            operationJob?.isActive != false && isCurrent() && operationCurrent() && accountCurrent(account) &&
                (old == null || mounted.get() === old)
                && (capturedUpdate == null || old!!.session.updates.value == capturedUpdate)
        }
        val watched = watchedProducer.prepare(scope, materialDocument, roster, sources,
            retainedStorage = NativeWatchedMigrationStorage.read(priorArchive), isCurrent = migrationCurrent)
        val preparation = if (unavailable.isNotEmpty() || !watched.isComplete) null else try {
            prepareNativeLegacyMaterial(materialDocument, roster, resolved.modifiedSeconds,
                sources, ownBaseline, scope, pendingOverlays, watchedMigration = watched)
        } catch (error: LegacyReconciliationRequired) {
            // A whole-account stop names its reconciliation reason, scrubbed of source values.
            DiagnosticsLog.log("native-profiles", "restore result=failed stage=legacy_preparation detail=${scrubbedLegacyReason(error.reason)}")
            throw error
        }
        // Held units (issue #262) stay only in the retained original document; name them without values.
        preparation?.let { prepared ->
            val held = if (prepared.held.isEmpty()) "" else " held=${prepared.held.size} held_units=${nativeLegacyHeldSummary(prepared.held)}"
            DiagnosticsLog.log("native-profiles", "prepare result=ready pending_membership_receipts=${prepared.pendingMembershipReceipts.length()}$held")
        }
        val material = preparation?.material
        // Retain exact unresolved source receipts in the same sealed candidate checkpoint as the
        // accepted material. Never turn a historical receipt into an install, removal or clock.
        archive.getJSONObject("document").put("nativeLegacyMembershipPending", nativeLegacyMembershipJournal(scope,
            priorArchive?.optJSONObject("nativeLegacyMembershipPending"), preparation?.pendingMembershipReceipts ?: JSONArray(),
            knownProfileIDs = roster.map { it.id }.toSet() +
                retained?.optJSONObject("roster")?.optJSONObject("profiles")?.keys()?.asSequence()?.toSet().orEmpty() +
                remote?.optJSONObject("profiles")?.keys()?.asSequence()?.toSet().orEmpty()))
        // Full descriptors may contain encoded custom strings. Retain exact typed input only if it
        // is credential-free; sanitizing it would silently change the shared kernel's receipt input.
        material?.let(NativeHostDocument::requireCredentialFree)
        val hasReceipt = remote?.optJSONObject("legacyImport") != null || retained?.optJSONObject("nativeSync")?.optJSONObject("legacyImport") != null
        val replay = material?.let { JSONObject().put("type", if (hasReceipt) "reconcile_legacy_sync" else "import_legacy_sync")
            .put("scope", namespace).put("ownerProfileId", owner.id).put("material", it).also { action ->
                if (hasReceipt) action.put("baselineMaterial", retained?.optJSONObject("legacyImportMaterial") ?: it)
            } }
        val syncActions = listOfNotNull(remote?.let { JSONObject().put("type", "merge_native_sync").put("document", it) }, replay).toMutableList()
        if (!hasNative && material != null) sources.forEach { source -> source.credentialTransactionID?.let { transaction ->
            val expected = NativeAccountBinding.parse(JSONObject().put("account", JSONObject().put("kind", "own").put("value", source.verifiedUID))
                .put("revision", 0).put("transactionId", JSONObject.NULL))
            syncActions += NativeStreamingAccountLink.action(scope, source.profileID, expected, transaction, JSONObject().put("kind", "own")
                .put("carrier", nativePreparedOwnAccountCarrier(source, roster.single { it.id == source.profileID }, JSONObject(),
                    watchedMigration = watched, preparedMaterial = material)))
        } }
        val archivedDocument = archive.getJSONObject("document")
        priorArchive?.optJSONObject("nativeOwnAccountCandidates")?.let {
            archivedDocument.put("nativeOwnAccountCandidates", validateNativeOwnAccountCandidates(it))
        }
        mergeNativeWatchedArchive(scope, priorArchive, archivedDocument, watched.storage())
        val archivedSources = retainedSources?.let { JSONObject(it.toString()) } ?: JSONObject()
        sources.forEach { source -> archivedSources.put(source.profileID, JSONObject().put("verifiedStreamingUid", source.verifiedUID)
            .put("sourceDocumentBase64", source.archiveBase64())) }
        if (archivedSources.length() > 0) archivedDocument.put("authenticatedOwnAccountSources", validateNativeOwnAccountArchive(archivedSources))
        archivedDocument.put("nativeOwnAccountPending", JSONObject().also { pending -> pendingOverlays.forEach { id ->
            val overlay = nativeOwnAccountOverlay(materialDocument, id)
            NativeHostDocument.requireCredentialFree(overlay)
            val record = JSONObject().put("reason", if (id in unavailable) "verified-source-required" else "overlay-attribution-required")
                .put("profileOverlayBase64", java.util.Base64.getEncoder().encodeToString(overlay.toString().toByteArray(Charsets.UTF_8)))
            // A digest is not a UID: two empty accounts legitimately hash to the same envelope.
            // Only a kernel-validated historical tuple may attribute this legacy UUID slice.
            val priorPending = retained?.optJSONObject("hostDocument")?.optJSONObject("nativeOwnAccountPending")?.optJSONObject(id)
            // A network-only B import did not attest to A's slice. Do not upgrade its unknown
            // attribution merely because B is now present in the kernel's baseline on restart.
            val proof = ownBaseline?.takeIf { id in it.profileIDs() }?.proof(id)
            val attributed = priorPending?.takeIf { it.has("verifiedStreamingUid") && it.has("sourceDocumentSha256") }
                ?: proof?.takeIf { it.has("profileOverlaySha256") && priorPending == null }
            attributed?.let { proof ->
                record.put("verifiedStreamingUid", proof.getString("verifiedStreamingUid"))
                    .put("sourceDocumentSha256", proof.getString("sourceDocumentSha256"))
            }
            pending.put(id, record)
        } })
        // Admission applies to the complete retained host, not just its compact watched journal.
        nativeWatchedDocumentSnapshot(archivedDocument)
        if (!hasNative && material == null) {
            // Preserve setup across a restart, but do not create a native runtime, publish a
            // checkpoint locator, acknowledge the legacy receipt, or drop unresolved originals.
            val next = NativeMigrationPreflight.create(scope, archive, sources, preflight?.candidates)
            withNativeOwnAccountSources(sources) { withAccountAdmission(account, migrationCurrent) {
                checkpoints.commitPreflight(next, preflight)
                pendingImport = PendingImport(UUID.fromString(next.id), account, archivedDocument, roster, isCurrent, sources.toList(), next)
            } }
            changes.value += 1
            return false
        }
        val verifySources: (VortxNativeRuntime) -> Unit = { candidate ->
            operationJob?.ensureActive()
            check(isCurrent() && accountCurrent(account)) { "Native migration changed before checkpoint admission" }
            if (!hasNative) sources.forEach { source -> source.credentialTransactionID?.let { transaction ->
                val state = JSONObject(candidate.stateJson())
                val selected = NativeAccountBinding.read(state, source.profileID)
                check(selected.kind == "own" && selected.streamingUID == source.verifiedUID && selected.transactionID == transaction) {
                    "Native imported credential selection readback failed"
                }
                val active = NativeOwnAccountBaseline.validate(bindings, scope, state.getJSONObject("nativeSync"))
                check(NativeHostPreferences.equal(active.proof(source.profileID), source.proof())) { "Native imported source readback failed" }
            } }
        }
        val baselineHost = NativeHostProfiles.fromDocument(archive.getJSONObject("document"), roster, resolved.modifiedSeconds)
        if (old != null && old.account == account && old.session.scope == scope && !old.session.requiresRecovery()) {
            val read = old.session.owned(checkNotNull(capturedRead).owner) { old.session.read().also {
                check(NativeHostPreferences.equal(it.state.optJSONObject("hostDocument"), capturedRead.state.optJSONObject("hostDocument"))) {
                    "Native migration archive changed during metadata capture"
                }
            } }
            val host = read.state.getJSONObject("hostProfilePreferences")
            val nextHost = if ((resolved.modifiedSeconds ?: 0.0) > host.optDouble("modifiedSeconds", 0.0)) {
                baselineHost
            } else host
            old.session.owned(read.owner) { withNativeOwnAccountSources(sources) {
                withAccountAdmission(account, migrationCurrent) { check(withMountedSession(old.session, account) {
                    old.session.withRawHostMerge(originalHostPreferences) {
                        old.session.dispatch(syncActions, read.owner, nextHost, notifyMutation = false, hostArchive = archive,
                            remoteHostPreferences = remoteHost, baselineHostProfiles = baselineHost, verifyCandidate = verifySources,
                            beforeCommit = { operationJob?.ensureActive(); check(migrationCurrent()) { "Native migration changed before commit" } },
                            legacyWatchlists = watchlists.profiles)
                    }
                    reportLegacyReconciliation(old.session, stage = "sync")
                    true
                }) { "Native account changed" } }
            } }
            websiteEvents.forEach { event -> old.session.applyWebsiteProfileEdit(event) }
            old.session.owned(old.session.read().owner) {
                withAccountAdmission(account, isCurrent) { check(withMountedSession(old.session, account) {
                    old.session.applyWebsiteAddonEdits(websiteAddonEvents, beforeCommit = {
                        operationJob?.ensureActive(); check(isCurrent() && operationCurrent() && accountCurrent(account)) { "Native website add-on account changed" }
                    })
                    true
                }) { "Native account changed" } }
            }
            legacyAggregate?.let { aggregate -> old.session.applyLegacyWebsiteAggregate(aggregate) }
            check(isCurrent()) { "Native account changed" }
            project(old.session)
            check(isCurrent() && accountCurrent(account) && mounted.get() === old) { "Native account changed" }
            pendingImport = null
            return true
        }
        check(migrationCurrent()) { "Native migration changed" }
        retire()
        // Close is deferred out of the auth lock to avoid lock inversion, but a replacement writer
        // must join every retired transaction before reading or replacing the same account file.
        while (true) { val prior = retired.peek() ?: break; prior.close(); retired.remove(prior) }
        val resources = transport()
        val hostProfiles = baselineHost
        // The captured setup target was admitted before intentional retirement. The coroutine and
        // authenticated account fences remain live at the actual commit; the pending-ID predicate
        // cannot be reused after we deliberately cleared that setup record ourselves.
        val candidate = try { withNativeOwnAccountSources(sources) { withAccountAdmission(account, isCurrent) {
            operationJob?.ensureActive()
            VortxNativeSession.open(scope, owner.name, bindings, checkpoints, resources,
            bootstrapActions = syncActions, initialHostProfiles = hostProfiles, initialHostArchive = archive,
            initialHostPreferences = remoteHost, initialLegacyWatchlists = watchlists.profiles,
            initialRawHostPreferences = originalHostPreferences,
            verifyCandidate = verifySources, onMutation = { onMutation(account) }, beforeOwnerChange = onAuthorityChanged,
            onProgressMutation = { onProgressMutation(account) }, ownerHistoryBindings = historyBindings,
            ownerHistoryAuthority = ownerHistoryAuthority(account) { accountCurrent(account) }) { isCurrent() && accountCurrent(account) } } } }
            catch (error: Throwable) {
                (resources as? AutoCloseable)?.close()
                // Cancellation did not consume the durable setup source. Restore its setup-only
                // presentation when the same authenticated account is still current.
                if (preflight != null && mounted.get() == null && isCurrent() && accountCurrent(account))
                    runCatching { restorePreflight(account, preflight, isCurrent) }
                throw error
            }
        reportLegacyReconciliation(candidate, stage = "restore")
        try { websiteEvents.forEach { event -> candidate.applyWebsiteProfileEdit(event) } }
        catch (error: Throwable) { retireUnpublished(account, candidate); throw error }
        try { candidate.owned(candidate.read().owner) {
            withAccountAdmission(account, isCurrent) { candidate.applyWebsiteAddonEdits(websiteAddonEvents, beforeCommit = {
                operationJob?.ensureActive(); check(isCurrent() && accountCurrent(account)) { "Native website add-on account changed" }
            }) }
        } }
        catch (error: Throwable) { retireUnpublished(account, candidate); throw error }
        try { legacyAggregate?.let { aggregate -> candidate.applyLegacyWebsiteAggregate(aggregate) } }
        catch (error: Throwable) { retireUnpublished(account, candidate); throw error }
        try { checkpoints.remember(scope) }
        catch (error: Throwable) { retireUnpublished(account, candidate); throw error }
        return publish(account, candidate, isCurrent, onInstalled)
    }

    /** A held old-format delta is reported, never fatal: native sync keeps landing (Apple 0.5.0 Beta 6). */
    private fun reportLegacyReconciliation(session: VortxNativeSession, stage: String) {
        session.heldLegacyReconciliation?.let { reason ->
            android.util.Log.i("VortXNative", "legacy_reconcile result=held stage=$stage reason=$reason")
        }
    }

    private fun recoverPreflightSources(account: SessionOwnerSnapshot.Account, retained: NativeMigrationPreflight): List<NativeOwnAccountSource> {
        val credentials = ownCredentials ?: return emptyList()
        val admission = captureOwnAccountAdmission(account) ?: return emptyList()
        val candidates = retained.candidates
        return (0 until candidates.length()).mapNotNull { index ->
            val candidate = candidates.getJSONObject(index)
            val capture = credentials.capture(account, candidate.getString("profileId"), candidate.getString("verifiedStreamingUid"),
                candidate.opt("transactionId") as? String, admission) ?: return@mapNotNull null
            NativeOwnAccountSource.fromRetained(capture, java.util.Base64.getDecoder().decode(candidate.getString("sourceDocumentBase64")))
        }
    }

    private fun restorePreflight(account: SessionOwnerSnapshot.Account, retained: NativeMigrationPreflight, isCurrent: () -> Boolean) {
        val document = retained.archive.getJSONObject("document")
        val parsed = VortXSyncDoc.parse(document)
        val resolved = SettingsBackup.resolveRosterForPull(document.opt("settings"), parsed.roster.takeIf { parsed.rosterIsLossless },
            parsed.rosterModifiedSeconds, parsed.rosterIsLossless)
        val roster = checkNotNull(resolved.roster)
        require(roster.single { it.isOwner }.id == retained.scope.ownerProfileID)
        val sources = recoverPreflightSources(account, retained)
        withNativeOwnAccountSources(sources) { withAccountAdmission(account, isCurrent) {
            pendingImport = PendingImport(UUID.fromString(retained.id), account, document, roster, isCurrent, sources, retained)
        } }
    }

    /** Session -> credential journal (when present) -> auth -> mounted lifecycle. */
    private fun <T> withAccountAdmission(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean, action: () -> T): T {
        val admission = captureOwnAccountAdmission(account)
        // Legacy deterministic gateway fixtures do not inject an auth monitor. Production always
        // injects it when credential support is enabled, and must never silently lose that fence.
        check(ownCredentials == null || admission != null) { "Native account admission unavailable" }
        if (admission == null) { check(isCurrent() && accountCurrent(account)); return action() }
        var result: Result<T>? = null
        check(admission { if (!isCurrent() || !accountCurrent(account)) false else { result = runCatching(action); true } }) {
            "Native account changed"
        }
        return requireNotNull(result).getOrThrow()
    }

    override fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport? {
        val current = mounted.get()?.takeIf { it.account == account && accountCurrent(account) } ?: return null
        val read = current.session.read()
        return current.session.owned(read.owner) {
            exportDocument(current, read)
        }
    }

    private fun exportDocument(current: Mounted, read: VortxNativeRead): NativeAccountExport {
        // Active selection is device-local and intentionally absent from this carrier.
        val profiles = NativeProfileAccess.projection(read).profiles
        val host = read.state.getJSONObject("hostProfilePreferences")
        return NativeAccountExport(read.state.getJSONObject("nativeSync"), profiles, host.optDouble("modifiedSeconds", 0.0), NativeHostProfiles.roster(host, profiles),
            read.state.getBoolean("hostProfileSyncPending"), read.state.getJSONObject("nativeHostPreferenceState").getJSONObject("document"),
            read.state.optJSONObject("hostDocument")?.opt("settings"), current.session.rawAccount(),
            current.sourceProjection(), current.session.rawHostPreferences())
    }

    /** No Session read occurs in the scalar predicate. All local receipt work starts outside the
     * manager monitor, takes Session first, then this original auth admission and lifecycle fence. */
    private inner class UploadOrigin(val account: SessionOwnerSnapshot.Account,
        private val admission: (() -> Boolean) -> Boolean, private val active: () -> Boolean) : NativeAccountUploadCurrency.Origin {
        val issuer = this@NativeAccountCoordinator
        fun withAuthentication(body: () -> Boolean): Boolean = admission {
            active() && accountCurrent(account) && body()
        }
        override fun isCurrent() = withAuthentication { true }
    }

    private inner class UploadCurrency(val origin: UploadOrigin, val installation: Mounted?) : NativeAccountUploadCurrency {
        val account get() = origin.account
        val issuer get() = origin.issuer
        fun withAuthentication(body: () -> Boolean): Boolean = origin.withAuthentication(body)
        fun successor(next: Mounted?): UploadCurrency = UploadCurrency(origin, next)
        override fun isCurrent(): Boolean = origin.withAuthentication {
            synchronized(lifecycleLock) { mounted.get() === installation }
        }
        override fun <T> withCurrentSession(action: () -> T): T? {
            fun admitted(): T? {
                var result: Result<T>? = null
                if (!withAuthentication { synchronized(lifecycleLock) {
                    if (mounted.get() !== installation) false else { result = runCatching(action); true }
                } }) return null
                return requireNotNull(result).getOrThrow()
            }
            val session = installation?.session ?: return admitted()
            return synchronized(session) { if (session.requiresRecovery()) null else admitted() }
        }
    }

    override fun captureUploadOrigin(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): NativeAccountUploadCurrency.Origin? {
        val original = captureOwnAccountAdmission(account) ?: return null
        return UploadOrigin(account, original, isCurrent).takeIf { it.isCurrent() }
    }

    override suspend fun prepareUploadSeed(account: SessionOwnerSnapshot.Account, original: NativeAccountUploadCurrency.Origin, isCurrent: () -> Boolean):
        Pair<JSONObject, NativeAccountUploadCurrency>? {
        val origin = original as? UploadOrigin ?: return null
        if (origin.issuer !== this || origin.account != account || !origin.isCurrent()) return null
        val before = mounted.get()
        if (before != null && before.account != account) return null
        val captured = UploadCurrency(origin, before)
        if (captured.withCurrentSession { isCurrent() } != true) return null
        val produced = AtomicReference<Mounted?>(null)
        fun current(): Boolean = captured.withAuthentication { isCurrent() && synchronized(lifecycleLock) {
            mounted.get() === (produced.get() ?: captured.installation)
        } }
        // prepare may reopen a genuine bootstrap checkpoint. Only its publication CAS may name
        // that replacement; an unrelated same-account mount after an await is never adopted.
        val document = prepareEmptyAccount(account, ::current) { next -> check(produced.compareAndSet(null, next)) }
        if (!current()) return null
        val currency = captured.successor(produced.get() ?: captured.installation)
        return if (currency.withCurrentSession { current() } == true) document to currency else null
    }

    override suspend fun applyUploadSeed(account: SessionOwnerSnapshot.Account, document: JSONObject,
        original: NativeAccountUploadCurrency, isCurrent: () -> Boolean): NativeAccountUploadCurrency? {
        val captured = original as? UploadCurrency ?: return null
        if (captured.issuer !== this || captured.account != account || captured.withCurrentSession { isCurrent() } != true) return null
        val produced = AtomicReference<Mounted?>(null)
        fun current(): Boolean = captured.withAuthentication { isCurrent() && synchronized(lifecycleLock) {
            mounted.get() === (produced.get() ?: captured.installation)
        } }
        val applied = mutex.withLock {
            require(!document.has(NativeOwnerHistoryAccount.ARCHIVE) && document.optJSONObject("nativeSync")?.optInt("schemaVersion") != 6)
            require(nativeMigrationSidecars.none(document::has) && !document.has("websiteAddonEditPending"))
            if (!current()) false else applyDocumentLocked(account, document, ::current,
                onInstalled = { next -> check(produced.compareAndSet(null, next)) })
        }
        if (!applied || !current()) return null
        val installed = produced.get() ?: captured.installation ?: return null
        // Reuse ORIGINAL auth, cancellation and operation observations; no new capture after PUT.
        return captured.successor(installed).takeIf { it.withCurrentSession { current() } == true }
    }

    private class CapturedHostAcknowledgment(
        private val session: VortxNativeSession, raw: ByteArray,
        private val originalAdmission: (() -> Boolean) -> Boolean,
    ) : NativeHostUploadAcknowledgment {
        private val lock = Any(); private var active = true; private var armed = false
        private val sent = raw.copyOf()
        fun arm() = synchronized(lock) { check(active && !armed); armed = true }
        private fun usable() = synchronized(lock) { active && armed }
        override fun isCurrent(): Boolean = usable() && originalAdmission { usable() }
        override fun acknowledge(isAcceptedCurrent: () -> Boolean): Boolean {
            val raw = synchronized(lock) { if (!active || !armed) return false else sent.copyOf() }
            return try { synchronized(session) {
                originalAdmission {
                    usable() && isAcceptedCurrent() && !session.requiresRecovery() &&
                        session.acknowledgeRawHostDocument(raw) { usable() && isAcceptedCurrent() }
                }
            } } finally { raw.fill(0) }
        }
        override fun close() = synchronized(lock) { active = false; sent.fill(0) }
    }

    override fun <T> withUploadExport(account: SessionOwnerSnapshot.Account, source: NativeAccountReadCapture,
        originalRaw: ByteArray, original: NativeAccountUploadCurrency.Origin, isCurrent: () -> Boolean,
        action: (NativeAccountExport, NativeAccountMountToken?, ((JSONObject) -> ByteArray)?, NativeHostUploadAcknowledgment?, NativeAccountUploadCurrency) -> T): T? {
        val current = mounted.get()?.takeIf { it.account == account && accountCurrent(account) } ?: return null
        val origin = original as? UploadOrigin ?: return null
        if (origin.issuer !== this || origin.account != account || !origin.isCurrent()) return null
        val currency = UploadCurrency(origin, current)
        // Scalar admission deliberately has no Session calls. Frozen wire candidates retain this
        // original auth/mount fence after their capture checkpoint has legitimately advanced.
        val originalAdmission: (() -> Boolean) -> Boolean = { body -> origin.withAuthentication {
            if (!isCurrent() || !accountCurrent(account)) false else synchronized(lifecycleLock) {
                mounted.get() === current && body()
            }
        } }
        return current.session.withCompleteAccountExportRead(current.readIdentity() != null) { read ->
            var result: Result<T>? = null
            check(originalAdmission {
                result = runCatching {
                    val exported = exportDocument(current, read)
                    val mount = NativeAccountMountToken(current, current.session.updates.value)
                    if (exported.rawAccount != null) action(exported, mount, null, null, currency) // Separate typed path.
                    else {
                        val retained = checkNotNull(current.readIdentity()) { "Authenticated generic read unavailable" }
                        check(retained.sameObservation(source)) { "Original authenticated upload read changed" }
                        current.withRead(retained) { raw, projection ->
                            check(raw.contentEquals(originalRaw)) { "Authenticated upload bytes changed" }
                            current.session.withRawHostExport(read.owner, raw, projection, {
                                isCurrent() && accountCurrent(account) && mounted.get() === current && current.readIdentity() === retained
                            }) { snapshot ->
                                val sent = current.session.rawHostPreferences()
                                val ack = CapturedHostAcknowledgment(current.session, sent, originalAdmission)
                                sent.fill(0)
                                var transferred = false
                                try {
                                    action(exported, mount, { providers ->
                                        val candidate = NativePlaylistAccountComposer.composeExport(raw, projection, snapshot, providers)
                                        try { ack.arm(); candidate } catch (failure: Throwable) { candidate.fill(0); throw failure }
                                    }, ack, currency).also { transferred = true }
                                } finally { if (!transferred) ack.close() }
                            }
                        }
                    }
                }; true
            }) { "Original upload account or mount retired" }
            check(originalAdmission { true }) { "Original upload account or mount retired" }
            requireNotNull(result).getOrThrow()
        }
    }

    override fun recordGlobalPreferences(account: SessionOwnerSnapshot.Account, changes: JSONObject,
        original: NativeAccountUploadCurrency.Origin): Boolean {
        val origin = original as? UploadOrigin ?: return false
        if (origin.issuer !== this || origin.account != account) return false
        val current = mounted.get()?.takeIf { it.account == account && accountCurrent(account) } ?: return false
        val currency = UploadCurrency(origin, current)
        return currency.withCurrentSession {
            current.session.dispatch(emptyList(), notifyMutation = false, globalChanges = changes,
                beforeCommit = { check(currency.isCurrent()) { "Original upload authentication or mount retired" } })
            currency.isCurrent()
        } == true
    }
    override fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean {
        val current = mounted.get()?.takeIf { it.account == account && accountCurrent(account) } ?: return false
        current.session.dispatch(emptyList(), notifyMutation = false, acknowledgeHostPreferences = document)
        return mounted.get() === current && accountCurrent(account)
    }
}
