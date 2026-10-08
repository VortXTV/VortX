package com.vortx.android.engine

import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.TimeUnit

/** Immutable proof from the authenticated producer, never constructible from a bare claimed UID. */
internal class NativeOwnAccountSource private constructor(
    val accountID: String,
    val profileID: String,
    val verifiedUID: String,
    val credentialTransactionID: String?,
    bytes: ByteArray,
    private val authority: NativeOwnAccountCredentials.Authority,
) {
    private val bytes = bytes.copyOf()
    val digest: String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    val overlayDigest: String = NativeProfileOverlayWitness.digest(decodeOwnEnvelope(bytes).third)
    fun proof(): JSONObject = withActive { JSONObject().put("verifiedStreamingUid", verifiedUID)
        .put("sourceDocumentSha256", digest).also {
            if (ownObject(bytes).getInt("schemaVersion") == 2) it.put("profileOverlaySha256", overlayDigest)
        } }
    fun archiveBase64(): String = withActive { Base64.getEncoder().encodeToString(bytes) }
    fun <T> withActive(action: () -> T): T = authority.withActive(action)
    fun requireOverlayUnchanged(document: JSONObject) = withActive {
        require(NativeProfileOverlayWitness.digest(nativeOwnAccountOverlay(document, profileID)) == overlayDigest) {
            "Own-account overlay changed during authenticated source capture"
        }
    }

    /** Compatibility projection happens AFTER hashing exact raw HTTP response bytes. */
    fun legacyDocument(): JSONObject = withActive {
        val (library, addons, overlay) = decodeOwnEnvelope(bytes)
        require(library.keys().asSequence().toSet() == setOf("result") && addons.keys().asSequence().toSet() == setOf("result"))
        requireOwnAccountSourceCredentialFree(library); requireOwnAccountSourceCredentialFree(addons)
        val rows = library.getJSONArray("result")
        val descriptors = addons.getJSONObject("result").also { require(it.keys().asSequence().toSet() == setOf("addons")) }.getJSONArray("addons")
        val projected = JSONArray()
        for (index in 0 until rows.length()) projected.put(projectLibrary(rows.getJSONObject(index)))
        val order = JSONArray()
        for (index in 0 until descriptors.length()) {
            val addon = descriptors.getJSONObject(index)
            order.put(ownString(addon, "transportUrl"))
            val manifest = addon.getJSONObject("manifest")
            for (key in listOf("id", "name", "version")) ownString(manifest, key)
        }
        require(NativeHostPreferences.equal(nativeOwnAccountOverlay(overlay, profileID), overlay)) { "Foreign own-account overlay carrier" }
        requireOwnAccountSourceCredentialFree(overlay)
        val vortx = overlay.optJSONObject("vortx") ?: JSONObject().also { overlay.put("vortx", it) }
        // No known producer writes own saved-membership intents here. Do not reinterpret an
        // invented nested carrier as owner-global tombstones.
        vortx.optJSONObject("byProfile")?.optJSONObject(profileID)?.let { bucket ->
            require(!bucket.has("deletedLibraryTs") && !bucket.has("deletedLibrary")) { "Unsupported own library intent carrier" }
        }
        vortx.put("library", projected).put("addons", descriptors)
        overlay.put("addonOrder", order)
    }
    private fun projectLibrary(raw: JSONObject): JSONObject {
        val row = JSONObject().put("id", ownString(raw, "_id")).put("type", ownString(raw, "type"))
        for (field in listOf("name", "poster")) if (raw.has(field) && !raw.isNull(field)) row.put(field, raw.get(field) as? String ?: error("Invalid library text"))
        for (field in listOf("removed", "temp")) if (raw.has(field) && !raw.isNull(field)) {
            val value = raw.get(field) as? Boolean ?: error("Invalid library membership")
            row.put(field, value)
        }
        if (raw.has("state") && !raw.isNull("state")) {
            val state = raw.getJSONObject("state")
            for ((from, to) in listOf("timeOffset" to "t", "duration" to "d")) if (state.has(from) && !state.isNull(from)) {
                row.put(to, BigDecimal(ownUnsigned(state, from, 9_007_199_254_740_990L)).divide(BigDecimal(1000)))
            }
            for ((from, to) in listOf("lastWatched" to "lastWatched", "video_id" to "v", "watched" to "watched")) {
                if (state.has(from) && !state.isNull(from)) row.put(to, state.get(from) as? String ?: error("Invalid library state text"))
            }
            if (state.has("timesWatched") && !state.isNull("timesWatched")) row.put("timesWatched", ownUnsigned(state, "timesWatched", 0xffff_ffffL))
            if (state.has("flaggedWatched") && !state.isNull("flaggedWatched")) row.put("currentVideoWatched", ownUnsigned(state, "flaggedWatched", 1) == 1L)
        }
        return row
    }
    companion object {
        /** Only a previously authenticated sealed host candidate may call this seam. The exact
         * immutable credential revision must still be available; never borrow a latest-UID slot. */
        internal fun fromRetained(capture: NativeOwnAccountCredentials.Capture, bytes: ByteArray): NativeOwnAccountSource =
            capture.authority.withActive {
                NativeOwnAccountSource(capture.accountID, capture.profileID, capture.verifiedUID, capture.transactionID,
                    bytes, capture.authority).also { it.legacyDocument() }
            }
        internal fun fromFetched(capture: NativeOwnAccountCredentials.Capture, uid: String, library: ByteArray, addons: ByteArray, overlay: ByteArray,
                                 witnessedOverlay: Boolean = true): NativeOwnAccountSource = capture.authority.withActive {
            requireNativeStreamingUID(uid); require(uid == capture.verifiedUID) { "Streaming credential identity changed" }
            // Sorted keys and ordinary JSON strings match the shared Apple framing. The digest is
            // over THESE bytes; another platform must retain rather than reserialize this envelope.
            val encoded = "{\"addonsResponseBase64\":" + JSONObject.quote(Base64.getEncoder().encodeToString(addons)) +
                ",\"libraryResponseBase64\":" + JSONObject.quote(Base64.getEncoder().encodeToString(library)) +
                ",\"profileOverlayBase64\":" + JSONObject.quote(Base64.getEncoder().encodeToString(overlay)) +
                ",\"schemaVersion\":" + (if (witnessedOverlay) 2 else 1) + "}"
            NativeOwnAccountSource(capture.accountID, capture.profileID, uid, capture.transactionID,
                encoded.toByteArray(Charsets.UTF_8), capture.authority).also { it.legacyDocument() }
        }
    }
}

internal class NativeOwnAccountProducer(private val send: suspend (String, JSONObject) -> ByteArray = NativeOwnAccountHTTP()::post) {
    suspend fun signIn(credentials: NativeOwnAccountCredentials, account: SessionOwnerSnapshot.Account, profileID: String,
                       email: String, password: String, accountAdmission: (() -> Boolean) -> Boolean,
                       transactionID: String? = null): NativeOwnAccountCredentials.Capture {
        val attempt = credentials.begin(account, profileID, accountAdmission, transactionID)
        val login = ownObject(send("login", JSONObject().put("email", email).put("password", password)))
        attempt.authority.withActive {}
        val result = ownResult(login); val token = ownString(result, "authKey")
        val uid = identity(send("getUser", JSONObject().put("authKey", token)))
        return attempt.authority.withActive {
            credentials.storeVerified(attempt, token, uid)
        }
    }
    suspend fun fetch(capture: NativeOwnAccountCredentials.Capture, authenticatedDocument: JSONObject,
                      witnessedOverlay: Boolean = true): NativeOwnAccountSource {
        val overlay = capture.authority.withActive {
            nativeOwnAccountOverlay(authenticatedDocument, capture.profileID).toString().toByteArray(Charsets.UTF_8)
        }
        val uid = identity(send("getUser", capture.request(JSONObject())))
        capture.authority.withActive { require(uid == capture.verifiedUID) { "Streaming identity changed" } }
        val library = send("datastoreGet", capture.request(JSONObject().put("collection", "libraryItem").put("all", true)))
        capture.authority.withActive {}
        val addons = send("addonCollectionGet", capture.request(JSONObject().put("update", false)))
        return NativeOwnAccountSource.fromFetched(capture, uid, library, addons, overlay, witnessedOverlay)
    }
    private fun identity(bytes: ByteArray): String {
        val user = ownResult(ownObject(bytes))
        val uid = (user.opt("_id") as? String) ?: (user.opt("id") as? String) ?: error("Authenticated streaming identity missing")
        if (user.has("_id") && user.has("id")) require(user.get("_id") == user.get("id"))
        return uid.also(::requireNativeStreamingUID)
    }
}

/** Exact UUID-qualified authenticated VortX slice. Never folds owner/global membership into it. */
internal fun nativeOwnAccountOverlay(document: JSONObject, profileID: String): JSONObject {
    fun member(root: JSONObject?, key: String): JSONObject? = if (root == null || !root.has(key) || root.isNull(key)) null else root.getJSONObject(key)
    fun own(root: JSONObject?): Any? {
        if (root == null) return null
        val matches = root.keys().asSequence().filter { it.equals(profileID, true) }.toList()
        require(matches.isEmpty() || matches == listOf(profileID)) { "Ambiguous own-account overlay identity" }
        return if (root.has(profileID)) root.get(profileID) else null
    }
    val result = JSONObject()
    own(member(member(document, "vortx"), "byProfile"))?.let {
        require(it is JSONObject) { "Malformed own-account watch overlay" }
        // Strict copies preserve original decimal values. Platform JSONObject(String) can round
        // them before witness framing, changing provenance or blessing unsafe fractions.
        result.put("vortx", JSONObject().put("byProfile", JSONObject().put(profileID,
            NativeProfileOverlayWitness.parseDocument(it.toString().toByteArray(Charsets.UTF_8)))))
    }
    own(member(member(member(document, "webProgress"), "removed"), "byProfile"))?.let {
        require(it is JSONArray) { "Malformed own-account watch removals" }
        result.put("webProgress", JSONObject().put("removed", JSONObject().put("byProfile", JSONObject().put(profileID,
            NativeProfileOverlayWitness.parse(it.toString().toByteArray(Charsets.UTF_8))))))
    }
    return result
}

/** A cold peer may reuse only a baseline accepted by the real kernel, never arbitrary archived
 * JSON or an email/UID claim. Raw source bytes and the other device's credentials are unnecessary. */
internal class NativeOwnAccountBaseline private constructor(val scope: VortxAccountScope, private val material: JSONObject,
                                                           private val sourceOverlays: Map<String, JSONObject>) {
    fun profileIDs(): Set<String> = material.getJSONObject("ownAccountSources").keys().asSequence().toSet()
    fun proof(id: String): JSONObject = JSONObject(material.getJSONObject("ownAccountSources").getJSONObject(id).toString())
    fun bucket(kind: String, id: String): Any = when (val value = material.getJSONObject(kind).get(id)) {
        is JSONObject -> JSONObject(value.toString())
        is JSONArray -> JSONArray(value.toString())
        else -> error("Invalid retained own-account bucket")
    }
    /** No raw source reconstruction: only a hash-bound archived source proves a nonempty overlay
     * unchanged. A true cold peer still displays validated native state; unproven legacy overlays
     * remain pending until a new authenticated fetch or a kernel-supported overlay witness. */
    fun requireOverlayUnchanged(document: JSONObject, id: String) {
        val current = nativeOwnAccountOverlay(document, id)
        val witness = proof(id).optString("profileOverlaySha256").takeIf { it.isNotEmpty() }
        val acknowledged = sourceOverlays[id]
        require(if (witness != null) NativeProfileOverlayWitness.digest(current) == witness
            else acknowledged != null && NativeHostPreferences.equal(current, acknowledged)) {
            "Own-account overlay requires an authenticated source refresh"
        }
    }
    companion object {
        fun validate(bindings: VortxRuntimeBindings, scope: VortxAccountScope, document: JSONObject,
                     retainedSourceEnvelopes: Map<String, ByteArray> = emptyMap(), activeBindings: Boolean = true,
                     priorDocument: JSONObject? = null, retainedSourceUIDs: Map<String, String> = emptyMap()): NativeOwnAccountBaseline {
            require(document.getInt("schemaVersion") in 1..5 && document.getString("scope") == scope.accountID &&
                document.getString("ownerProfileId") == scope.ownerProfileID)
            return VortxNativeRuntime.create(bindings, scope.ownerProfileID, "Owner").use { runtime ->
                for (action in listOfNotNull(JSONObject().put("type", "bind_sync_scope").put("scope", scope.accountID),
                    priorDocument?.let { JSONObject().put("type", "merge_native_sync").put("document", it) },
                    JSONObject().put("type", "merge_native_sync").put("document", document))) {
                    check(JSONObject(runtime.dispatch(action.toString())).getBoolean("ok")) { "Native own-account document rejected" }
                }
                val validated = JSONObject(runtime.stateJson()).getJSONObject("nativeSync")
                require(validated.getInt("schemaVersion") in 3..5)
                val receipt = validated.getJSONObject("legacyImport")
                require(receipt.getInt("schemaVersion") in 1..2)
                val baseline = JSONObject(receipt.getJSONObject("baseline").toString())
                require(baseline.getInt("schemaVersion") in 1..2)
                if (!baseline.has("ownAccountSources")) baseline.put("ownAccountSources", JSONObject())
                // Rebound profiles use their ACTIVE slot's canonical carrier. Original import
                // material remains historical evidence, never authority for the newly selected UID.
                validated.optJSONObject("accountSlots")?.takeIf { activeBindings }?.let { slots ->
                    slots.keys().forEach { id ->
                        val entry = slots.getJSONObject(id); val binding = entry.getJSONObject("activeBinding")
                        val account = binding.getJSONObject("account")
                        if (account.getString("kind") == "own") {
                            val matches = entry.getJSONObject("slots").let { all -> all.keys().asSequence()
                                .map { all.getJSONObject(it) }.filter { NativeHostPreferences.equal(it.getJSONObject("account"), account) }.toList() }
                            val carrier = matches.single().optJSONObject("sourceBaseline")
                            if (carrier == null) {
                                baseline.getJSONObject("ownAccountSources").remove(id)
                            } else {
                                baseline.getJSONObject("ownAccountSources").put(id, carrier.getJSONObject("source"))
                                for ((kind, field) in listOf("addons" to "addons", "libraries" to "library", "watches" to "watches", "identityLinks" to "identityLinks"))
                                    baseline.getJSONObject(kind).put(id, carrier.get(field))
                            }
                        } else baseline.getJSONObject("ownAccountSources").remove(id)
                    }
                }
                val proofs = baseline.getJSONObject("ownAccountSources")
                val overlays = retainedSourceEnvelopes.filterKeys { proofs.has(it) }.mapNotNull { (id, bytes) ->
                    val immutableBytes = bytes.copyOf()
                    val proof = proofs.getJSONObject(id)
                    val digest = MessageDigest.getInstance("SHA-256").digest(immutableBytes).joinToString("") { "%02x".format(it) }
                    val selected = digest == proof.getString("sourceDocumentSha256") &&
                        (retainedSourceUIDs[id] == null || retainedSourceUIDs[id] == proof.getString("verifiedStreamingUid"))
                    val historical = validated.getJSONObject("legacyImport").optJSONObject("ownAccountSourceHistory")
                        ?.optJSONObject(id)?.has(digest) == true || validated.optJSONObject("accountSlots")?.optJSONObject(id)
                        ?.getJSONObject("slots")?.let { slots -> slots.keys().asSequence().any {
                            slots.getJSONObject(it).optJSONObject("sourceHistory")?.has(digest) == true
                        } } == true
                    require(selected || historical) { "Retained own-account source changed" }
                    val (library, addons, overlay) = decodeOwnEnvelope(immutableBytes)
                    val version = ownObject(immutableBytes).getInt("schemaVersion")
                    if (selected && proof.has("profileOverlaySha256")) require(version == 2 &&
                        proof.getString("profileOverlaySha256") == NativeProfileOverlayWitness.digest(overlay)) { "Retained overlay witness changed" }
                    requireOwnAccountSourceCredentialFree(library); requireOwnAccountSourceCredentialFree(addons)
                    requireOwnAccountSourceCredentialFree(overlay)
                    require(NativeHostPreferences.equal(nativeOwnAccountOverlay(overlay, id), overlay)) { "Foreign retained own-account overlay" }
                    if (selected) id to overlay else null
                }.toMap()
                NativeOwnAccountBaseline(scope, JSONObject(baseline.toString()), overlays)
            }
        }
    }
}

private fun decodeOwnEnvelope(bytes: ByteArray): Triple<JSONObject, JSONObject, JSONObject> {
    val envelope = ownObject(bytes)
    require(envelope.keys().asSequence().toSet() == setOf("schemaVersion", "libraryResponseBase64", "addonsResponseBase64", "profileOverlayBase64"))
    require(envelope.get("schemaVersion") is Number && envelope.getDouble("schemaVersion") in listOf(1.0, 2.0))
    fun decoded(key: String): JSONObject {
        val text = envelope.get(key) as? String ?: error("Malformed streaming response carrier")
        val decoded = Base64.getDecoder().decode(text)
        require(Base64.getEncoder().encodeToString(decoded) == text)
        return ownObject(decoded)
    }
    val overlay = decoded("profileOverlayBase64")
    if (envelope.getInt("schemaVersion") == 2) NativeProfileOverlayWitness.digest(overlay)
    return Triple(decoded("libraryResponseBase64"), decoded("addonsResponseBase64"), overlay)
}

/** Exact token-free source bytes are adjacent sealed host evidence, never native wire. The
 * specialized validator preserves ordinary media text while rejecting encoded credentials. */
internal fun validateNativeOwnAccountArchive(value: JSONObject): JSONObject {
    value.keys().forEach { id ->
        require(java.util.UUID.fromString(id).toString().uppercase() == id)
        val record = value.getJSONObject(id)
        require(record.keys().asSequence().toSet() == setOf("verifiedStreamingUid", "sourceDocumentBase64"))
        requireNativeStreamingUID(record.getString("verifiedStreamingUid"))
        val encoded = record.getString("sourceDocumentBase64")
        val bytes = Base64.getDecoder().decode(encoded)
        require(Base64.getEncoder().encodeToString(bytes) == encoded)
        val (library, addons, overlay) = decodeOwnEnvelope(bytes)
        listOf(library, addons, overlay).forEach(::requireOwnAccountSourceCredentialFree)
        require(NativeHostPreferences.equal(nativeOwnAccountOverlay(overlay, id), overlay))
    }
    return JSONObject(value.toString())
}

/** Hold every exact credential generation across material construction AND native commit. */
internal fun <T> withNativeOwnAccountSources(sources: List<NativeOwnAccountSource>, action: () -> T): T {
    fun enter(index: Int): T = if (index == sources.size) action() else sources[index].withActive { enter(index + 1) }
    return enter(0)
}

/** Fixed-origin, bounded, read-only source requests. No auth headers, logs, redirects or disk cache. */
private class NativeOwnAccountHTTP {
    private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .callTimeout(20, TimeUnit.SECONDS).build()
    suspend fun post(path: String, body: JSONObject): ByteArray = withContext(Dispatchers.IO) {
        require(path in setOf("login", "getUser", "datastoreGet", "addonCollectionGet"))
        val request = Request.Builder().url("https://api.strem.io/api/$path")
            .post(body.toString().toRequestBody("application/json".toMediaType())).build()
        client.newCall(request).execute().use { response ->
            check(response.isSuccessful) { "Streaming account request failed" }
            val input = requireNotNull(response.body).byteStream()
            val bytes = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(8192)
            while (true) { val count = input.read(chunk); if (count < 0) break
                check(bytes.size() + count <= 8 * 1024 * 1024) { "Streaming response exceeds limit" }; bytes.write(chunk, 0, count) }
            bytes.toByteArray()
        }
    }
}

private fun ownObject(bytes: ByteArray): JSONObject {
    return NativeProfileOverlayWitness.parseDocument(bytes)
}
private fun ownString(value: JSONObject, key: String): String = (value.get(key) as? String)?.takeIf(String::isNotBlank) ?: error("Malformed streaming response")
private fun ownResult(value: JSONObject): JSONObject {
    require(!value.has("error") || value.isNull("error")) { "Streaming account request rejected" }; return value.getJSONObject("result")
}
private fun ownUnsigned(value: JSONObject, key: String, max: Long): Long {
    require(value.get(key) is Number)
    return BigDecimal(value.get(key).toString()).longValueExact().also { require(it in 0..max) }
}

/** Known media names/IDs are literal text, not backup carriers: e.g. "Independent title" happens
 * to decode as base64 beginning with a quote followed by invalid UTF-8. Mask ONLY schema-qualified
 * text slots for credential inspection; keep the exact original response in the sealed source.
 * Unknown fields still undergo the full recursive encoded-carrier scanner. */
internal fun requireOwnAccountSourceCredentialFree(source: JSONObject) {
    fun literal(value: String): String {
        if (value.trimStart().firstOrNull() in setOf('{', '[', '"')) return value
        val candidate = value.filterNot { it in " \t\r\n" }
        val decoder = if (candidate.any { it == '-' || it == '_' }) Base64.getUrlDecoder() else Base64.getDecoder()
        val bytes = runCatching { decoder.decode(candidate) }.getOrNull() ?: return value
        if (bytes.firstOrNull { it.toInt().toChar() !in " \t\r\n" }?.toInt()?.toChar() !in setOf('{', '[', '"')) return value
        val utf8 = runCatching { Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)) }.isSuccess
        // Valid encoded JSON (including credentials hidden in a title) is still inspected.
        return if (utf8) value else "literal media text!"
    }
    fun inspect(value: Any?, manifest: Boolean = false): Any? = when (value) {
        is JSONObject -> JSONObject(value.toString()).also { copy ->
            val media = (copy.has("_id") || copy.has("id")) && copy.opt("type") in setOf("movie", "series")
            val manifestShape = manifest && copy.has("id") && copy.has("name") && copy.has("version")
            val literalFields = if (media) setOf("_id", "id", "type", "name", "poster", "background", "logo", "lastWatched", "v")
                else if (manifestShape) setOf("id", "name", "version", "description", "logo", "background") else emptySet()
            for (key in copy.keys().asSequence().toList()) {
                val child = copy.get(key)
                if (key in literalFields && child is String) copy.put(key, literal(child))
                else if (media && key == "state" && child is JSONObject) {
                    val state = JSONObject(child.toString())
                    for (field in listOf("video_id", "lastWatched", "watched")) if (state.opt(field) is String) state.put(field, literal(state.getString(field)))
                    copy.put(key, inspect(state))
                } else copy.put(key, inspect(child, key == "manifest"))
            }
        }
        is JSONArray -> JSONArray().also { out -> for (index in 0 until value.length()) out.put(inspect(value.get(index))) }
        else -> value
    }
    NativeHostDocument.requireCredentialFree(inspect(source) as JSONObject)
}
