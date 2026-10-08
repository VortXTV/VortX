package com.vortx.android.engine

import java.math.BigDecimal
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

/**
 * Host half of the immutable website edit protocol.  The kernel owns native validation,
 * provenance, fingerprints and receipts; this adapter only admits its explicitly returned
 * host patch against the independently-clocked host registers.
 */
internal object NativeWebsiteProfileEdits {
    internal class Conflict(message: String) : IllegalArgumentException(message)
    internal data class Applied(
        val receipt: JSONObject,
        val host: JSONObject,
        val certificates: JSONObject,
    )

    private val hex = Regex("[0-9a-f]{64}")
    private val uuid = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    private val top = setOf("eventId", "editedAt", "observedNativeClock", "observedHostClock", "hostBases", "roster", "libraryAdds", "legacyBootstrapFingerprint")
    private val playbackStrings = setOf("audioLang", "subtitleLang", "forced", "subFont", "subSize", "subColor", "subBackground", "safetyMode")
    private val playbackBooleans = setOf("useAddonOrder", "instantOnly", "hideDeadTorrents", "hdrOnly", "excludeAV1", "keywordsAreRegex")
    private val languageCodes = setOf("", "en", "es", "fr", "de", "it", "pt", "hi", "ja", "ko", "zh", "ar", "ru")
    private val forced = setOf("always", "forced", "off")
    private val fonts = setOf("modern", "classic")
    private val sizes = setOf("s", "m", "l", "xl")
    private val colors = setOf("white", "yellow", "soft")
    private val backgrounds = setOf("outline", "shaded", "box")
    private val safety = setOf("off", "balanced", "strict")

    fun events(document: JSONObject): List<JSONObject> {
        val carrier = document.optJSONObject("profileEditEvents") ?: return emptyList()
        require(carrier.keys().asSequence().toSet() == setOf("schemaVersion", "events") && carrier.optInt("schemaVersion") == 2) {
            "Unsupported website profile edit carrier"
        }
        val source = carrier.optJSONArray("events") ?: throw IllegalArgumentException("Website events must be an array")
        return (0 until source.length()).map { index -> source.optJSONObject(index)?.let { JSONObject(it.toString()) }
            ?: throw IllegalArgumentException("Website event[$index] must be an object") }
    }

    /** Exact old aggregate is retained as source; only the session can prove bootstrap eligibility. */
    fun legacyPending(raw: Any?): JSONObject = JSONObject().put("eventId", "legacy-aggregate-${hash(raw)}")
        .put("legacyAggregate", copy(raw))
    fun legacyMigrationEvent(raw: JSONObject, legacyImportFingerprint: String): JSONObject = JSONObject(raw.toString())
        .put("eventId", legacyPending(raw).getString("eventId")).put("legacyBootstrapFingerprint", legacyImportFingerprint)

    fun validateRetained(scope: VortxAccountScope, pending: JSONObject, certificates: JSONObject) {
        require(pending.keys().asSequence().toSet() == setOf("events")) { "Invalid retained website events" }
        val events = pending.optJSONArray("events") ?: throw IllegalArgumentException("Invalid retained website events")
        val ids = mutableSetOf<String>()
        for (index in 0 until events.length()) {
            val event = events.optJSONObject(index) ?: throw IllegalArgumentException("Invalid retained website event")
            validateRetainedSource(scope, event)
            require(ids.add(event.getString("eventId"))) { "Duplicate retained website event" }
        }
        for (id in certificates.keys()) {
            require(id.isNotBlank() && hex.matches(certificates.getString(id))) { "Invalid website receipt certificate" }
        }
    }

    fun retain(scope: VortxAccountScope, pending: JSONObject, event: JSONObject): JSONObject {
        validateRetainedSource(scope, event)
        val result = JSONObject(pending.toString())
        val events = result.getJSONArray("events")
        val id = event.getString("eventId")
        for (index in 0 until events.length()) {
            val old = events.getJSONObject(index)
            if (old.getString("eventId") == id) {
                if (!NativeHostPreferences.equal(old, event)) throw Conflict("Website event identity conflict")
                return result
            }
        }
        events.put(JSONObject(event.toString()))
        return result
    }

    fun remove(pending: JSONObject, eventId: String): JSONObject = JSONObject().put("events", JSONArray().also { kept ->
        val events = pending.getJSONArray("events")
        for (index in 0 until events.length()) {
            val event = events.getJSONObject(index)
            if (event.getString("eventId") != eventId) kept.put(JSONObject(event.toString()))
        }
    })

    fun admit(scope: VortxAccountScope, event: JSONObject, response: JSONObject, local: JSONObject,
              fallbackProfiles: JSONObject, certificates: JSONObject): Applied {
        validateSource(scope, event)
        if (!response.optBoolean("ok")) throw Conflict("Website event rejected by native kernel")
        val returned = response.optJSONArray("events") ?: throw Conflict("Website receipt missing")
        if (returned.length() != 1) throw Conflict("Website receipt cardinality mismatch")
        val result = returned.optJSONObject(0) ?: throw Conflict("Website receipt malformed")
        if (result.optString("event") != "legacy_profile_edits_applied") throw Conflict("Website receipt type mismatch")
        val receipt = result.optJSONObject("receipt") ?: throw Conflict("Website receipt missing")
        val source = receipt.optJSONObject("source") ?: throw Conflict("Website receipt source missing")
        val id = event.getString("eventId")
        val fingerprint = source.optString("fingerprint")
        require(receipt.optInt("schemaVersion") == 1 && receipt.optString("eventId") == id && hex.matches(fingerprint)) {
            "Website receipt is invalid"
        }
        require(source.has("editedAtMs") && source.has("observedNativeClock") && NativeHostPreferences.equal(source.get("editedAtMs"), event.get("editedAt")) &&
            (!event.has("observedNativeClock") || NativeHostPreferences.equal(source.get("observedNativeClock"), event.get("observedNativeClock")))) { "Website receipt source mismatch" }
        val patch = result.optJSONObject("hostPatch") ?: throw Conflict("Website host patch missing")
        validatePatch(event, patch)
        val prior = if (certificates.has(id)) certificates.getString(id) else null
        if (prior != null && prior != fingerprint) throw Conflict("Website certificate conflicts with immutable receipt")
        val updated = NativeHostPreferences.local(scope, local)
        if (prior == null) compareBases(event, patch, updated, fallbackProfiles)
        applyPatch(event, patch, updated, fallbackProfiles, replay = prior != null)
        val nextCertificates = JSONObject(certificates.toString()).put(id, fingerprint)
        return Applied(JSONObject(receipt.toString()), updated, nextCertificates)
    }

    private fun validateSource(scope: VortxAccountScope, event: JSONObject) {
        require(event.keys().asSequence().toSet().all { it in top }) { "Unsupported website event field" }
        scope.rejectCredentials(event)
        require(event.optString("eventId").isNotBlank()) { "Website event ID required" }
        require(event.get("editedAt") is Number && event.getDouble("editedAt").isFinite() && event.getDouble("editedAt") > 0.0)
        require((event.has("observedNativeClock") && event.get("observedNativeClock") is Number && exactClock(event.get("observedNativeClock"))) ||
            (!event.has("observedNativeClock") && event.has("legacyBootstrapFingerprint") && hex.matches(event.getString("legacyBootstrapFingerprint"))))
        event.optJSONArray("roster")?.let { rows -> (0 until rows.length()).forEach { require(rows.optJSONObject(it) != null) } }
        event.optJSONObject("libraryAdds")?.let { additions -> additions.keys().forEach { require(additions.optJSONArray(it) != null) } }
        if (event.has("observedHostClock") || event.has("hostBases")) {
            require(uuid.matches(event.getString("eventId")) && event.has("observedHostClock") && exactClock(event.get("observedHostClock")))
            event.optJSONObject("hostBases") ?: throw IllegalArgumentException("Website host bases required")
        }
    }

    private fun validateRetainedSource(scope: VortxAccountScope, event: JSONObject) {
        scope.rejectCredentials(event)
        require(event.optString("eventId").isNotBlank()) { "Website event ID required" }
    }

    private fun validatePatch(event: JSONObject, patch: JSONObject) {
        for (profileId in patch.keys()) {
            val fields = patch.getJSONObject(profileId)
            for (path in fields.keys()) {
                val value = fields.get(path)
                when {
                    path == "settings.avatar" -> require(value is String && value.isNotEmpty() && value.codePointCount(0, value.length) <= 16 && value.none { it.code < 128 || Character.isISOControl(it) })
                    path.startsWith("settings.playback.") -> validatePlayback(path.removePrefix("settings.playback."), value)
                    else -> throw IllegalArgumentException("Unsupported website host patch")
                }
            }
        }
        // The native reply must be reconstructable from unchanged sparse input, never a host-only surprise.
        val expected = JSONObject()
        event.optJSONArray("roster")?.let { rows -> for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index); val settings = row.optJSONObject("settings") ?: continue
            val patchFields = JSONObject()
            if (settings.has("avatar")) patchFields.put("settings.avatar", settings.get("avatar"))
            settings.optJSONObject("playback")?.let { playback -> playback.keys().forEach { key -> patchFields.put("settings.playback.$key", playback.get(key)) } }
            if (patchFields.length() > 0) expected.put(row.getString("id"), patchFields)
        } }
        require(NativeHostPreferences.equal(expected, patch)) { "Website host patch does not match immutable event" }
    }

    private fun validatePlayback(key: String, value: Any) {
        when (key) {
            "audioLang", "subtitleLang" -> require(value is String && value in languageCodes)
            "forced" -> require(value is String && value in forced)
            "subFont" -> require(value is String && value in fonts)
            "subSize" -> require(value is String && value in sizes)
            "subColor" -> require(value is String && value in colors)
            "subBackground" -> require(value is String && value in backgrounds)
            "safetyMode" -> require(value is String && value in safety)
            "subSizeScale" -> require(value is Number && value.toDouble().isFinite() && value.toDouble() in 0.6..1.8)
            "maxFileSizeGB" -> require(value is Number && value.toDouble().isFinite() && value.toDouble() in 0.0..100000.0)
            "maxResolution" -> require(value is Number && value.toInt() in setOf(0, 720, 1080, 2160) && value.toDouble() == value.toInt().toDouble())
            in playbackBooleans -> require(value is Boolean)
            "sourceTypeOrder" -> require(value is JSONArray && (0 until value.length()).map { value.getString(it) }.let { it.distinct().size == it.size && it.all { item -> item in setOf("debrid", "torrent", "usenet", "direct") } })
            else -> throw IllegalArgumentException("Unsupported website playback preference")
        }
    }

    private fun compareBases(event: JSONObject, patch: JSONObject, local: JSONObject, fallbackProfiles: JSONObject) {
        val bases = event.getJSONObject("hostBases")
        for (profileId in patch.keys()) {
            val fields = patch.getJSONObject(profileId)
            for (topLevel in fields.keys().asSequence().map { if (it == "settings.avatar") "avatar" else "playback" }.toSet()) {
                val base = bases.optJSONObject(profileId)?.optJSONObject(topLevel) ?: throw Conflict("Website host base missing")
                val current = local.getJSONObject("document").getJSONObject("profiles").optJSONObject(profileId)?.getJSONObject("fields")?.optJSONObject(topLevel)
                if (current == null) {
                    if (!(base.optBoolean("absent") && base.keys().asSequence().toSet() == setOf("absent", "valueHash"))) throw Conflict("Website absent host base mismatch")
                    if (base.getString("valueHash") != hash(fallbackProfiles.optJSONObject(profileId)?.opt(topLevel) ?: JSONObject.NULL)) throw Conflict("Website host fallback changed")
                } else {
                    if (!(base.keys().asSequence().toSet() == setOf("clock", "actor", "valueHash") && exactClock(base.get("clock")) &&
                        base.getLong("clock") <= event.getLong("observedHostClock") && uuid.matches(base.getString("actor")) &&
                        base.getLong("clock") == current.getLong("clock") && base.getString("actor") == current.getString("actor") &&
                        base.getString("valueHash") == hash(current.get("value")))) throw Conflict("Website host base changed")
                }
            }
        }
    }

    private fun applyPatch(event: JSONObject, patch: JSONObject, local: JSONObject, fallbackProfiles: JSONObject, replay: Boolean) {
        val clock = event.getLong("observedHostClock") + 1
        require(clock <= NativeHostPreferences.MAX_CLOCK)
        val document = local.getJSONObject("document"); val profiles = document.getJSONObject("profiles")
        for (profileId in patch.keys()) {
            val values = patch.getJSONObject(profileId)
            val bucket = profiles.optJSONObject(profileId) ?: JSONObject().put("fields", JSONObject()).also { profiles.put(profileId, it) }
            val fields = bucket.getJSONObject("fields")
            for (topLevel in values.keys().asSequence().map { if (it == "settings.avatar") "avatar" else "playback" }.toSet()) {
                val current = fields.optJSONObject(topLevel)
                if (replay && current != null && compare(current, clock, event.getString("eventId")) >= 0) continue
                val value = if (topLevel == "avatar") values.get("settings.avatar") else {
                    val base = fallbackProfiles.optJSONObject(profileId)?.optJSONObject("playback") ?: JSONObject()
                    val playback = if (current?.optJSONObject("value") != null) JSONObject(current.getJSONObject("value").toString()) else JSONObject(base.toString())
                    values.keys().asSequence().filter { it.startsWith("settings.playback.") }.forEach { key -> playback.put(key.removePrefix("settings.playback."), values.get(key)) }
                    playback
                }
                fields.put(topLevel, JSONObject().put("clock", clock).put("actor", event.getString("eventId")).put("value", value))
            }
        }
        local.put("counter", maxOf(local.getLong("counter"), clock)).put("pending", true)
        NativeHostPreferences.validate(scope = VortxAccountScope(document.getString("scope"), document.getString("ownerProfileId")), document = document)
    }

    private fun compare(entry: JSONObject, clock: Long, actor: String): Int = compareValuesBy(entry, JSONObject().put("clock", clock).put("actor", actor), { it.getLong("clock") }, { it.getString("actor") })
    private fun exactClock(value: Any): Boolean = runCatching { BigDecimal(value.toString()).longValueExact() in 0..NativeHostPreferences.MAX_CLOCK }.getOrDefault(false)
    private fun hash(value: Any?): String = MessageDigest.getInstance("SHA-256").digest(canonical(value).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    private fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().sorted().joinToString(prefix = "{", postfix = "}") { key -> JSONObject.quote(key) + ":" + canonical(value.get(key)) }
        is JSONArray -> (0 until value.length()).joinToString(prefix = "[", postfix = "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        is Boolean -> value.toString()
        is Number -> BigDecimal(value.toString()).stripTrailingZeros().toPlainString()
        else -> throw IllegalArgumentException("Unsupported canonical JSON value")
    }
    private fun copy(value: Any?): Any = when (value) {
        null, JSONObject.NULL -> JSONObject.NULL
        is JSONObject -> JSONObject(value.toString())
        is JSONArray -> JSONArray(value.toString())
        is String, is Boolean, is Number -> value
        else -> throw IllegalArgumentException("Unsupported legacy website source")
    }
}
