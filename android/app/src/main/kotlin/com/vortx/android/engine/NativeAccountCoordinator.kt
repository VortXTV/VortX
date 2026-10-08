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
) : NativeAccountGateway {
    private data class Mounted(val account: SessionOwnerSnapshot.Account, val session: VortxNativeSession)
    private val mounted = AtomicReference<Mounted?>()
    private val retired = ConcurrentLinkedQueue<VortxNativeSession>()
    private val lifecycleLock = Any()
    private val mutex = Mutex()
    val changes = MutableStateFlow(0L)
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
        val old = synchronized(lifecycleLock) {
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
        val scope = checkpoints.discover(namespace) ?: return@withLock false
        val state = scope.validateSnapshot(checkNotNull(checkpoints.read(scope)))
        requireNotNull(state.getJSONObject("nativeSync").optJSONObject("legacyImport")) { "Native account requires a verified legacy baseline receipt" }
        val ownerName = state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getString("name")
        val resources = transport()
        val candidate = try { VortxNativeSession.open(scope, ownerName, bindings, checkpoints, resources,
            onMutation = onMutation) { isCurrent() && accountCurrent(account) } }
            catch (error: Throwable) { (resources as? AutoCloseable)?.close(); throw error }
        publish(account, candidate, isCurrent)
    }

    override suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): JSONObject {
        if (reopenCheckpoint(account, isCurrent)) {
            val read = session().read()
            return session().owned(read.owner) {
                check(isCurrent() && accountCurrent(account))
                val baseline = read.state.getJSONObject("hostDocument")
                require(baseline.optString("nativeAccountBootstrap") == "authenticated-empty-v1") { "Existing account backup disappeared" }
                JSONObject(baseline.toString()).put("nativeSync", read.state.getJSONObject("nativeSync"))
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
            check(applyDocument(account, baseline, isCurrent))
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
        val next = Mounted(account, candidate)
        // Authentication may take its own lock; never invoke it while holding lifecycleLock.
        val current = isCurrent() && accountCurrent(account)
        val installed = current && synchronized(lifecycleLock) { mounted.compareAndSet(null, next) }
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
        check(isCurrent() && accountCurrent(account)) { "Native account changed" }
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
        val legacyAggregate = document.opt("profileEdits").takeIf { value -> value != null && value != JSONObject.NULL &&
            (value !is JSONObject || value.length() > 0) }
        // The historical aggregate must never be folded by the broad legacy importer. Its narrow
        // original-baseline reducer runs after the immutable host archive has durably committed.
        val materialDocument = if (legacyAggregate == null) document else JSONObject(document.toString()).also { it.remove("profileEdits") }
        // Current authenticated legacy material is reconciled against the kernel's acknowledged
        // baseline. Unsupported/missing causal evidence rejects the complete candidate transaction.
        val material = nativeLegacyMaterial(materialDocument, roster, resolved.modifiedSeconds)
        // Full descriptors may contain encoded custom strings. Retain exact typed input only if it
        // is credential-free; sanitizing it would silently change the shared kernel's receipt input.
        NativeHostDocument.requireCredentialFree(material)
        val old = mounted.get()
        val retained = old?.takeIf { it.account == account && it.session.scope == scope && !it.session.requiresRecovery() }?.session?.read()?.state
            ?: checkpoints.read(scope)?.let(scope::validateSnapshot)
        val hasReceipt = remote?.optJSONObject("legacyImport") != null || retained?.optJSONObject("nativeSync")?.optJSONObject("legacyImport") != null
        val replay = JSONObject().put("type", if (hasReceipt) "reconcile_legacy_sync" else "import_legacy_sync").put("scope", namespace).put("ownerProfileId", owner.id)
            .put("material", material)
        if (hasReceipt) replay.put("baselineMaterial", retained?.optJSONObject("legacyImportMaterial") ?: material)
        val syncActions = listOfNotNull(remote?.let { JSONObject().put("type", "merge_native_sync").put("document", it) }, replay)
        val archive = NativeHostDocument.archive(document)
        val baselineHost = NativeHostProfiles.fromDocument(archive.getJSONObject("document"), roster, resolved.modifiedSeconds)
        if (old != null && old.account == account && old.session.scope == scope && !old.session.requiresRecovery()) {
            val read = old.session.read()
            val host = read.state.getJSONObject("hostProfilePreferences")
            val nextHost = if ((resolved.modifiedSeconds ?: 0.0) > host.optDouble("modifiedSeconds", 0.0)) {
                baselineHost
            } else host
            old.session.dispatch(syncActions, read.owner, nextHost, notifyMutation = false, hostArchive = archive,
                remoteHostPreferences = remoteHost, baselineHostProfiles = baselineHost)
            websiteEvents.forEach { event -> old.session.applyWebsiteProfileEdit(event) }
            legacyAggregate?.let { aggregate -> old.session.applyLegacyWebsiteAggregate(aggregate) }
            check(isCurrent()) { "Native account changed" }
            project(old.session)
            check(isCurrent() && accountCurrent(account) && mounted.get() === old) { "Native account changed" }
            return@withLock true
        }
        retire()
        // Close is deferred out of the auth lock to avoid lock inversion, but a replacement writer
        // must join every retired transaction before reading or replacing the same account file.
        while (true) { val prior = retired.poll() ?: break; prior.close() }
        val resources = transport()
        val hostProfiles = baselineHost
        val candidate = try { VortxNativeSession.open(scope, owner.name, bindings, checkpoints, resources,
            bootstrapActions = syncActions, initialHostProfiles = hostProfiles, initialHostArchive = archive,
            initialHostPreferences = remoteHost, onMutation = onMutation) { accountCurrent(account) } }
            catch (error: Throwable) { (resources as? AutoCloseable)?.close(); throw error }
        try { websiteEvents.forEach { event -> candidate.applyWebsiteProfileEdit(event) } }
        catch (error: Throwable) { candidate.close(); throw error }
        try { legacyAggregate?.let { aggregate -> candidate.applyLegacyWebsiteAggregate(aggregate) } }
        catch (error: Throwable) { candidate.close(); throw error }
        try { checkpoints.remember(scope) }
        catch (error: Throwable) { candidate.close(); throw error }
        publish(account, candidate, isCurrent)
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
