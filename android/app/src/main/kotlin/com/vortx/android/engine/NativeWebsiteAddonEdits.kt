package com.vortx.android.engine

import java.math.BigDecimal
import java.math.BigInteger
import org.json.JSONArray
import org.json.JSONObject

/** Immutable website source admission only. The kernel owns causal membership/order merging,
 * account-binding checks and receipts. An acknowledged stale event need not win a register. */
internal object NativeWebsiteAddonEdits {
    internal class Conflict(message: String) : IllegalArgumentException(message)
    private val eventKeys = setOf("schemaVersion", "eventId", "counter", "wallTime", "scope", "ownerProfileId", "profileId", "expectedBinding", "observed", "mutations", "order")
    private val receiptKeys = setOf("schemaVersion", "eventId", "counter", "fingerprint", "scope", "ownerProfileId", "profileId", "expectedBinding")
    private val idPattern = Regex("[0-9a-f]{32}")
    private val hashPattern = Regex("[0-9a-f]{64}")
    private val counterPattern = Regex("0|[1-9][0-9]{0,19}")
    private val uint64Max = BigInteger("18446744073709551615")
    const val MAX_CLOCK = 9_007_199_254_740_990L
    const val MAX_EVENTS = 128
    const val MAX_BYTES = 2 * 1024 * 1024

    fun events(document: JSONObject, scope: VortxAccountScope): List<JSONObject> {
        if (!document.has("webAddonEdits")) return emptyList()
        val carrier = document.getJSONObject("webAddonEdits")
        require(carrier.keys().asSequence().toSet() == setOf("schemaVersion", "events") && integer(carrier.get("schemaVersion")) == 1L)
        val events = carrier.getJSONArray("events")
        require(events.length() <= MAX_EVENTS) { "Website add-on queue requires synchronization" }
        val ids = mutableSetOf<String>()
        // Validate original numeric nodes BEFORE any serialization; Android org.json can round
        // BigDecimal clocks through Double. Immutable raw manifest extensions remain present.
        val result = (0 until events.length()).map { index -> events.getJSONObject(index).also {
            validate(scope, it); require(ids.add(it.getString("eventId"))) { "Duplicate website add-on event ID" }
        } }
        require(nativeWatchedDocumentSnapshot(carrier).size <= MAX_BYTES) { "Website add-on queue exceeds bounds" }
        return result.map(::detached)
    }

    fun validate(scope: VortxAccountScope, event: JSONObject) {
        val keys = event.keys().asSequence().toSet()
        require(keys - "order" == eventKeys - "order") { "Unsupported website add-on event fields" }
        require(integer(event.get("schemaVersion")) == 1L && idPattern.matches(text(event, "eventId")))
        requireCounter(event.get("counter"))
        require(integer(event.get("wallTime")) <= System.currentTimeMillis() + 48L * 60 * 60 * 1000) { "Website add-on event is future-dated" }
        require(event.get("scope") == scope.accountID && event.get("ownerProfileId") == scope.ownerProfileID) { "Website add-on account changed" }
        require(event.get("profileId") is String && event.getString("profileId").isNotBlank())
        val binding = event.getJSONObject("expectedBinding")
        val account = binding.getJSONObject("account")
        require(account.get("kind") is String && (!account.has("value") || account.get("value") is String))
        NativeAccountBinding.parse(binding)
        val observed = event.getJSONObject("observed")
        require(observed.keys().asSequence().toSet() == setOf("records", "order"))
        val records = observed.getJSONObject("records")
        records.keys().forEach { url ->
            requireURL(url)
            val member = records.getJSONObject(url)
            require(member.keys().asSequence().toSet().let { it.containsAll(setOf("addedAt", "removedAt", "valueAt", "value")) &&
                it.all { key -> key in setOf("addedAt", "removedAt", "valueAt", "value", "webSources") } })
            for (field in listOf("addedAt", "removedAt", "valueAt")) integer(member.get(field))
            if (!member.isNull("value")) descriptor(member.getJSONObject("value"), url)
            if (member.has("webSources")) member.getJSONObject("webSources").let { sources -> sources.keys().forEach { field ->
                require(field in setOf("addedAt", "removedAt", "valueAt")); source(sources.getJSONObject(field))
            } }
        }
        val order = observed.getJSONObject("order")
        require(order.keys().asSequence().toSet().all { it in setOf("updatedAt", "ids", "webSource") })
        integer(order.get("updatedAt")); urls(order.getJSONArray("ids"))
        if (order.has("webSource")) source(order.getJSONObject("webSource"))
        val mutations = event.getJSONArray("mutations")
        val seen = mutableSetOf<String>()
        for (index in 0 until mutations.length()) {
            val mutation = mutations.getJSONObject(index)
            val url = text(mutation, "transportUrl"); requireURL(url); require(seen.add(url))
            when (text(mutation, "state")) {
                "present" -> {
                    require(mutation.keys().asSequence().toSet() == setOf("transportUrl", "state", "addon"))
                    descriptor(mutation.getJSONObject("addon"), url)
                }
                "removed" -> require(mutation.keys().asSequence().toSet() == setOf("transportUrl", "state"))
                else -> error("Unsupported website add-on mutation")
            }
        }
        if (event.has("order")) urls(event.getJSONArray("order"))
        require(mutations.length() > 0 || event.has("order")) { "Empty website add-on event" }
        scope.rejectCredentials(event)
        NativeHostDocument.requireCredentialFree(event)
        require(nativeWatchedDocumentSnapshot(event).size <= MAX_BYTES) { "Website add-on source exceeds bounds" }
    }

    fun action(scope: VortxAccountScope, event: JSONObject): JSONObject = JSONObject()
        .put("type", "apply_website_addon_edits").put("scope", scope.accountID)
        .put("ownerProfileId", scope.ownerProfileID).put("event", detached(event))

    fun receipt(scope: VortxAccountScope, event: JSONObject, response: JSONObject): JSONObject {
        validate(scope, event)
        if (response.opt("ok") != true) throw Conflict("Native website add-on event rejected")
        val results = response.optJSONArray("events") ?: throw Conflict("Native website add-on receipt missing")
        if (results.length() != 1) throw Conflict("Native website add-on receipt cardinality mismatch")
        val result = results.optJSONObject(0) ?: throw Conflict("Native website add-on result malformed")
        if (result.optString("event") != "website_addon_edits_applied") throw Conflict("Native website add-on result mismatch")
        val receipt = result.optJSONObject("receipt") ?: throw Conflict("Native website add-on receipt missing")
        // The trusted kernel computes JCS over the dispatched RAW event and checks replay hashes.
        // Do not reconstruct a fingerprint from a lossy typed manifest or skip dispatch by ID.
        require(receipt.opt("fingerprint") is String && hashPattern.matches(receipt.getString("fingerprint")))
        val expected = JSONObject().put("schemaVersion", 1).put("fingerprint", receipt.getString("fingerprint"))
        for (key in receiptKeys - setOf("schemaVersion", "fingerprint")) expected.put(key, event.get(key))
        require(receipt.keys().asSequence().toSet() == receiptKeys && NativeHostPreferences.equal(receipt, expected)) { "Native website add-on receipt/source mismatch" }
        return detached(receipt)
    }

    fun emptyPending(): JSONObject = JSONObject().put("events", JSONArray())
    /** Sealed historical sources participate even after a peer ACK pruned the cloud queue. */
    fun union(scope: VortxAccountScope, pending: JSONObject, incoming: List<JSONObject>): List<JSONObject> {
        validatePending(scope, pending)
        val result = mutableListOf<JSONObject>()
        val retained = pending.getJSONArray("events")
        for (event in (0 until retained.length()).map(retained::getJSONObject) + incoming) {
            validate(scope, event)
            if (result.none { NativeHostPreferences.equal(it, event) }) result += detached(event)
        }
        require(result.size <= MAX_EVENTS && nativeWatchedDocumentSnapshot(JSONObject().put("schemaVersion", 1).put("events", JSONArray(result))).size <= MAX_BYTES) {
            "Combined website add-on queue requires conflict resolution"
        }
        return result
    }
    fun validatePending(scope: VortxAccountScope, pending: JSONObject) {
        require(pending.keys().asSequence().toSet() == setOf("events"))
        val entries = pending.getJSONArray("events")
        require(entries.length() <= MAX_EVENTS && nativeWatchedDocumentSnapshot(pending).size <= MAX_BYTES) { "Website add-on pending queue exceeds bounds" }
        for (index in 0 until entries.length()) {
            val event = entries.getJSONObject(index); validate(scope, event)
            require((0 until index).none { NativeHostPreferences.equal(entries.getJSONObject(it), event) }) { "Duplicate pending website add-on source" }
        }
    }
    fun retain(scope: VortxAccountScope, pending: JSONObject, event: JSONObject): JSONObject {
        validatePending(scope, pending); validate(scope, event)
        val result = detached(pending); val entries = result.getJSONArray("events")
        if ((0 until entries.length()).none { NativeHostPreferences.equal(entries.getJSONObject(it), event) }) entries.put(detached(event))
        return result.also { validatePending(scope, it) }
    }
    fun remove(pending: JSONObject, event: JSONObject): JSONObject {
        return emptyPending().also { result ->
            val entries = pending.getJSONArray("events")
            for (index in 0 until entries.length()) entries.getJSONObject(index).let {
                if (!NativeHostPreferences.equal(it, event)) result.getJSONArray("events").put(detached(it))
            }
        }
    }
    private fun descriptor(value: JSONObject, url: String) {
        require(value.keys().asSequence().toSet().let { it.containsAll(setOf("transportUrl", "manifest")) && it.all { key -> key in setOf("transportUrl", "manifest", "flags") } })
        require(value.get("transportUrl") == url)
        value.getJSONObject("manifest") // Full raw manifest, including extensions, remains hash-bound.
        if (value.has("flags")) value.getJSONObject("flags").let { flags ->
            flags.keys().forEach { require(it in setOf("official", "protected") && flags.get(it) is Boolean) }
        }
    }
    private fun source(value: JSONObject) {
        require(value.keys().asSequence().toSet() == setOf("schemaVersion", "counter", "eventId", "fingerprint", "observedClock"))
        require(integer(value.get("schemaVersion")) == 1L && idPattern.matches(text(value, "eventId")) && hashPattern.matches(text(value, "fingerprint")))
        requireCounter(value.get("counter")); integer(value.get("observedClock"))
    }
    private fun urls(values: JSONArray) {
        val seen = mutableSetOf<String>()
        for (index in 0 until values.length()) { val url = values.get(index) as? String ?: error("Invalid add-on URL"); requireURL(url); require(seen.add(url)) }
    }
    private fun requireURL(url: String) {
        val uri = java.net.URI(url)
        require(url == url.trim() && uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.rawUserInfo == null && uri.rawFragment == null)
        require(uri.host == uri.host.lowercase()) { "Website add-on URL is not canonical" }
    }
    internal fun requireCounter(value: Any) {
        require(value is String && counterPattern.matches(value) && BigInteger(value) < uint64Max) { "Invalid website add-on counter" }
    }
    private fun integer(value: Any): Long {
        require(value is Number)
        return BigDecimal(value.toString()).longValueExact().also { require(it in 0..MAX_CLOCK) }
    }
    private fun text(value: JSONObject, key: String): String = value.get(key) as? String ?: error("Invalid website add-on string")
    fun detached(value: JSONObject): JSONObject = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(value))
}
