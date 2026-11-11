package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.VortXSyncDoc
import org.json.JSONObject

/** Local validation only. The actual Session.open builds and checks its complete native/host
 * snapshot against a private scratch store. Nothing is mounted, published, persisted or returned
 * as an owner/read/checkpoint capability. Only the original lossless projected bytes may escape. */
internal object NativeWebsiteRosterAdmission {
    class MetadataRequired : IllegalArgumentException("Website account requires original watched metadata")

    /** Input is the exact output of NativeWebsiteRosterProjection; the gateway owns and retains it. */
    suspend fun requireAdmissible(scope: VortxAccountScope, projected: ByteArray, bindings: VortxRuntimeBindings,
        checkCurrent: () -> Unit) {
        checkCurrent()
        require(scope.ownerProfileID == UserProfile.OWNER_ID)
        checkCurrent()
        val snapshot = nativeWatchedDocumentSnapshot(NativeProfileOverlayWitness.parseAccountDocument(projected))
        val document = try { NativeProfileOverlayWitness.parseDocument(snapshot) } finally { snapshot.fill(0) }
        val parsed = VortXSyncDoc.parse(document)
        require(parsed.rosterIsLossless)
        val resolved = SettingsBackup.resolveRosterForPull(document.opt("settings"),
            parsed.roster.takeIf { parsed.rosterIsLossless }, parsed.rosterModifiedSeconds, parsed.rosterIsLossless)
        val roster = requireNotNull(resolved.roster)
        val owner = roster.single()
        require(owner == UserProfile(id = scope.ownerProfileID, name = "Main", avatar = "🍿", isOwner = true) &&
            resolved.modifiedSeconds == 0.0)

        // Shared with ordinary applyDocumentLocked: source credentials cannot be silently
        // stripped from an immutable add-on/library/watch source to make import succeed.
        val archive = nativeLegacySourceArchive(document)
        val archived = archive.getJSONObject("document")
        val watchlists = nativeLegacyWatchlists(document, roster.map { it.id }.toSet())
        archived.put("nativeWatchlistMigrationPending", watchlists.pending)
        val materialDocument = nativeMigrationSourceDocument(archived).also { it.remove("profileEdits") }
        checkCurrent()

        // This route has no prior local source archive and never fetches provider metadata.
        // Enumerate with the real producer's source reader; a nonempty opaque watched source
        // is unresolved evidence, not permission to substitute an empty inventory.
        val source = WatchedSource(scope, null, nativeWatchedDocumentSnapshot(materialDocument), null)
        if (source.rows(roster).isNotEmpty()) throw MetadataRequired()
        val watched = NativeWatchedMigrationProducer(fetch = { throw MetadataRequired() }).prepare(
            scope, materialDocument, roster, isCurrent = { checkCurrent(); true })
        if (!watched.isComplete) throw MetadataRequired()
        val prepared = prepareNativeLegacyMaterial(materialDocument, roster, resolved.modifiedSeconds,
            accountScope = scope, watchedMigration = watched)
        val material = prepared.material
        NativeHostDocument.requireCredentialFree(material)
        archived.put("nativeLegacyMembershipPending", nativeLegacyMembershipJournal(scope, null,
            prepared.pendingMembershipReceipts, roster.map { it.id }.toSet()))
        mergeNativeWatchedArchive(scope, null, archived, watched.storage())
        archived.put("nativeOwnAccountPending", JSONObject())
        nativeWatchedDocumentSnapshot(archived).fill(0)
        val host = NativeHostProfiles.fromDocument(archived, roster, resolved.modifiedSeconds)
        val action = JSONObject().put("type", "import_legacy_sync").put("scope", scope.accountID)
            .put("ownerProfileId", scope.ownerProfileID).put("material", material)
        checkCurrent()

        val scratch = ScratchStore(scope, checkCurrent)
        var session: VortxNativeSession? = null
        try {
            session = VortxNativeSession.open(scope, owner.name, bindings, scratch, NoResources,
                bootstrapActions = listOf(action), initialHostProfiles = host, initialHostArchive = archive,
                initialLegacyWatchlists = watchlists.profiles,
                verifyCandidate = { checkCurrent() }, isAccountCurrent = { checkCurrent(); true })
            checkCurrent()
            check(session.heldLegacyReconciliation == null) { "Detached native import was held" }
            val state = session.read().state
            val receipt = state.getJSONObject("nativeSync").getJSONObject("legacyImport")
            require(receipt.getInt("schemaVersion") == material.getInt("schemaVersion"))
            require(NativeHostPreferences.equal(state.getJSONObject("legacyImportMaterial"), material))
            checkCurrent()
        } finally {
            try { session?.close() } finally { scratch.close() }
        }
        // Cleanup must finish while this original operation remains admitted, before PUT.
        checkCurrent()
    }

    /** Explicitly not a production store or an absence/CAS proof. Only Session.open's ordinary
     * generic validation path may use it. No directory, key, locator, archive or receipt is written. */
    private class ScratchStore(private val expected: VortxAccountScope, private val checkCurrent: () -> Unit) :
        VortxCheckpointStore, AutoCloseable {
        private var closed = false
        private var snapshot: String? = null
        override val supportsCheckpointAuthority = false
        override fun read(scope: VortxAccountScope): String? {
            checkCurrent(); check(!closed && scope == expected); return snapshot
        }
        override fun commit(scope: VortxAccountScope, snapshot: String) {
            checkCurrent(); check(!closed && scope == expected && this.snapshot == null)
            // Same plaintext ceiling as VortxEncryptedCheckpointStore (32 MiB minus GCM framing).
            // This is a bounded scratch-buffer check, not a claim of production persistence.
            require(snapshot.toByteArray(Charsets.UTF_8).size <= 33_554_432 - 28)
            this.snapshot = snapshot
        }
        override fun discover(accountID: String): VortxAccountScope? = error("Detached locator access forbidden")
        override fun remember(scope: VortxAccountScope) = error("Detached locator publication forbidden")
        override fun verifyFreshAccount(scope: VortxAccountScope) = error("Detached store grants no absence")
        override fun readPreflight(accountID: String): NativeMigrationPreflight? = error("Detached preflight access forbidden")
        override fun commitPreflight(next: NativeMigrationPreflight, expected: NativeMigrationPreflight?) =
            error("Detached preflight publication forbidden")
        override fun close() { closed = true; snapshot = null }
    }

    private object NoResources : VortxResourceTransport {
        override fun makeCancellation(): VortxResourceCancellation = error("Detached resource request forbidden")
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String =
            error("Detached resource request forbidden")
    }
}

/** The exact source-only credential/archive preparation used by ordinary account apply. Keeping
 * this shared avoids a weaker detached credential policy or a second source-field inventory. */
internal fun nativeLegacySourceArchive(document: JSONObject): JSONObject {
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
    return archive
}
