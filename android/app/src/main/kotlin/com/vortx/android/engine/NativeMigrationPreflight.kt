package com.vortx.android.engine

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Sealed setup evidence, deliberately not a native runtime or a published account locator. */
internal class NativeMigrationPreflight private constructor(val scope: VortxAccountScope, val raw: String) {
    private val value get() = NativeProfileOverlayWitness.parseDocument(raw.toByteArray(Charsets.UTF_8))
    val id: String get() = value.getString("id")
    val archive: JSONObject get() = value.getJSONObject("hostArchive")
    val candidates: JSONArray get() = value.getJSONArray("ownCandidates")

    companion object {
        fun create(scope: VortxAccountScope, archive: JSONObject, sources: List<NativeOwnAccountSource>,
                   retainedCandidates: JSONArray? = null): NativeMigrationPreflight {
            val candidates = JSONArray()
            retainedCandidates?.let { prior -> for (index in 0 until prior.length()) {
                val candidate = prior.getJSONObject(index)
                if (sources.none { it.profileID == candidate.getString("profileId") }) candidates.put(candidate)
            } }
            sources.forEach { source -> source.withActive {
                require(source.accountID == scope.accountID)
                candidates.put(JSONObject().put("profileId", source.profileID).put("verifiedStreamingUid", source.verifiedUID)
                    .put("transactionId", source.credentialTransactionID ?: JSONObject.NULL)
                    .put("sourceDocumentBase64", source.archiveBase64()))
            } }
            val json = JSONObject().put("format", "vortx-native-preflight-v1").put("id", UUID.randomUUID().toString())
                .put("scope", scope.accountID).put("ownerProfileId", scope.ownerProfileID)
                .put("hostArchive", archive).put("ownCandidates", candidates)
            return parse(scope, nativeWatchedDocumentSnapshot(json).toString(Charsets.UTF_8))
        }

        fun parse(scope: VortxAccountScope, raw: String): NativeMigrationPreflight {
            val json = NativeProfileOverlayWitness.parseDocument(raw.toByteArray(Charsets.UTF_8))
            require(json.keys().asSequence().toSet() == setOf("format", "id", "scope", "ownerProfileId", "hostArchive", "ownCandidates"))
            require(json.getString("format") == "vortx-native-preflight-v1" && json.getString("scope") == scope.accountID &&
                json.getString("ownerProfileId") == scope.ownerProfileID)
            require(UUID.fromString(json.getString("id")).toString() == json.getString("id"))
            val archive = json.getJSONObject("hostArchive")
            require(archive.keys().asSequence().toSet() == setOf("document", "excludedCredentialPaths"))
            NativeHostDocument.requireCredentialFree(archive.getJSONObject("document"))
            val excluded = archive.getJSONArray("excludedCredentialPaths")
            for (i in 0 until excluded.length()) require(excluded.get(i) is String)
            val candidates = json.getJSONArray("ownCandidates")
            val ids = mutableSetOf<String>()
            for (i in 0 until candidates.length()) {
                val entry = candidates.getJSONObject(i)
                require(entry.keys().asSequence().toSet() == setOf("profileId", "verifiedStreamingUid", "transactionId", "sourceDocumentBase64"))
                val id = entry.getString("profileId")
                require(ids.add(id) && id != scope.ownerProfileID)
                val txn = entry.get("transactionId")
                require(txn == JSONObject.NULL || txn is String && UUID.fromString(txn).toString() == txn)
                validateNativeOwnAccountArchive(JSONObject().put(id, JSONObject()
                    .put("verifiedStreamingUid", entry.getString("verifiedStreamingUid"))
                    .put("sourceDocumentBase64", entry.getString("sourceDocumentBase64"))))
            }
            for (key in listOf("nativeWatchedMigrationEvidence", "nativeWatchedMigrationPending")) {
                val records = archive.getJSONObject("document").optJSONArray(key) ?: continue
                for (i in 0 until records.length()) require(records.getJSONObject(i).let {
                    it.getString("accountId") == scope.accountID && it.getString("ownerProfileId") == scope.ownerProfileID
                })
            }
            return NativeMigrationPreflight(scope, raw)
        }
    }
}

/** Sidecars are not part of the legacy source being hashed. Never recursively archive evidence
 * inside its next consumed source snapshot. The original cloud fields remain otherwise intact. */
internal fun nativeMigrationSourceDocument(document: JSONObject): JSONObject =
    NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(document)).also { source ->
        nativeMigrationSidecars.forEach(source::remove)
    }

internal val nativeMigrationSidecars = setOf("authenticatedOwnAccountSources", "nativeOwnAccountPending", "nativeOwnAccountCandidates",
    "nativeWatchedMigrationEvidence", "nativeWatchedMigrationPending", "nativeWatchlistMigrationPending")

internal fun validateNativeOwnAccountCandidates(value: JSONObject): JSONObject {
    value.keys().forEach { id ->
        require(UUID.fromString(id).toString().uppercase() == id)
        val record = value.getJSONObject(id)
        require(record.keys().asSequence().toSet() == setOf("verifiedStreamingUid", "transactionId", "sourceDocumentBase64", "expectedBinding", "profile", "historicalOverlayDigest"))
        NativeAccountBinding.requireTransactionID(record.getString("transactionId"))
        NativeAccountBinding.parse(record.getJSONObject("expectedBinding"))
        require(record.getString("historicalOverlayDigest").matches(Regex("[0-9a-f]{64}")))
        require(record.getJSONObject("profile").getString("id") == id)
        NativeHostDocument.requireCredentialFree(record.getJSONObject("profile"))
        validateNativeOwnAccountArchive(JSONObject().put(id, JSONObject()
            .put("verifiedStreamingUid", record.getString("verifiedStreamingUid"))
            .put("sourceDocumentBase64", record.getString("sourceDocumentBase64"))))
    }
    return NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(value))
}

internal fun nativeWatchedRecordIdentity(record: JSONObject): String = listOf(record.getString("accountId"),
    record.getString("ownerProfileId"), record.getString("profileId"), record.optString("verifiedStreamingUid"),
    record.getString("sourceDocumentSha256"), record.getJSONObject("row").toString()).joinToString("\u0000")

internal fun mergeNativeWatchedArchive(scope: VortxAccountScope, prior: JSONObject?, next: JSONObject,
                                     evidence: JSONArray, pending: JSONArray) {
    fun merged(key: String, added: JSONArray, validate: (JSONArray) -> JSONArray): JSONArray {
        val unique = linkedMapOf<String, JSONObject>()
        for (array in listOf(prior?.optJSONArray(key) ?: JSONArray(), added)) {
            val checked = validate(array)
            for (index in 0 until checked.length()) {
                val record = checked.getJSONObject(index)
                require(record.getString("accountId") == scope.accountID && record.getString("ownerProfileId") == scope.ownerProfileID)
                unique.putIfAbsent(nativeWatchedRecordIdentity(record), record)
            }
        }
        return JSONArray(unique.values.toList())
    }
    val accepted = merged("nativeWatchedMigrationEvidence", evidence, ::validateNativeWatchedMigrationArchive)
    val completed = (0 until accepted.length()).map { nativeWatchedRecordIdentity(accepted.getJSONObject(it)) }.toSet()
    val unresolved = merged("nativeWatchedMigrationPending", pending, ::validateNativeWatchedMigrationPending)
    next.put("nativeWatchedMigrationEvidence", accepted)
    next.put("nativeWatchedMigrationPending", JSONArray((0 until unresolved.length()).map(unresolved::getJSONObject)
        .filterNot { nativeWatchedRecordIdentity(it) in completed }))
}
