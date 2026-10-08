package com.vortx.android.integrations

import org.json.JSONObject
import java.util.UUID

/** Credential-only wire: never pass this carrier to a kernel, archive or diagnostic. */
internal class NativeProviderCredentials(val scope: String, sealed: String? = null) {
    private var local = sealed?.let(::JSONObject) ?: JSONObject()
        .put("actor", UUID.randomUUID().toString()).put("counter", 0L)
        .put("document", emptyDocument(scope)).put("pending", JSONObject()).put("auxiliary", JSONObject()).put("baseline", JSONObject())

    init {
        require(scope.startsWith("account.") && scope.removePrefix("account.").let(::validActor))
        require(local.keys().asSequence().toSet() == setOf("actor", "counter", "document", "pending", "auxiliary", "baseline"))
        require(validActor(local.getString("actor")))
        val maximum = clock(local.get("counter"))
        validate(local.getJSONObject("document"), scope)
        validate(emptyDocument(scope).put("fields", local.getJSONObject("pending")), scope)
        validate(emptyDocument(scope).put("fields", local.getJSONObject("baseline")), scope)
        require(fields().keys().asSequence().all { clock(fields().getJSONObject(it).get("clock")) <= maximum })
        require(pending().keys().asSequence().all { same(pending().getJSONObject(it), fields().optJSONObject(it)) })
        require(local.getJSONObject("auxiliary").keys().asSequence().all { it == "traktCreated" })
        local.getJSONObject("auxiliary").opt("traktCreated")?.let { require(it is String && validExpiry(it)) }
    }

    fun encoded(): String = local.toString()
    fun document(): JSONObject = JSONObject(local.getJSONObject("document").toString())
    fun value(key: String): String? = (fields().optJSONObject(key) ?: local.getJSONObject("baseline").optJSONObject(key))?.opt("value") as? String
    fun auxiliary(key: String): String? = local.getJSONObject("auxiliary").opt(key) as? String
    fun hasPending(): Boolean = pending().length() != 0
    fun events(keys: Set<String>): JSONObject = JSONObject().also { result ->
        keys.sorted().forEach { key -> (fields().optJSONObject(key) ?: local.getJSONObject("baseline").optJSONObject(key))?.let { result.put(key, JSONObject(it.toString())) } }
    }

    fun edit(values: Map<String, String?>, auxiliary: Map<String, String?> = emptyMap()) {
        require(values.isNotEmpty() && values.keys.all { it in KEYS })
        GROUPS.forEach { require(values.keys.intersect(it).let { touched -> touched.isEmpty() || touched == it }) }
        val next = JSONObject(local.toString())
        val counter = clock(next.get("counter"))
        require(counter < MAX_CLOCK)
        next.put("counter", counter + 1)
        values.forEach { (key, value) ->
            val event = JSONObject().put("clock", counter + 1).put("actor", next.getString("actor"))
                .put("value", value ?: JSONObject.NULL)
            next.getJSONObject("document").getJSONObject("fields").put(key, event)
            next.getJSONObject("pending").put(key, event)
        }
        auxiliary.forEach { (key, value) ->
            require(key == "traktCreated" && (value == null || validExpiry(value)))
            if (value == null) next.getJSONObject("auxiliary").remove(key) else next.getJSONObject("auxiliary").put(key, value)
        }
        validate(next.getJSONObject("document"), scope)
        local = next
    }

    /** Authenticated legacy values remain a secure fallback, never promoted to register authority. */
    fun merge(document: JSONObject) {
        val before = local
        local = JSONObject(local.toString())
        try { mergeDocument(document) } catch (failure: Exception) { local = before; throw failure }
    }

    private fun mergeDocument(document: JSONObject) {
        val wire = document.opt("nativeProviderCredentials")
        require(wire == null || wire is JSONObject)
        wire?.let { mergeWire(it as JSONObject) }
        val api = document.opt("apiKeys")
        require(api == null || api === JSONObject.NULL || api is JSONObject)
        if (api !is JSONObject) return
        val baseline = JSONObject(local.getJSONObject("baseline").toString())
        val metadata = api.opt("metadata")
        require(metadata == null || metadata === JSONObject.NULL || metadata is JSONObject)
        KEYS.forEach { key ->
            val direct = api.opt(key)
            val nested = if (key in METADATA) (metadata as? JSONObject)?.opt(key) else null
            listOf(direct, nested).forEach { require(it == null || it === JSONObject.NULL || it is String) }
            val a = (direct as? String)?.takeIf(String::isNotEmpty)
            val b = (nested as? String)?.takeIf(String::isNotEmpty)
            require(a == null || b == null || a == b)
            if (!fields().has(key)) (a ?: b)?.let { baseline.put(key,
                JSONObject().put("clock", 0L).put("actor", ZERO_ACTOR).put("value", it)) }
        }
        validate(emptyDocument(scope).put("fields", baseline), scope)
        local.put("baseline", baseline)
    }

    fun mergeWire(incoming: JSONObject) {
        validate(incoming, scope)
        val next = JSONObject(local.toString())
        val target = next.getJSONObject("document").getJSONObject("fields")
        val pending = next.getJSONObject("pending")
        incoming.getJSONObject("fields").let { source -> source.keys().forEach { key ->
            val event = source.getJSONObject(key)
            val old = target.optJSONObject(key)
            val comparison = if (old == null) 1 else compare(event, old)
            require(comparison != 0 || same(event, old))
            if (comparison > 0) {
                target.put(key, JSONObject(event.toString()))
                if (old != null && same(pending.optJSONObject(key), old)) pending.remove(key)
                if (key == "traktAccess") next.getJSONObject("auxiliary").remove("traktCreated")
            }
        } }
        validate(next.getJSONObject("document"), scope)
        next.put("counter", maxOf(clock(next.get("counter")), target.keys().asSequence()
            .map { clock(target.getJSONObject(it).get("clock")) }.maxOrNull() ?: 0L))
        local = next
    }

    fun acknowledge(sent: JSONObject) {
        validate(sent, scope)
        sent.getJSONObject("fields").let { fields -> fields.keys().forEach { key ->
            if (same(pending().optJSONObject(key), fields.getJSONObject(key))) pending().remove(key)
        } }
    }

    fun mirror(into: JSONObject): JSONObject = JSONObject(into.toString()).also { document ->
        document.put("nativeProviderCredentials", this.document())
        val existing = document.opt("apiKeys")
        require(existing == null || existing === JSONObject.NULL || existing is JSONObject)
        val api = (existing as? JSONObject) ?: JSONObject().also { document.put("apiKeys", it) }
        fields().keys().forEach { key ->
            val value = value(key)
            if (value == null) api.remove(key) else api.put(key, value)
            if (key in METADATA) {
                val old = api.opt("metadata")
                require(old == null || old === JSONObject.NULL || old is JSONObject)
                val nested = (old as? JSONObject) ?: JSONObject().also { api.put("metadata", it) }
                if (value == null) nested.remove(key) else nested.put(key, value)
            }
        }
    }

    private fun fields() = local.getJSONObject("document").getJSONObject("fields")
    private fun pending() = local.getJSONObject("pending")

    companion object {
        const val MAX_CLOCK = 9007199254740991L
        private const val ZERO_ACTOR = "00000000-0000-0000-0000-000000000000"
        val METADATA = setOf("tmdb", "mdblist", "fanart")
        val GROUPS = listOf(setOf("traktAccess", "traktRefresh", "traktExpiry"), setOf("simklAccess", "simklExpiry"))
        val KEYS = METADATA + setOf("realDebrid", "allDebrid", "premiumize", "torBox") + GROUPS.flatten()
        private fun emptyDocument(scope: String) = JSONObject().put("schemaVersion", 1).put("scope", scope).put("fields", JSONObject())
        private fun validActor(value: String) = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
        private fun validExpiry(value: String) = value.toLongOrNull()?.let { it in 0..MAX_CLOCK && it.toString() == value } == true
        private fun clock(value: Any): Long {
            require(value is Number)
            return java.math.BigDecimal(value.toString()).longValueExact().also { require(it in 0..MAX_CLOCK) }
        }
        private fun compare(a: JSONObject, b: JSONObject): Int = clock(a.get("clock")).compareTo(clock(b.get("clock")))
            .takeIf { it != 0 } ?: a.getString("actor").compareTo(b.getString("actor"))
        fun same(a: JSONObject?, b: JSONObject?): Boolean = when {
            a == null || b == null -> a == null && b == null
            else -> a.keys().asSequence().toSet() == b.keys().asSequence().toSet() && a.keys().asSequence().all { key ->
                val left = a.opt(key); val right = b.opt(key)
                if (left is JSONObject && right is JSONObject) same(left, right)
                else if (left is Number && right is Number) left.toLong() == right.toLong()
                else left == right
            }
        }
        fun validate(document: JSONObject, scope: String) {
            require(document.keys().asSequence().toSet() == setOf("schemaVersion", "scope", "fields"))
            require(clock(document.get("schemaVersion")) == 1L && document.get("scope") == scope)
            val fields = document.getJSONObject("fields")
            fields.keys().forEach { key ->
                require(key in KEYS)
                val event = fields.getJSONObject(key)
                require(event.keys().asSequence().toSet() == setOf("clock", "actor", "value"))
                clock(event.get("clock")); require(validActor(event.getString("actor")))
                val value = event.get("value")
                require(value === JSONObject.NULL || (value is String && value.isNotEmpty()))
                if (key.endsWith("Expiry") && value is String) require(validExpiry(value))
            }
            GROUPS.forEach { group ->
                val events = group.mapNotNull(fields::optJSONObject)
                require(events.isEmpty() || (events.size == group.size && events.all {
                    compare(it, events[0]) == 0 && it.isNull("value") == events[0].isNull("value")
                }))
            }
        }
    }
}
