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
        isCurrent: () -> Boolean,
    ): NativeWatchedMigrationBatch {
        require(isCurrent()) { "Watched migration account changed" }
        require(roster.single { it.isOwner }.id == scope.ownerProfileID)
        return prepareCaptured(scope, document, roster, ownSources, retainedArchive, isCurrent)
    }

    /** The caller supplies its authenticated session scope (including the owner UUID). New links
     * and rebinds can attest only to this independent envelope, never a historical
     * root UUID overlay or the owner's global source. No synthetic owner/library is consulted. */
    suspend fun prepareOwn(scope: VortxAccountScope, profile: UserProfile, source: NativeOwnAccountSource,
                           retainedArchive: JSONArray? = null, isCurrent: () -> Boolean): NativeWatchedMigrationBatch {
        require(!profile.isOwner && profile.usesOwnAccount && profile.id == source.profileID)
        return prepareCaptured(scope, JSONObject(), listOf(profile), listOf(source), retainedArchive, isCurrent)
    }

    private suspend fun prepareCaptured(scope: VortxAccountScope, document: JSONObject, roster: List<UserProfile>,
                                        ownSources: List<NativeOwnAccountSource>, retainedArchive: JSONArray?,
                                        isCurrent: () -> Boolean): NativeWatchedMigrationBatch {
        require(isCurrent()) { "Watched migration account changed" }
        require(ownSources.map { it.profileID }.distinct().size == ownSources.size)
        require(ownSources.all { it.accountID == scope.accountID && roster.any { profile -> profile.id == it.profileID && profile.usesOwnAccount } })
        val sources = listOf(WatchedSource(scope, null, nativeWatchedDocumentSnapshot(document), null)) + ownSources.map {
            WatchedSource(scope, it, watchedDecode64(it.archiveBase64()), it.verifiedUID)
        }
        val rosterSnapshot = roster.map { Triple(it.id, it.isOwner, it.usesOwnAccount) }
        val old = retainedArchive?.let(::validateNativeWatchedMigrationArchive) ?: JSONArray()
        val accepted = mutableListOf<NativeWatchedRowEvidence>()
        val pending = JSONArray()
        val candidates = sources.flatMap { it.rows(roster) }
        for (candidate in candidates) {
            currentCoroutineContext().ensureActive()
            candidate.source.requireCurrent(isCurrent)
            WatchedEvidence.validateSource(candidate.scope, candidate.source.bytes(), candidate.locator)
            requireWatchedSourceCredentialFree(candidate.scope, candidate.source.bytes())
            val prior = (0 until old.length()).map(old::getJSONObject).filter { candidate.matches(it) }
            require(prior.size <= 1) { "Duplicate retained watched evidence" }
            if (prior.isNotEmpty()) {
                accepted += NativeWatchedRowEvidence.replay(prior.single(), isCurrent)
                currentCoroutineContext().ensureActive()
                candidate.source.requireCurrent(isCurrent)
                continue
            }
            val descriptors = WatchedEvidence.originalAddons(candidate.source.bytes(), candidate.locator).filter { supportsSeriesMetadata(it, candidate.metaID) }
            val successful = mutableListOf<NativeWatchedRowEvidence>()
            for (descriptor in descriptors) {
                currentCoroutineContext().ensureActive()
                candidate.source.requireCurrent(isCurrent)
                try {
                    val captured = NativeWatchedRowEvidence.capture(candidate, descriptor, {
                        candidate.source.requireCurrent(isCurrent); true
                    }, fetch)
                    currentCoroutineContext().ensureActive()
                    successful += captured
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) {
                    // A failed provider is unresolved evidence, never an empty watched inventory.
                    candidate.source.requireCurrent(isCurrent)
                    currentCoroutineContext().ensureActive()
                }
            }
            val first = successful.firstOrNull()
            if (first != null && successful.all { it.sameInventory(first) }) accepted += first
            else pending.put(candidate.pending(if (first == null) "episode_inventory_unavailable" else "episode_inventory_ambiguous"))
        }
        sources.forEach { it.requireCurrent(isCurrent) }
        currentCoroutineContext().ensureActive()
        require(sources.first().bytes().contentEquals(nativeWatchedDocumentSnapshot(document))) { "Watched migration source changed" }
        return NativeWatchedMigrationBatch(scope, sources, rosterSnapshot, accepted, pending, isCurrent)
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
            source.bytes().contentEquals(evidence.source) && if (evidence.scope.verifiedStreamingUID == null) source.own == null
            else source.own?.let { it.profileID == evidence.scope.profileID && it.verifiedUID == evidence.scope.verifiedStreamingUID } == true
        }) { "Watched evidence does not belong to captured authenticated source" }
    }
    fun archive(): JSONObject = watchedHeader(evidence.scope, evidence.source, evidence.rowLocator)
        .put("addon", JSONObject().put("transportUrl", evidence.addon.transportURL).put("manifestBase64", watchedEncode64(evidence.addon.manifest)))
        .put("metadataResponseBase64", watchedEncode64(evidence.metadata)).put("metadataResponseSha256", evidence.metadataSHA256)

    companion object {
        internal suspend fun capture(candidate: WatchedCandidate, addon: WatchedEvidence.AuthorizedAddon, isCurrent: () -> Boolean,
                                     fetch: suspend (WatchedEvidence.MetadataRequest) -> WatchedEvidence.MetadataResponse): NativeWatchedRowEvidence {
            val evidence = WatchedEvidence.capture(candidate.scope, candidate.source.bytes(), candidate.locator, addon, isCurrent, fetch)
            requireWatchedCredentialFree(evidence)
            return NativeWatchedRowEvidence(evidence)
        }
        internal fun replay(record: JSONObject, isCurrent: () -> Boolean): NativeWatchedRowEvidence {
            val common = setOf("schemaVersion", "accountId", "profileId", "ownerProfileId", "sourceDocumentBase64", "sourceDocumentSha256", "row", "addon", "metadataResponseBase64", "metadataResponseSha256")
            require(record.keys().asSequence().toSet() == common + if (record.has("verifiedStreamingUid")) setOf("verifiedStreamingUid") else emptySet())
            require(record.get("schemaVersion") is Number && record.getDouble("schemaVersion") == 1.0)
            val scope = WatchedEvidence.Scope(record.getString("accountId"), record.getString("profileId"),
                record.opt("verifiedStreamingUid") as? String, record.getString("ownerProfileId"))
            val source = watchedDecode64(record.getString("sourceDocumentBase64"))
            val metadata = watchedDecode64(record.getString("metadataResponseBase64"))
            require(watchedSHA(source) == record.getString("sourceDocumentSha256") && watchedSHA(metadata) == record.getString("metadataResponseSha256")) { "Watched evidence digest mismatch" }
            val rawAddon = record.getJSONObject("addon")
            require(rawAddon.keys().asSequence().toSet() == setOf("transportUrl", "manifestBase64"))
            val addon = WatchedEvidence.AuthorizedAddon(rawAddon.getString("transportUrl"), watchedDecode64(rawAddon.getString("manifestBase64")))
            val evidence = WatchedEvidence.replay(scope, source, watchedLocator(record.getJSONObject("row")), addon, metadata, isCurrent)
            require(supportsSeriesMetadata(addon, evidence.metaID)) { "Retained add-on does not advertise matching metadata" }
            requireWatchedCredentialFree(evidence)
            return NativeWatchedRowEvidence(evidence)
        }
    }
}

internal class NativeWatchedMigrationBatch internal constructor(
    private val scope: VortxAccountScope,
    private val sources: List<WatchedSource>,
    private val roster: List<Triple<String, Boolean, Boolean>>,
    private val evidence: List<NativeWatchedRowEvidence>,
    private val unresolved: JSONArray,
    private val isCurrent: () -> Boolean,
) {
    init { require(sources.isNotEmpty()); evidence.forEach { it.requireSource(sources) } }
    val isComplete: Boolean get() = unresolved.length() == 0
    fun archive(): JSONArray { sources.forEach { it.requireCurrent(isCurrent) }; return JSONArray(evidence.map { it.archive() }) }
    fun pending(): JSONArray { sources.forEach { it.requireCurrent(isCurrent) }; return validateNativeWatchedMigrationPending(unresolved) }
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
    private val snapshot = bytes.copyOf()
    val digest = watchedSHA(snapshot)
    fun bytes(): ByteArray = snapshot.copyOf()
    fun document(): JSONObject = NativeProfileOverlayWitness.parseDocument(snapshot)
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
    fun pending(reason: String): JSONObject = watchedHeader(scope, source.bytes(), locator).put("reason", reason)
}

internal fun validateNativeWatchedMigrationArchive(value: JSONArray): JSONArray = JSONArray().also { output ->
    val identities = mutableSetOf<String>()
    for (index in 0 until value.length()) {
        val evidence = NativeWatchedRowEvidence.replay(value.getJSONObject(index)) { true }
        val record = evidence.archive()
        val identity = listOf(record.getString("accountId"), record.getString("profileId"), record.optString("verifiedStreamingUid"),
            record.getString("sourceDocumentSha256"), record.getJSONObject("row").toString()).joinToString("\u0000")
        require(identities.add(identity)) { "Duplicate watched archive row" }
        output.put(record)
    }
}

/** Pending rows retain undecoded originals with truthful failure status. They grant no watched
 * authority and must never be acknowledged as an empty completed migration. */
internal fun validateNativeWatchedMigrationPending(value: JSONArray): JSONArray = JSONArray().also { output ->
    for (index in 0 until value.length()) {
        val record = value.getJSONObject(index)
        val keys = setOf("schemaVersion", "accountId", "profileId", "ownerProfileId", "sourceDocumentBase64", "sourceDocumentSha256", "row", "reason")
        require(record.keys().asSequence().toSet() == keys + if (record.has("verifiedStreamingUid")) setOf("verifiedStreamingUid") else emptySet())
        require(record.get("schemaVersion") is Number && record.getDouble("schemaVersion") == 1.0)
        require(record.getString("reason") in setOf("episode_inventory_unavailable", "episode_inventory_ambiguous"))
        val scope = WatchedEvidence.Scope(record.getString("accountId"), record.getString("profileId"),
            record.opt("verifiedStreamingUid") as? String, record.getString("ownerProfileId"))
        val source = watchedDecode64(record.getString("sourceDocumentBase64"))
        require(watchedSHA(source) == record.getString("sourceDocumentSha256")) { "Pending watched evidence digest mismatch" }
        val locator = watchedLocator(record.getJSONObject("row"))
        WatchedEvidence.validateSource(scope, source, locator)
        requireWatchedSourceCredentialFree(scope, source)
        output.put(watchedHeader(scope, source, locator).put("reason", record.getString("reason")))
    }
}

private fun watchedHeader(scope: WatchedEvidence.Scope, source: ByteArray, locator: WatchedLocator): JSONObject = JSONObject()
    .put("schemaVersion", 1).put("accountId", scope.accountID).put("profileId", scope.profileID).put("ownerProfileId", scope.ownerProfileID)
    .put("sourceDocumentBase64", watchedEncode64(source)).put("sourceDocumentSha256", watchedSHA(source)).put("row", watchedLocatorJSON(locator))
    .also { scope.verifiedStreamingUID?.let { uid -> it.put("verifiedStreamingUid", uid) } }

private fun watchedLocatorJSON(locator: WatchedLocator): JSONObject {
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
private fun watchedLocator(row: JSONObject): WatchedLocator {
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

private fun requireWatchedCredentialFree(evidence: WatchedEvidence.Evidence) {
    requireWatchedSourceCredentialFree(evidence.scope, evidence.source)
    val metadata = NativeProfileOverlayWitness.parseDocument(evidence.metadata)
    // Episode IDs/names are literal media slots too. The generic credential scanner still checks
    // valid encoded JSON and every unknown field; the retained raw metadata is never rewritten.
    val videos = metadata.getJSONObject("meta").getJSONArray("videos")
    for (index in 0 until videos.length()) videos.getJSONObject(index).put("type", "series")
    requireOwnAccountSourceCredentialFree(metadata)
    requireOwnAccountSourceCredentialFree(JSONObject().put("manifest", NativeProfileOverlayWitness.parseDocument(evidence.addon.manifest)))
}
private fun requireWatchedSourceCredentialFree(scope: WatchedEvidence.Scope, bytes: ByteArray) {
    val source = NativeProfileOverlayWitness.parseDocument(bytes)
    if (scope.verifiedStreamingUID == null) requireOwnAccountSourceCredentialFree(source)
    else for (key in listOf("libraryResponseBase64", "addonsResponseBase64", "profileOverlayBase64"))
        requireOwnAccountSourceCredentialFree(NativeProfileOverlayWitness.parseDocument(watchedDecode64(source.getString(key))))
}
private fun watchedSHA(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
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
private fun watchedDecode64(text: String): ByteArray = Base64.getDecoder().decode(text).also {
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
