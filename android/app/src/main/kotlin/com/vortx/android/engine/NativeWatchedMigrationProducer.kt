package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.engine.LegacyWatchedBitfieldMigrationEvidence as WatchedEvidence
import com.vortx.android.engine.LegacyWatchedBitfieldMigrationEvidence.SourceRowLocator as WatchedLocator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Base64

/** One authenticated source snapshot, retained before the first metadata suspension. Owner/shared
 * documents arrive parsed, so their bytes are this strict capture serialization, not HTTP bytes.
 * Independent sources retain their ORIGINAL producer envelope and response bytes without rewriting. */
internal class NativeWatchedMigrationProducer(
    private val fetch: suspend (WatchedEvidence.MetadataRequest) -> WatchedEvidence.MetadataResponse = NativeWatchedMetadataHTTP()::fetch,
) {
    suspend fun prepare(
        scope: VortxAccountScope,
        document: JSONObject,
        roster: List<UserProfile>,
        ownSources: List<NativeOwnAccountSource> = emptyList(),
        retainedArchive: JSONArray? = null,
        retainedStorage: NativeWatchedMigrationStorage? = null,
        isCurrent: () -> Boolean,
    ): NativeWatchedMigrationBatch {
        require(isCurrent()) { "Watched migration account changed" }
        require(roster.single { it.isOwner }.id == scope.ownerProfileID)
        return prepareCaptured(scope, document, roster, ownSources, retainedStorage ?: NativeWatchedMigrationStorage.read(retainedArchive?.let { JSONObject().put(NativeWatchedMigrationStorage.EVIDENCE, it) }), isCurrent)
    }

    /** The caller supplies its authenticated session scope (including the owner UUID). New links
     * and rebinds can attest only to this independent envelope, never a historical
     * root UUID overlay or the owner's global source. No synthetic owner/library is consulted. */
    suspend fun prepareOwn(scope: VortxAccountScope, profile: UserProfile, source: NativeOwnAccountSource,
                           retainedArchive: JSONArray? = null, retainedStorage: NativeWatchedMigrationStorage? = null, isCurrent: () -> Boolean): NativeWatchedMigrationBatch {
        require(!profile.isOwner && profile.usesOwnAccount && profile.id == source.profileID)
        return prepareCaptured(scope, JSONObject(), listOf(profile), listOf(source), retainedStorage ?: NativeWatchedMigrationStorage.read(retainedArchive?.let { JSONObject().put(NativeWatchedMigrationStorage.EVIDENCE, it) }), isCurrent)
    }

    /** Retry sealed historical rows, not the current document or active credential. Completing an
     * archived UID's metadata grants no current import authority: this API cannot return a batch. */
    suspend fun retryPending(scope: VortxAccountScope, pending: JSONArray, retainedArchive: JSONArray? = null,
                             isCurrent: () -> Boolean): NativeWatchedMigrationRetry = retryPending(scope,
        NativeWatchedMigrationStorage.read(JSONObject().put(NativeWatchedMigrationStorage.PENDING, pending)
            .put(NativeWatchedMigrationStorage.EVIDENCE, retainedArchive ?: JSONArray())), isCurrent)

    suspend fun retryPending(scope: VortxAccountScope, storage: NativeWatchedMigrationStorage,
                             isCurrent: () -> Boolean): NativeWatchedMigrationRetry {
        fun requireCurrent() { require(isCurrent()) { "Watched migration account or profile changed" } }
        currentCoroutineContext().ensureActive(); requireCurrent(); storage.requireScope(scope)
        // The sealed compact snapshot is immutable before suspension. Keep the original pending
        // receipts even after success; their identities cease to be unresolved, not to exist.
        val originals = storage.inlineRecords(NativeWatchedMigrationStorage.PENDING)
        val accepted = storage.records(NativeWatchedMigrationStorage.EVIDENCE)
        val acceptedIdentities = (0 until accepted.length()).map { nativeWatchedRecordIdentity(accepted.getJSONObject(it)) }.toMutableSet()
        val result = NativeWatchedMigrationStorage.Builder().also { it.add(storage) }
        val materials = mutableMapOf<String, WatchedEvidence.SourceMaterial>()
        for (index in 0 until originals.length()) {
            currentCoroutineContext().ensureActive(); requireCurrent()
            val record = originals.getJSONObject(index)
            val identity = nativeWatchedRecordIdentity(record)
            if (identity in acceptedIdentities) continue
            val historicalScope = WatchedEvidence.Scope(record.getString("accountId"), record.getString("profileId"),
                record.opt("verifiedStreamingUid") as? String, record.getString("ownerProfileId"))
            val source = materials.getOrPut(record.getString("sourceDocumentSha256")) {
                WatchedEvidence.SourceMaterial(watchedDecode64(record.getString("sourceDocumentBase64")))
            }
            val locator = watchedLocator(record.getJSONObject("row"))
            val metaID = source.metaID(historicalScope, locator)
            val descriptors = source.addons(locator).filter { supportsSeriesMetadata(it, metaID) }
            var first: NativeWatchedRowEvidence? = null
            var ambiguous = false
            for (descriptor in descriptors) {
                currentCoroutineContext().ensureActive(); requireCurrent()
                try {
                    val captured = NativeWatchedRowEvidence.capture(historicalScope, source, locator, descriptor, isCurrent, fetch, false)
                    if (first == null) first = captured else if (!captured.sameInventory(requireNotNull(first))) ambiguous = true
                    currentCoroutineContext().ensureActive()
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { requireCurrent(); currentCoroutineContext().ensureActive() }
            }
            if (first != null && !ambiguous) {
                result.evidence(first.archive()); acceptedIdentities.add(identity)
            }
        }
        currentCoroutineContext().ensureActive(); requireCurrent()
        return NativeWatchedMigrationRetry(result.build(), isCurrent)
    }

    private suspend fun prepareCaptured(scope: VortxAccountScope, document: JSONObject, roster: List<UserProfile>,
                                        ownSources: List<NativeOwnAccountSource>, retainedStorage: NativeWatchedMigrationStorage,
                                        isCurrent: () -> Boolean): NativeWatchedMigrationBatch {
        require(isCurrent()) { "Watched migration account changed" }
        require(ownSources.map { it.profileID }.distinct().size == ownSources.size)
        require(ownSources.all { it.accountID == scope.accountID && roster.any { profile -> profile.id == it.profileID && profile.usesOwnAccount } })
        val sources = listOf(WatchedSource(scope, null, nativeWatchedDocumentSnapshot(document), null)) + ownSources.map {
            WatchedSource(scope, it, watchedDecode64(it.archiveBase64()), it.verifiedUID)
        }
        val rosterSnapshot = roster.map { Triple(it.id, it.isOwner, it.usesOwnAccount) }
        retainedStorage.requireScope(scope)
        val old = retainedStorage.inlineRecords(NativeWatchedMigrationStorage.EVIDENCE)
        val oldIndex = (0 until old.length()).associate { index ->
            val record = old.getJSONObject(index); nativeWatchedRecordIdentity(record) to record
        }
        val accepted = mutableListOf<NativeWatchedRowEvidence>()
        val pending = NativeWatchedMigrationStorage.Builder()
        val candidates = sources.flatMap { it.rows(roster) }
        for (candidate in candidates) {
            currentCoroutineContext().ensureActive()
            candidate.source.requireCurrent(isCurrent)
            candidate.source.material.validate(candidate.scope, candidate.locator)
            val prior = oldIndex[nativeWatchedRecordIdentity(candidate.pending("episode_inventory_unavailable"))]
            if (prior != null) {
                val replayed = NativeWatchedRowEvidence.replay(prior, candidate.source.material, false, isCurrent)
                pending.evidence(replayed.archive())
                accepted += replayed
                currentCoroutineContext().ensureActive()
                candidate.source.requireCurrent(isCurrent)
                continue
            }
            val descriptors = candidate.source.material.addons(candidate.locator).filter { supportsSeriesMetadata(it, candidate.metaID) }
            var first: NativeWatchedRowEvidence? = null
            var ambiguous = false
            for (descriptor in descriptors) {
                currentCoroutineContext().ensureActive()
                candidate.source.requireCurrent(isCurrent)
                try {
                    val captured = NativeWatchedRowEvidence.capture(candidate, descriptor, {
                        candidate.source.requireCurrent(isCurrent); true
                    }, fetch)
                    currentCoroutineContext().ensureActive()
                    if (first == null) first = captured else if (!captured.sameInventory(requireNotNull(first))) ambiguous = true
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) {
                    // A failed provider is unresolved evidence, never an empty watched inventory.
                    candidate.source.requireCurrent(isCurrent)
                    currentCoroutineContext().ensureActive()
                }
            }
            if (first != null && !ambiguous) {
                pending.evidence(first.archive())
                accepted += first
            }
            else pending.pending(candidate.pending(if (first == null) "episode_inventory_unavailable" else "episode_inventory_ambiguous"))
        }
        sources.forEach { it.requireCurrent(isCurrent) }
        currentCoroutineContext().ensureActive()
        require(sources.first().bytes().contentEquals(nativeWatchedDocumentSnapshot(document))) { "Watched migration source changed" }
        return NativeWatchedMigrationBatch(scope, sources, rosterSnapshot, accepted, pending.build(), isCurrent)
    }
}

/** Only strict capture/replay can construct a row. Neither callers nor archived decoded IDs can
 * supply watched facts; archive replay always derives them again from the retained raw originals. */
internal class NativeWatchedRowEvidence private constructor(private val evidence: WatchedEvidence.Evidence) {
    fun matches(profileID: String, locator: WatchedLocator, raw: JSONObject): Boolean = evidence.scope.profileID == profileID &&
        evidence.rowLocator == locator && evidence.metaID == raw.getString("id") && evidence.watchedBitfield == raw.getString("watched")
    fun videoIDs(): List<String> = evidence.watchedVideoIDs.toList()
    fun sameInventory(other: NativeWatchedRowEvidence): Boolean = evidence.inventory == other.evidence.inventory
    internal fun requireSource(sources: List<WatchedSource>) {
        require(sources.any { source -> source.account.accountID == evidence.scope.accountID &&
            source.account.ownerProfileID == evidence.scope.ownerProfileID && source.digest == evidence.sourceSHA256 &&
            source.material.sameSource(evidence.sourceMaterial) && if (evidence.scope.verifiedStreamingUID == null) source.own == null
            else source.own?.let { it.profileID == evidence.scope.profileID && it.verifiedUID == evidence.scope.verifiedStreamingUID } == true
        }) { "Watched evidence does not belong to captured authenticated source" }
    }
    fun archive(): JSONObject = watchedHeader(evidence.scope, evidence.sourceMaterial, evidence.rowLocator)
        .put("addon", JSONObject().put("transportUrl", evidence.addon.transportURL).put("manifestBase64", watchedEncode64(evidence.addon.manifest)))
        .put("metadataResponseBase64", watchedEncode64(evidence.metadata)).put("metadataResponseSha256", evidence.metadataSHA256)

    companion object {
        internal suspend fun capture(candidate: WatchedCandidate, addon: WatchedEvidence.AuthorizedAddon, isCurrent: () -> Boolean,
                                     fetch: suspend (WatchedEvidence.MetadataRequest) -> WatchedEvidence.MetadataResponse): NativeWatchedRowEvidence =
            capture(candidate.scope, candidate.source.material, candidate.locator, addon, isCurrent, fetch, false)

        internal suspend fun capture(scope: WatchedEvidence.Scope, source: ByteArray, locator: WatchedLocator,
                                     addon: WatchedEvidence.AuthorizedAddon, isCurrent: () -> Boolean,
                                     fetch: suspend (WatchedEvidence.MetadataRequest) -> WatchedEvidence.MetadataResponse): NativeWatchedRowEvidence =
            capture(scope, WatchedEvidence.SourceMaterial(source), locator, addon, isCurrent, fetch)
        internal suspend fun capture(scope: WatchedEvidence.Scope, source: WatchedEvidence.SourceMaterial, locator: WatchedLocator,
                                     addon: WatchedEvidence.AuthorizedAddon, isCurrent: () -> Boolean,
                                     fetch: suspend (WatchedEvidence.MetadataRequest) -> WatchedEvidence.MetadataResponse,
                                     inspectSource: Boolean = true): NativeWatchedRowEvidence {
            val evidence = source.capture(scope, locator, addon, isCurrent, fetch)
            requireWatchedCredentialFree(evidence, inspectSource)
            return NativeWatchedRowEvidence(evidence)
        }
        internal fun replay(record: JSONObject, sourceMaterial: WatchedEvidence.SourceMaterial? = null,
                            inspectSource: Boolean = true, isCurrent: () -> Boolean): NativeWatchedRowEvidence {
            val common = setOf("schemaVersion", "accountId", "profileId", "ownerProfileId", "sourceDocumentBase64", "sourceDocumentSha256", "row", "addon", "metadataResponseBase64", "metadataResponseSha256")
            require(record.keys().asSequence().toSet() == common + if (record.has("verifiedStreamingUid")) setOf("verifiedStreamingUid") else emptySet())
            require(record.get("schemaVersion") is Number && record.getDouble("schemaVersion") == 1.0)
            require(!record.has("verifiedStreamingUid") || record.get("verifiedStreamingUid") is String) { "Malformed watched streaming identity" }
            val scope = WatchedEvidence.Scope(record.getString("accountId"), record.getString("profileId"),
                record.opt("verifiedStreamingUid") as? String, record.getString("ownerProfileId"))
            val source = sourceMaterial ?: WatchedEvidence.SourceMaterial(watchedDecode64(record.getString("sourceDocumentBase64")))
            require(source.base64 == record.getString("sourceDocumentBase64")) { "Watched evidence source mismatch" }
            val metadata = watchedDecode64(record.getString("metadataResponseBase64"))
            require(source.sha256 == record.getString("sourceDocumentSha256") && watchedSHA(metadata) == record.getString("metadataResponseSha256")) { "Watched evidence digest mismatch" }
            val rawAddon = record.getJSONObject("addon")
            require(rawAddon.keys().asSequence().toSet() == setOf("transportUrl", "manifestBase64"))
            val addon = WatchedEvidence.AuthorizedAddon(rawAddon.getString("transportUrl"), watchedDecode64(rawAddon.getString("manifestBase64")))
            val evidence = source.replay(scope, watchedLocator(record.getJSONObject("row")), addon, metadata, isCurrent)
            require(supportsSeriesMetadata(addon, evidence.metaID)) { "Retained add-on does not advertise matching metadata" }
            requireWatchedCredentialFree(evidence, inspectSource)
            return NativeWatchedRowEvidence(evidence)
        }
    }
}

/** Historical retry receipts are archival data only. No video IDs, native material, source
 * authority, or current-import admission can be obtained from this result. */
internal class NativeWatchedMigrationRetry internal constructor(private val retained: NativeWatchedMigrationStorage,
                                                                private val isCurrent: () -> Boolean) {
    val isComplete: Boolean get() = retained.unresolvedCount == 0
    fun storage(): NativeWatchedMigrationStorage {
        require(isCurrent()) { "Watched migration account or profile changed" }; return retained
    }
    fun archive(): JSONArray = storage().inlineRecords(NativeWatchedMigrationStorage.EVIDENCE)
    /** Compatibility view of unresolved rows. Durable storage retains all original pending rows. */
    fun pending(): JSONArray {
        val value = storage(); val complete = value.inlineRecords(NativeWatchedMigrationStorage.EVIDENCE)
        val ids = (0 until complete.length()).map { nativeWatchedRecordIdentity(complete.getJSONObject(it)) }.toSet()
        val rows = value.inlineRecords(NativeWatchedMigrationStorage.PENDING)
        return JSONArray((0 until rows.length()).map(rows::getJSONObject).filterNot { nativeWatchedRecordIdentity(it) in ids })
    }
}

internal class NativeWatchedMigrationBatch internal constructor(
    private val scope: VortxAccountScope,
    private val sources: List<WatchedSource>,
    private val roster: List<Triple<String, Boolean, Boolean>>,
    private val evidence: List<NativeWatchedRowEvidence>,
    private val unresolved: NativeWatchedMigrationStorage,
    private val isCurrent: () -> Boolean,
) {
    init { require(sources.isNotEmpty()); evidence.forEach { it.requireSource(sources) } }
    val isComplete: Boolean get() = unresolved.unresolvedCount == 0
    fun archive(): JSONArray { sources.forEach { it.requireCurrent(isCurrent) }; return JSONArray(evidence.map { it.archive() }) }
    fun pending(): JSONArray { sources.forEach { it.requireCurrent(isCurrent) }; return unresolved.inlineRecords(NativeWatchedMigrationStorage.PENDING) }
    fun storage(): NativeWatchedMigrationStorage {
        sources.forEach { it.requireCurrent(isCurrent) }
        return unresolved
    }
    fun requireOwnSource(source: NativeOwnAccountSource) {
        require(source.accountID == scope.accountID && sources.any { it.own === source }) { "Watched evidence own source changed" }
        require(roster.any { it.first == source.profileID && !it.second && it.third }) { "Watched evidence own profile changed" }
        sources.forEach { it.requireCurrent(isCurrent) }
        require(isComplete) { "Native migration reconciliation required: watched metadata remains unresolved" }
    }
    fun requireInputs(document: JSONObject, profiles: List<UserProfile>, account: VortxAccountScope?, ownSources: List<NativeOwnAccountSource>) {
        require(account == scope) { "Watched evidence account scope changed" }
        require(profiles.map { Triple(it.id, it.isOwner, it.usesOwnAccount) } == roster) { "Watched evidence profile scope changed" }
        require(sources.first().bytes().contentEquals(nativeWatchedDocumentSnapshot(document))) { "Watched evidence source changed" }
        val own = sources.mapNotNull { it.own }
        require(own.size == ownSources.size && own.all { prior -> ownSources.any { it === prior } }) { "Watched evidence own source changed" }
        sources.forEach { it.requireCurrent(isCurrent) }
        require(isComplete) { "Native migration reconciliation required: watched metadata remains unresolved" }
    }
    fun videoIDs(profileID: String, locator: WatchedLocator, raw: JSONObject): List<String> {
        sources.forEach { it.requireCurrent(isCurrent) }
        return evidence.singleOrNull { it.matches(profileID, locator, raw) }?.videoIDs()
            ?: throw IllegalArgumentException("Native migration reconciliation required: opaque watched bitfield lacks source-bound metadata")
    }
}

internal class WatchedSource(val account: VortxAccountScope, val own: NativeOwnAccountSource?, bytes: ByteArray, private val uid: String?) {
    val material = WatchedEvidence.SourceMaterial(bytes)
    val digest = material.sha256
    init { requireWatchedSourceCredentialFree(WatchedEvidence.Scope(account.accountID, own?.profileID ?: account.ownerProfileID, uid, account.ownerProfileID), material.bytes()) }
    fun bytes(): ByteArray = material.bytes()
    fun document(): JSONObject = NativeProfileOverlayWitness.parseDocument(material.bytes())
    fun requireCurrent(isCurrent: () -> Boolean) {
        require(isCurrent()) { "Watched migration account or profile changed" }
        own?.withActive { require(own.digest == digest && own.verifiedUID == uid) { "Watched migration own source changed" } }
    }
    fun rows(roster: List<UserProfile>): List<WatchedCandidate> {
        val root = document()
        val result = mutableListOf<WatchedCandidate>()
        fun append(profile: String, rows: JSONArray?, locator: (Int) -> WatchedLocator, rawState: Boolean = false) {
            for (index in 0 until (rows?.length() ?: 0)) {
                val row = rows!!.getJSONObject(index)
                val state = if (rawState) row.optJSONObject("state") else row
                if (state?.opt("watched") is String && state.getString("watched").isNotEmpty()) {
                    val metaID = row.getString(if (rawState) "_id" else "id")
                    result += WatchedCandidate(this, WatchedEvidence.Scope(account.accountID, profile, uid, account.ownerProfileID), locator(index), metaID)
                }
            }
        }
        if (own != null) {
            val library = NativeProfileOverlayWitness.parseDocument(watchedDecode64(root.getString("libraryResponseBase64")))
            append(own.profileID, library.getJSONArray("result"), WatchedLocator::OwnAccountLibraryResponse, true)
            val overlay = NativeProfileOverlayWitness.parseDocument(watchedDecode64(root.getString("profileOverlayBase64")))
            val bucket = overlay.optJSONObject("vortx")?.optJSONObject("byProfile")?.optJSONObject(own.profileID)
            append(own.profileID, bucket?.optJSONArray("library"), WatchedLocator::OwnAccountProfileLibrary)
            append(own.profileID, bucket?.optJSONArray("ownerHistory"), WatchedLocator::OwnAccountOwnerHistory)
        } else {
            val vortx = root.optJSONObject("vortx")
            val ownerRows = vortx?.optJSONArray("library")
            if (ownerRows != null) append(account.ownerProfileID, ownerRows, WatchedLocator::AuthenticatedOwnerLibrary)
            else append(account.ownerProfileID, root.optJSONArray("library"), WatchedLocator::AuthenticatedLegacyRootLibrary)
            val profiles = vortx?.optJSONObject("byProfile")
            // A lower/upper UUID alias must not make watched rows disappear from enumeration.
            profiles?.keys()?.asSequence()?.toList()?.groupBy { it.uppercase() }?.forEach { (_, aliases) ->
                require(aliases.size == 1) { "Ambiguous watched profile carrier" }
            }
            (roster.map { it.id } + account.ownerProfileID + UserProfile.OWNER_ID).forEach { id ->
                profiles?.keys()?.asSequence()?.filter { it.equals(id, true) }?.forEach {
                    require(it == id) { "Noncanonical watched profile carrier" }
                }
            }
            profiles?.keys()?.asSequence().orEmpty().filter { it.equals(account.ownerProfileID, true) || it.equals(UserProfile.OWNER_ID, true) }.forEach { sourceProfileID ->
                append(account.ownerProfileID, profiles?.optJSONObject(sourceProfileID)?.optJSONArray("ownerHistory"), locator = {
                    WatchedLocator.AuthenticatedOwnerHistory(it, sourceProfileID)
                })
            }
            roster.filterNot { it.usesOwnAccount }.forEach { profile ->
                append(profile.id, profiles?.optJSONObject(profile.id)?.optJSONArray("library"), WatchedLocator::AuthenticatedProfileLibrary)
            }
        }
        return result
    }
}

internal data class WatchedCandidate(val source: WatchedSource, val scope: WatchedEvidence.Scope, val locator: WatchedLocator, val metaID: String) {
    fun matches(record: JSONObject): Boolean = record.getString("accountId") == scope.accountID && record.getString("profileId") == scope.profileID &&
        record.getString("ownerProfileId") == scope.ownerProfileID && (record.opt("verifiedStreamingUid") as? String) == scope.verifiedStreamingUID &&
        record.getString("sourceDocumentSha256") == source.digest && watchedLocator(record.getJSONObject("row")) == locator
    fun pending(reason: String): JSONObject = watchedHeader(scope, source.material, locator).put("reason", reason)
}

internal fun validateNativeWatchedMigrationArchive(value: JSONArray): JSONArray = JSONArray().also { output ->
    val identities = mutableSetOf<String>()
    for (index in 0 until value.length()) {
        val evidence = NativeWatchedRowEvidence.replay(value.getJSONObject(index)) { true }
        val record = evidence.archive()
        val identity = watchedRecordIdentity(record)
        require(identities.add(identity)) { "Duplicate watched archive row" }
        output.put(record)
    }
}

private fun watchedRecordIdentity(record: JSONObject): String = JSONArray(listOf(
    record.getString("accountId"), record.getString("ownerProfileId"), record.getString("profileId"),
    record.opt("verifiedStreamingUid"), record.getString("sourceDocumentSha256"),
    watchedLocatorJSON(watchedLocator(record.getJSONObject("row"))),
)).toString()

/** Pending rows retain undecoded originals with truthful failure status. They grant no watched
 * authority and must never be acknowledged as an empty completed migration. */
internal fun validateNativeWatchedMigrationPending(value: JSONArray, material: WatchedEvidence.SourceMaterial? = null,
                                                    inspectSource: Boolean = true): JSONArray = JSONArray().also { output ->
    for (index in 0 until value.length()) {
        val record = value.getJSONObject(index)
        val keys = setOf("schemaVersion", "accountId", "profileId", "ownerProfileId", "sourceDocumentBase64", "sourceDocumentSha256", "row", "reason")
        require(record.keys().asSequence().toSet() == keys + if (record.has("verifiedStreamingUid")) setOf("verifiedStreamingUid") else emptySet())
        require(record.get("schemaVersion") is Number && record.getDouble("schemaVersion") == 1.0)
        require(!record.has("verifiedStreamingUid") || record.get("verifiedStreamingUid") is String) { "Malformed watched streaming identity" }
        require(record.getString("reason") in setOf("episode_inventory_unavailable", "episode_inventory_ambiguous"))
        val scope = WatchedEvidence.Scope(record.getString("accountId"), record.getString("profileId"),
            record.opt("verifiedStreamingUid") as? String, record.getString("ownerProfileId"))
        val source = material ?: WatchedEvidence.SourceMaterial(watchedDecode64(record.getString("sourceDocumentBase64")))
        require(source.base64 == record.getString("sourceDocumentBase64") && source.sha256 == record.getString("sourceDocumentSha256")) { "Pending watched evidence digest mismatch" }
        val locator = watchedLocator(record.getJSONObject("row"))
        source.validate(scope, locator)
        if (inspectSource) requireWatchedSourceCredentialFree(scope, source.bytes())
        output.put(watchedHeader(scope, source, locator).put("reason", record.getString("reason")))
    }
}

private fun watchedHeader(scope: WatchedEvidence.Scope, source: ByteArray, locator: WatchedLocator): JSONObject =
    watchedHeader(scope, WatchedEvidence.SourceMaterial(source), locator)
private fun watchedHeader(scope: WatchedEvidence.Scope, source: WatchedEvidence.SourceMaterial, locator: WatchedLocator): JSONObject = JSONObject()
    .put("schemaVersion", 1).put("accountId", scope.accountID).put("profileId", scope.profileID).put("ownerProfileId", scope.ownerProfileID)
    .put("sourceDocumentBase64", source.base64).put("sourceDocumentSha256", source.sha256).put("row", watchedLocatorJSON(locator))
    .also { scope.verifiedStreamingUID?.let { uid -> it.put("verifiedStreamingUid", uid) } }

internal fun watchedLocatorJSON(locator: WatchedLocator): JSONObject {
    val (kind, index) = when (locator) {
        is WatchedLocator.AuthenticatedOwnerLibrary -> "owner_library" to locator.index
        is WatchedLocator.AuthenticatedLegacyRootLibrary -> "legacy_root_library" to locator.index
        is WatchedLocator.AuthenticatedProfileLibrary -> "profile_library" to locator.index
        is WatchedLocator.AuthenticatedOwnerHistory -> "owner_history" to locator.index
        is WatchedLocator.OwnAccountLibraryResponse -> "own_library" to locator.index
        is WatchedLocator.OwnAccountProfileLibrary -> "own_profile_library" to locator.index
        is WatchedLocator.OwnAccountOwnerHistory -> "own_owner_history" to locator.index
    }
    return JSONObject().put("kind", kind).put("index", index).also {
        if (locator is WatchedLocator.AuthenticatedOwnerHistory) it.put("sourceProfileId", locator.sourceProfileID)
    }
}
internal fun watchedLocator(row: JSONObject): WatchedLocator {
    val kind = row.getString("kind")
    require(row.keys().asSequence().toSet() == setOf("kind", "index") + if (kind == "owner_history") setOf("sourceProfileId") else emptySet())
    val index = (row.get("index") as? Number)?.toDouble() ?: error("Malformed watched row index")
    require(index >= 0 && index < 10_000 && index.toInt().toDouble() == index)
    return when (kind) {
        "owner_library" -> WatchedLocator.AuthenticatedOwnerLibrary(index.toInt())
        "legacy_root_library" -> WatchedLocator.AuthenticatedLegacyRootLibrary(index.toInt())
        "profile_library" -> WatchedLocator.AuthenticatedProfileLibrary(index.toInt())
        "owner_history" -> WatchedLocator.AuthenticatedOwnerHistory(index.toInt(), row.getString("sourceProfileId"))
        "own_library" -> WatchedLocator.OwnAccountLibraryResponse(index.toInt())
        "own_profile_library" -> WatchedLocator.OwnAccountProfileLibrary(index.toInt())
        "own_owner_history" -> WatchedLocator.OwnAccountOwnerHistory(index.toInt())
        else -> error("Unsupported watched row locator")
    }
}

private fun supportsSeriesMetadata(addon: WatchedEvidence.AuthorizedAddon, metaID: String): Boolean {
    val manifest = NativeProfileOverlayWitness.parseDocument(addon.manifest)
    val resources = manifest.optJSONArray("resources") ?: return false
    fun matches(list: JSONArray?, value: String, prefix: Boolean = false): Boolean = list == null && prefix || list != null &&
        (0 until list.length()).any { index -> (list.opt(index) as? String)?.let { if (prefix) value.startsWith(it) else value == it } == true }
    fun validArrays(value: JSONObject): Boolean = listOf("types", "idPrefixes").all { !value.has(it) || value.opt(it) is JSONArray }
    if (!validArrays(manifest)) return false
    return (0 until resources.length()).any { index ->
        when (val resource = resources.get(index)) {
            "meta" -> matches(manifest.optJSONArray("types"), "series") && matches(manifest.optJSONArray("idPrefixes"), metaID, true)
            is JSONObject -> validArrays(resource) && resource.optString("name") == "meta" && matches(resource.optJSONArray("types") ?: manifest.optJSONArray("types"), "series") &&
                matches(resource.optJSONArray("idPrefixes") ?: manifest.optJSONArray("idPrefixes"), metaID, true)
            else -> false
        }
    }
}

private fun requireWatchedCredentialFree(evidence: WatchedEvidence.Evidence, inspectSource: Boolean = true) {
    if (inspectSource) requireWatchedSourceCredentialFree(evidence.scope, evidence.source)
    val metadata = NativeProfileOverlayWitness.parseDocument(evidence.metadata)
    // Episode IDs/names are literal media slots too. The generic credential scanner still checks
    // valid encoded JSON and every unknown field; the retained raw metadata is never rewritten.
    val videos = metadata.getJSONObject("meta").getJSONArray("videos")
    for (index in 0 until videos.length()) videos.getJSONObject(index).put("type", "series")
    requireOwnAccountSourceCredentialFree(metadata)
    requireOwnAccountSourceCredentialFree(JSONObject().put("manifest", NativeProfileOverlayWitness.parseDocument(evidence.addon.manifest)))
}
internal fun requireWatchedSourceCredentialFree(scope: WatchedEvidence.Scope, bytes: ByteArray) {
    val source = NativeProfileOverlayWitness.parseDocument(bytes)
    if (scope.verifiedStreamingUID == null) requireOwnAccountSourceCredentialFree(source)
    else for (key in listOf("libraryResponseBase64", "addonsResponseBase64", "profileOverlayBase64")) {
        val encoded = source.opt(key)
        require(encoded is String) { "Malformed own-account watched source envelope" }
        requireOwnAccountSourceCredentialFree(NativeProfileOverlayWitness.parseDocument(watchedDecode64(encoded)))
    }
}
internal fun watchedSHA(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
/** Platform JSONObject.numberToString can collapse exact BigDecimal values through double/long.
 * Serialize the already-authenticated numeric lexeme directly, then strict-parse the result. */
internal fun nativeWatchedDocumentSnapshot(document: JSONObject): ByteArray {
    fun encode(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + encode(value.get(it)) }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { encode(value.get(it)) }
        is String -> JSONObject.quote(value)
        is Boolean -> value.toString()
        is Number -> value.toString()
        else -> error("Unsupported authenticated watched source value")
    }
    return encode(document).toByteArray(Charsets.UTF_8).also { NativeProfileOverlayWitness.parseDocument(it) }
}
private fun watchedEncode64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
internal fun watchedDecode64(text: String): ByteArray = Base64.getDecoder().decode(text).also {
    require(watchedEncode64(it) == text) { "Noncanonical watched evidence base64" }
}

/** No registry lookup, authorization header, redirects, cookie jar, cache, or private DNS route. */
private class NativeWatchedMetadataHTTP {
    private val client = buildAddonManifestClient(20_000)
    suspend fun fetch(request: WatchedEvidence.MetadataRequest): WatchedEvidence.MetadataResponse = withContext(Dispatchers.IO) {
        val manifest = requireNotNull(request.addon.transportURL.toHttpUrlOrNull())
        require(manifest.username.isEmpty() && manifest.password.isEmpty() && manifest.fragment == null)
        require(manifest.pathSegments.last() == "manifest.json") { "Unsupported original metadata transport" }
        PublicAddressPolicy.requireLiteralPublicOrHostname(manifest.host)
        val url = manifest.newBuilder().removePathSegment(manifest.pathSegments.lastIndex)
            .addPathSegment("meta").addPathSegment("series").addPathSegment(request.metaID + ".json").build()
        val call = client.newCall(Request.Builder().url(url).get().build())
        val bytes = call.execute().use { response ->
            check(response.isSuccessful) { "Watched metadata unavailable" }
            val body = requireNotNull(response.body)
            check(body.contentLength() <= 2 * 1024 * 1024) { "Watched metadata exceeds limit" }
            body.byteStream().use { input ->
                val result = ByteArrayOutputStream(); val buffer = ByteArray(8192)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer); if (count < 0) break
                    check(result.size() + count <= 2 * 1024 * 1024) { "Watched metadata exceeds limit" }
                    result.write(buffer, 0, count)
                }
                result.toByteArray()
            }
        }
        currentCoroutineContext().ensureActive()
        WatchedEvidence.MetadataResponse(request, bytes)
    }
}
