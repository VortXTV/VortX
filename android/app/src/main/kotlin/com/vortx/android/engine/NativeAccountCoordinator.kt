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
        val remote = document.optJSONObject("nativeSync")
        if (document.has("nativeSync")) requireNotNull(remote) { "Invalid native sync document" }
        if (remote != null) {
            require(remote.getString("scope") == namespace && remote.getString("ownerProfileId") == owner.id)
            requireNotNull(remote.optJSONObject("legacyImport")) { "Native account requires a verified legacy baseline receipt" }
        }
        // Always project the CURRENT authenticated legacy carrier, even when nativeSync/checkpoint
        // exists. Receipt replay is a no-op after native edits, but differing old-client/website
        // material is rejected by the kernel before this transaction commits or publishes anything.
        val material = nativeLegacyMaterial(document, roster, resolved.modifiedSeconds)
        // Full descriptors may contain encoded custom strings. Retain exact typed input only if it
        // is credential-free; sanitizing it would silently change the shared kernel's receipt input.
        NativeHostDocument.requireCredentialFree(material)
        val replay = JSONObject().put("type", "import_legacy_sync").put("scope", namespace).put("ownerProfileId", owner.id)
            .put("material", material)
        val syncActions = listOfNotNull(remote?.let { JSONObject().put("type", "merge_native_sync").put("document", it) }, replay)
        val archive = NativeHostDocument.archive(document)
        val old = mounted.get()
        if (old != null && old.account == account && old.session.scope == scope) {
            val read = old.session.read()
            val host = read.state.getJSONObject("hostProfilePreferences")
            val nextHost = if ((resolved.modifiedSeconds ?: 0.0) > host.optDouble("modifiedSeconds", 0.0)) {
                NativeHostProfiles.fromDocument(archive.getJSONObject("document"), roster, resolved.modifiedSeconds)
            } else host
            old.session.dispatch(syncActions, read.owner, nextHost, notifyMutation = false, hostArchive = archive)
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
        val hostProfiles = NativeHostProfiles.fromDocument(archive.getJSONObject("document"), roster, resolved.modifiedSeconds)
        val candidate = try { VortxNativeSession.open(scope, owner.name, bindings, checkpoints, resources,
            bootstrapActions = syncActions, initialHostProfiles = hostProfiles, initialHostArchive = archive, onMutation = onMutation) { accountCurrent(account) } }
            catch (error: Throwable) { (resources as? AutoCloseable)?.close(); throw error }
        val next = Mounted(account, candidate)
        if (!isCurrent() || !accountCurrent(account) || !mounted.compareAndSet(null, next)) {
            candidate.close(); error("Native account changed")
        }
        try {
            project(candidate)
            check(isCurrent() && accountCurrent(account) && mounted.get() === next) { "Native account changed" }
            changes.value += 1; true
        }
        catch (error: Throwable) { if (mounted.compareAndSet(next, null)) candidate.close(); throw error }
    }

    override fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport? {
        val current = mounted.get()?.takeIf { it.account == account && accountCurrent(account) } ?: return null
        val read = current.session.read()
        return current.session.owned(read.owner) {
            // Active selection is device-local and intentionally absent from this carrier.
            val profiles = NativeProfileAccess.projection(read).profiles
            val host = read.state.getJSONObject("hostProfilePreferences")
            NativeAccountExport(read.state.getJSONObject("nativeSync"), profiles, host.optDouble("modifiedSeconds", 0.0), NativeHostProfiles.roster(host, profiles),
                read.state.getBoolean("hostProfileSyncPending"))
        }
    }
}
