package com.vortx.android.engine

import org.json.JSONArray
import org.json.JSONObject
import com.vortx.android.engine.LegacyWatchedBitfieldMigrationEvidence as WatchedEvidence

/** Device-local journal only. Each source is retained exactly once; this is never nativeSync or
 * cloud material. Schema 1 inline rows remain readable. Schema 2 changes only source storage,
 * not the exact account/owner/profile/UID/row authority checked by the original replay. */
internal class NativeWatchedMigrationStorage private constructor(private val snapshot: String) {
    private fun json() = JSONObject(snapshot)
    fun sources(): JSONObject = json().getJSONObject(SOURCES)
    fun records(key: String): JSONArray = json().getJSONArray(key)
    fun inlineRecords(key: String): JSONArray {
        val value = json(); val pool = value.getJSONObject(SOURCES)
        return JSONArray().also { out ->
            val rows = value.getJSONArray(key)
            for (i in 0 until rows.length()) out.put(expand(rows.getJSONObject(i), pool))
        }
    }
    val unresolvedCount: Int get() {
        val value = json()
        val complete = (0 until value.getJSONArray(EVIDENCE).length()).map {
            nativeWatchedRecordIdentity(value.getJSONArray(EVIDENCE).getJSONObject(it))
        }.toSet()
        val pending = value.getJSONArray(PENDING)
        return (0 until pending.length()).count { nativeWatchedRecordIdentity(pending.getJSONObject(it)) !in complete }
    }
    fun writeTo(document: JSONObject) {
        val value = json()
        for (key in KEYS) document.put(key, value.get(key))
    }
    fun requireScope(scope: VortxAccountScope) {
        val value = json()
        for (key in listOf(EVIDENCE, PENDING)) {
            val rows = value.getJSONArray(key)
            for (i in 0 until rows.length()) require(rows.getJSONObject(i).let {
                it.getString("accountId") == scope.accountID && it.getString("ownerProfileId") == scope.ownerProfileID
            }) { "Archived watched migration belongs to another account scope" }
        }
    }

    class Builder {
        private val sources = JSONObject()
        private val material = mutableMapOf<String, WatchedEvidence.SourceMaterial>()
        private val scanned = mutableSetOf<String>()
        private val accepted = linkedMapOf<String, JSONObject>()
        private val pending = linkedMapOf<String, JSONObject>()
        private var retainedBytes = nativeWatchedDocumentSnapshot(JSONObject().put(SOURCES, JSONObject())
            .put(EVIDENCE, JSONArray()).put(PENDING, JSONArray())).size.toLong()
        fun add(storage: NativeWatchedMigrationStorage) {
            val pool = storage.sources()
            for (key in listOf(EVIDENCE, PENDING)) {
                val rows = storage.records(key)
                for (i in 0 until rows.length()) add(rows.getJSONObject(i), key, pool)
            }
        }
        fun evidence(record: JSONObject) = add(record, EVIDENCE, JSONObject())
        fun pending(record: JSONObject) = add(record, PENDING, JSONObject())
        internal fun add(record: JSONObject, key: String, pool: JSONObject) {
            val inline = expand(record, pool)
            val digest = inline.getString("sourceDocumentSha256")
            val encoded = inline.getString("sourceDocumentBase64")
            val source = material.getOrPut(digest) {
                val bytes = watchedDecode64(encoded)
                require(watchedSHA(bytes) == digest) { "Watched source pool digest mismatch" }
                WatchedEvidence.SourceMaterial(bytes)
            }
            require(source.base64 == encoded) { "Conflicting watched source digest" }
            val scope = WatchedEvidence.Scope(inline.getString("accountId"), inline.getString("profileId"),
                inline.opt("verifiedStreamingUid") as? String, inline.getString("ownerProfileId"))
            if (scanned.add(digest + if (scope.verifiedStreamingUID == null) ":shared" else ":own"))
                requireWatchedSourceCredentialFree(scope, source.bytes())
            val checked = if (key == EVIDENCE) NativeWatchedRowEvidence.replay(inline, source, false) { true }.archive()
                else validateNativeWatchedMigrationPending(JSONArray().put(inline), source, false).getJSONObject(0)
            val identity = nativeWatchedRecordIdentity(checked)
            checked.remove("sourceDocumentBase64"); checked.put("schemaVersion", 2)
            val destination = if (key == EVIDENCE) accepted else pending
            val prior = destination[identity]
            if (prior != null) {
                // A repeated exact capture is idempotent. Conflicting accepted metadata cannot
                // silently replace the first receipt for the same source-bound row. A pending
                // failure reason is historical, so retain its original record after retry.
                require(key == PENDING || canonical(prior) == canonical(checked)) { "Conflicting watched evidence row" }
            } else {
                val recordBytes = nativeWatchedDocumentSnapshot(checked).size.toLong() + if (destination.isEmpty()) 0 else 1
                val sourceBytes = if (sources.has(digest)) 0L else
                    JSONObject.quote(digest).toByteArray(Charsets.UTF_8).size.toLong() + 1 +
                        JSONObject.quote(encoded).toByteArray(Charsets.UTF_8).size + if (sources.length() == 0) 0 else 1
                require(retainedBytes + recordBytes + sourceBytes <= 16_777_216L) { "Watched journal exceeds retained document limit" }
                retainedBytes += recordBytes + sourceBytes
                destination[identity] = checked
            }
            sources.put(digest, encoded)
        }
        fun build(): NativeWatchedMigrationStorage {
            val value = JSONObject().put(SOURCES, sources).put(EVIDENCE, JSONArray(accepted.values.toList()))
                .put(PENDING, JSONArray(pending.values.toList()))
            // The same 16 MiB strict admission applies after compaction, never to an expanded
            // N-source intermediate. The containing host/preflight is checked independently.
            return NativeWatchedMigrationStorage(nativeWatchedDocumentSnapshot(value).toString(Charsets.UTF_8))
        }
    }

    companion object {
        const val SOURCES = "nativeWatchedMigrationSources"
        const val EVIDENCE = "nativeWatchedMigrationEvidence"
        const val PENDING = "nativeWatchedMigrationPending"
        val KEYS = setOf(SOURCES, EVIDENCE, PENDING)
        /** Presentation only, for an already admitted checkpoint/preflight. Never use this cheap
         * projection as source/evidence validation or native-import admission. Progress refreshes
         * must not reparse source documents and metadata on the UI thread. */
        fun unresolvedCountForStatus(document: JSONObject?): Int {
            val accepted = document?.optJSONArray(EVIDENCE) ?: JSONArray()
            val complete = (0 until accepted.length()).map { nativeWatchedRecordIdentity(accepted.getJSONObject(it)) }.toSet()
            val pending = document?.optJSONArray(PENDING) ?: JSONArray()
            return (0 until pending.length()).count { nativeWatchedRecordIdentity(pending.getJSONObject(it)) !in complete }
        }
        fun read(document: JSONObject?): NativeWatchedMigrationStorage {
            val input = document ?: JSONObject()
            val pool = if (input.has(SOURCES)) input.getJSONObject(SOURCES) else JSONObject()
            val referenced = mutableSetOf<String>()
            val builder = Builder()
            for (key in listOf(EVIDENCE, PENDING)) {
                val rows = if (input.has(key)) input.getJSONArray(key) else JSONArray()
                val identities = mutableSetOf<String>()
                for (i in 0 until rows.length()) {
                    val row = rows.getJSONObject(i)
                    if (row.optInt("schemaVersion") == 2) referenced += row.getString("sourceDocumentSha256")
                    val expanded = expand(row, pool)
                    // Reject duplicate/UUID-case aliases within one original array. Merging an
                    // exact receipt from two checkpoints is separately idempotent in Builder.
                    val scope = WatchedEvidence.Scope(expanded.getString("accountId"), expanded.getString("profileId"),
                        expanded.opt("verifiedStreamingUid") as? String, expanded.getString("ownerProfileId"))
                    expanded.put("profileId", scope.profileID).put("ownerProfileId", scope.ownerProfileID)
                    require(identities.add(nativeWatchedRecordIdentity(expanded))) { "Duplicate watched journal row" }
                    builder.add(row, key, pool)
                }
            }
            require(pool.keys().asSequence().toSet() == referenced) { "Orphan or missing watched source pool entry" }
            return builder.build()
        }
        private fun expand(record: JSONObject, pool: JSONObject): JSONObject {
            val row = JSONObject(record.toString())
            val schema = row.get("schemaVersion") as? Number ?: error("Malformed watched journal schema")
            require(schema.toDouble() == 1.0 || schema.toDouble() == 2.0) { "Unsupported watched journal schema" }
            val digest = row.getString("sourceDocumentSha256")
            require(digest.matches(Regex("[0-9a-f]{64}"))) { "Malformed watched source digest" }
            if (schema.toDouble() == 2.0) {
                require(!row.has("sourceDocumentBase64")) { "Ambiguous watched source storage" }
                row.put("sourceDocumentBase64", pool.getString(digest)).put("schemaVersion", 1)
            }
            return row
        }
        private fun canonical(record: JSONObject) = nativeWatchedDocumentSnapshot(record).toString(Charsets.UTF_8)
    }
}
