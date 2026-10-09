package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.NativeAccountGateway
import com.vortx.android.sync.NativeAccountExport
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.sync.VortXSyncDoc
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.ConcurrentLinkedQueue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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
    private val onMutation: () -> Unit = {},
    private val onRetired: () -> Unit = {},
    private val ownCredentials: NativeOwnAccountCredentials? = null,
    private val ownProducer: NativeOwnAccountProducer = NativeOwnAccountProducer(),
    private val watchedProducer: NativeWatchedMigrationProducer = NativeWatchedMigrationProducer(),
    private val captureOwnAccountAdmission: (SessionOwnerSnapshot.Account) -> (((() -> Boolean) -> Boolean)?) = { null },
    private val onAuthorityChanged: () -> Unit = {},
) : NativeAccountGateway {
    private data class Mounted(val account: SessionOwnerSnapshot.Account, val session: VortxNativeSession)
    private val mounted = AtomicReference<Mounted?>()
    private val retired = ConcurrentLinkedQueue<VortxNativeSession>()
    private val lifecycleLock = Any()
    private val mutex = Mutex()
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
    val changes = MutableStateFlow(0L)

    internal data class MigrationStatus(val pendingRows: Int, val setupRequired: Boolean, val watchlistPending: Int = 0)
    internal class MigrationTarget internal constructor(internal val account: SessionOwnerSnapshot.Account,
        internal val scope: VortxAccountScope, internal val document: JSONObject, internal val session: VortxNativeSession?,
        internal val owner: VortxNativeOwner?, internal val update: Long?, internal val pendingID: UUID?)
    fun migrationStatus(): MigrationStatus? {
        mounted.get()?.takeIf { accountCurrent(it.account) }?.let { current ->
            val count = current.session.read().state.optJSONObject("hostDocument")?.optJSONArray("nativeWatchedMigrationPending")?.length() ?: 0
            val candidates = current.session.read().state.optJSONObject("hostDocument")?.optJSONObject("nativeOwnAccountCandidates")?.length() ?: 0
            val watchlists = current.session.read().state.optJSONObject("hostDocument")?.optJSONArray("nativeWatchlistMigrationPending")?.length() ?: 0
            return MigrationStatus(count, false, watchlists).takeIf { count > 0 || candidates > 0 || watchlists > 0 }
        }
        val pending = pendingImport?.takeIf { it.isCurrent() && accountCurrent(it.account) } ?: return null
        return MigrationStatus(pending.document.optJSONArray("nativeWatchedMigrationPending")?.length() ?: 0, true,
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
        val history = watchedProducer.retryPending(target.scope, target.document.optJSONArray("nativeWatchedMigrationPending") ?: JSONArray(),
            target.document.optJSONArray("nativeWatchedMigrationEvidence"), current)
        val retained = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(target.document))
            .put("nativeWatchedMigrationEvidence", history.archive()).put("nativeWatchedMigrationPending", history.pending())
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
        if (applied) onMutation()
        applied
    }
    fun session(): VortxNativeSession = checkNotNull(mounted.get()) { "Native account has not completed authenticated bootstrap" }
        .also { check(accountCurrent(it.account)) { "Native account changed" } }.session
    /** Captures only a still-mounted identity; callers perform account authentication outside this lock. */
    internal fun accountFor(session: VortxNativeSession): SessionOwnerSnapshot.Account? = synchronized(lifecycleLock) {
        mounted.get()?.takeIf { it.session === session }?.account
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
            onAuthorityChanged()
            mounted.getAndSet(null).also { if (it != null) retired.add(it.session) }
        }
        changes.value += 1
        onRetired()
        if (old != null) {
            dispose { old.session.close(); retired.remove(old.session) }
        }
    }

    override suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): Boolean = mutex.withLock {
        check(isCurrent() && accountCurrent(account)) { "Native account changed" }
        mounted.get()?.takeIf { it.account == account && !it.session.requiresRecovery() }?.let { return@withLock true }
        retire()
        while (true) { val prior = retired.poll() ?: break; prior.close() }
        val namespace = "account.${UUID.fromString(account.id).toString().lowercase()}"
        val scope = checkpoints.discover(namespace) ?: run {
            val retained = checkpoints.readPreflight(namespace) ?: return@withLock false
            if (checkpoints.read(retained.scope) != null) retained.scope // State committed before locator publication.
            else {
                restorePreflight(account, retained, isCurrent)
                changes.value += 1
                return@withLock false
            }
        }
        val state = scope.validateSnapshot(checkNotNull(checkpoints.read(scope)))
        state.optJSONObject("hostDocument")?.optJSONObject("nativeLegacyMembershipPending")?.let { journal ->
            nativeLegacyMembershipJournal(scope, journal, JSONArray(),
                state.getJSONObject("roster").getJSONObject("profiles").keys().asSequence().toSet())
        }
        requireNotNull(state.getJSONObject("nativeSync").optJSONObject("legacyImport")) { "Native account requires a verified legacy baseline receipt" }
        val ownerName = state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getString("name")
        val resources = transport()
        val candidate = try { VortxNativeSession.open(scope, ownerName, bindings, checkpoints, resources,
            onMutation = onMutation, beforeOwnerChange = onAuthorityChanged) { isCurrent() && accountCurrent(account) } }
            catch (error: Throwable) { (resources as? AutoCloseable)?.close(); throw error }
        try { withAccountAdmission(account, isCurrent) { checkpoints.remember(scope) } }
        catch (error: Throwable) { candidate.close(); throw error }
        publish(account, candidate, isCurrent)
    }

    override suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): JSONObject {
        if (reopenCheckpoint(account, isCurrent)) {
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
            check(mutex.withLock { applyDocumentLocked(account, baseline, isCurrent) })
            return prepareEmptyAccount(account, isCurrent)
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

    private suspend fun publish(account: SessionOwnerSnapshot.Account, candidate: VortxNativeSession, isCurrent: () -> Boolean): Boolean {
        try { currentCoroutineContext().ensureActive() }
        catch (error: Throwable) { candidate.close(); throw error }
        val next = Mounted(account, candidate)
        // Authentication may take its own lock; never invoke it while holding lifecycleLock.
        val current = isCurrent() && accountCurrent(account)
        val installed = current && synchronized(lifecycleLock) { onAuthorityChanged(); mounted.compareAndSet(null, next) }
        if (!installed) {
            candidate.close(); error("Native account changed")
        }
        try {
            project(candidate)
            check(isCurrent() && accountCurrent(account) && mounted.get() === next) { "Native account changed" }
            changes.value += 1
            return true
        } catch (error: Throwable) {
            val removed = synchronized(lifecycleLock) { mounted.compareAndSet(next, null) }
            if (removed) candidate.close()
            throw error
        }
    }

    override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean = mutex.withLock {
        require(nativeMigrationSidecars.none(document::has) && !document.has("websiteAddonEditPending")) { "Device-local migration evidence is not an authenticated cloud source" }
        applyDocumentLocked(account, document, isCurrent)
    }
    private suspend fun applyDocumentLocked(account: SessionOwnerSnapshot.Account, incomingDocument: JSONObject, isCurrent: () -> Boolean,
                                           suppliedSources: List<NativeOwnAccountSource> = emptyList(),
                                           retainedWatched: JSONObject? = null,
                                           operationCurrent: () -> Boolean = isCurrent): Boolean {
        check(isCurrent() && operationCurrent() && accountCurrent(account)) { "Native account changed" }
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
            priorArchive?.optJSONArray("nativeWatchedMigrationEvidence"), migrationCurrent)
        val preparation = if (unavailable.isNotEmpty() || !watched.isComplete) null else prepareNativeLegacyMaterial(materialDocument, roster, resolved.modifiedSeconds,
            sources, ownBaseline, scope, pendingOverlays, watchedMigration = watched)
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
        mergeNativeWatchedArchive(scope, priorArchive, archivedDocument, watched.archive(), watched.pending())
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
                    old.session.dispatch(syncActions, read.owner, nextHost, notifyMutation = false, hostArchive = archive,
                        remoteHostPreferences = remoteHost, baselineHostProfiles = baselineHost, verifyCandidate = verifySources,
                        beforeCommit = { operationJob?.ensureActive(); check(migrationCurrent()) { "Native migration changed before commit" } },
                        legacyWatchlists = watchlists.profiles)
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
        while (true) { val prior = retired.poll() ?: break; prior.close() }
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
            verifyCandidate = verifySources, onMutation = onMutation, beforeOwnerChange = onAuthorityChanged) { isCurrent() && accountCurrent(account) } } } }
            catch (error: Throwable) {
                (resources as? AutoCloseable)?.close()
                // Cancellation did not consume the durable setup source. Restore its setup-only
                // presentation when the same authenticated account is still current.
                if (preflight != null && mounted.get() == null && isCurrent() && accountCurrent(account))
                    runCatching { restorePreflight(account, preflight, isCurrent) }
                throw error
            }
        try { websiteEvents.forEach { event -> candidate.applyWebsiteProfileEdit(event) } }
        catch (error: Throwable) { candidate.close(); throw error }
        try { candidate.owned(candidate.read().owner) {
            withAccountAdmission(account, isCurrent) { candidate.applyWebsiteAddonEdits(websiteAddonEvents, beforeCommit = {
                operationJob?.ensureActive(); check(isCurrent() && accountCurrent(account)) { "Native website add-on account changed" }
            }) }
        } }
        catch (error: Throwable) { candidate.close(); throw error }
        try { legacyAggregate?.let { aggregate -> candidate.applyLegacyWebsiteAggregate(aggregate) } }
        catch (error: Throwable) { candidate.close(); throw error }
        try { checkpoints.remember(scope) }
        catch (error: Throwable) { candidate.close(); throw error }
        return publish(account, candidate, isCurrent)
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
            // Active selection is device-local and intentionally absent from this carrier.
            val profiles = NativeProfileAccess.projection(read).profiles
            val host = read.state.getJSONObject("hostProfilePreferences")
            NativeAccountExport(read.state.getJSONObject("nativeSync"), profiles, host.optDouble("modifiedSeconds", 0.0), NativeHostProfiles.roster(host, profiles),
                read.state.getBoolean("hostProfileSyncPending"), read.state.getJSONObject("nativeHostPreferenceState").getJSONObject("document"),
                read.state.optJSONObject("hostDocument")?.opt("settings"))
        }
    }

    override fun recordGlobalPreferences(account: SessionOwnerSnapshot.Account, changes: JSONObject): Boolean {
        val current = mounted.get()?.takeIf { it.account == account && accountCurrent(account) } ?: return false
        current.session.dispatch(emptyList(), notifyMutation = false, globalChanges = changes)
        return mounted.get() === current && accountCurrent(account)
    }
    override fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean {
        val current = mounted.get()?.takeIf { it.account == account && accountCurrent(account) } ?: return false
        current.session.dispatch(emptyList(), notifyMutation = false, acknowledgeHostPreferences = document)
        return mounted.get() === current && accountCurrent(account)
    }
}
