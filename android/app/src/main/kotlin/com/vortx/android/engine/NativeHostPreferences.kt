package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import java.math.BigDecimal
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** Shared Apple/Android schema 1. Kernel authority and credential storage are deliberately separate. */
internal object NativeHostPreferences {
    const val MAX_CLOCK = 9_007_199_254_740_991L
    private val nativeFields = setOf("id", "name", "isOwner", "pin", "isKids", "familyEdit", "accentID", "oled", "textScale",
        "disabledAddons", "usesOwnAccount", "account", "addons", "settings", "parental", "rev", "updatedAt", "deleted")
    private val forbiddenGlobals = setOf("activeprofileid", "activeid", "profiles", "roster", "nativesync", "nativehostpreferences",
        "account", "scope", "ownerprofileid", "stremiox.profiles", "stremiox.profiles.modified", "stremiox.activeprofileid", "stremiox.profiles.active",
        "stremiox.theme.accent", "stremiox.theme.oled", "stremiox.theme.textscale")
    private val forbiddenFields = nativeFields.map(String::lowercase).toSet() + forbiddenGlobals
    private fun authority(field: String): Boolean = field.lowercase().let { it in forbiddenFields ||
        it.startsWith("stremiox.profiles") || it.startsWith("vortx.sync.") || it.startsWith("vortx.native.") }

    fun empty(scope: VortxAccountScope) = JSONObject().put("schemaVersion", 1).put("scope", scope.accountID)
        .put("ownerProfileId", scope.ownerProfileID).put("profiles", JSONObject()).put("globals", JSONObject().put("fields", JSONObject()))

    fun local(scope: VortxAccountScope, stored: JSONObject? = null): JSONObject {
        val value = stored?.let { JSONObject(it.toString()) } ?: JSONObject().put("actor", UUID.randomUUID().toString())
            .put("counter", 0).put("document", empty(scope)).put("pending", false)
        actor(value.getString("actor")); clock(value.get("counter")); require(value.get("pending") is Boolean)
        validate(scope, value.getJSONObject("document"))
        require(value.getLong("counter") >= maximum(value.getJSONObject("document"))) { "Host preference clock regressed" }
        return value
    }

    fun validate(scope: VortxAccountScope, document: JSONObject) {
        require(document.keys().asSequence().toSet() == setOf("schemaVersion", "scope", "ownerProfileId", "profiles", "globals"))
        require(document.get("schemaVersion") is Number && clock(document.get("schemaVersion")) == 1L)
        require(document.getString("scope") == scope.accountID && document.getString("ownerProfileId") == scope.ownerProfileID)
        NativeHostDocument.requireCredentialFree(document)
        val profiles = document.getJSONObject("profiles")
        for (id in profiles.keys()) {
            require(id.isNotBlank() && '\u0000' !in id)
            val bucket = profiles.getJSONObject(id)
            require(bucket.keys().asSequence().toSet() == setOf("fields"))
            validateFields(bucket.getJSONObject("fields"), true)
        }
        val globals = document.getJSONObject("globals")
        require(globals.keys().asSequence().toSet() == setOf("fields"))
        validateFields(globals.getJSONObject("fields"), false)
    }
    private fun validateFields(fields: JSONObject, profile: Boolean) {
        for (field in fields.keys()) {
            require(field.isNotBlank() && field.length <= 512)
            require(!authority(field)) { "Host field conflicts with native authority" }
            val entry = fields.getJSONObject(field)
            require(entry.keys().asSequence().toSet() == setOf("clock", "actor", "value"))
            clock(entry.get("clock")); actor(entry.getString("actor"))
            val value = entry.get("value")
            if (value == JSONObject.NULL) continue
            if (profile) when (field) {
                "avatar", "email" -> require(value is String) { "Invalid host string preference" }
                "playback", "discovery", "addonPreferences" -> {
                    require(value is JSONObject) { "Invalid host object preference" }
                    validateProfileObject(field, value)
                }
            } else validateGlobal(field, value)
        }
    }
    private fun stringArray(value: Any) {
        require(value is JSONArray && (0 until value.length()).all { value.get(it) is String })
    }
    private fun integer(value: Any) { require(value is Number); BigDecimal(value.toString()).intValueExact() }
    private fun decimal(value: Any) { require(value is Number && value.toDouble().isFinite()) }
    private fun validateGlobal(field: String, value: Any) {
        when (SettingsBackup.SYNCABLE_SETTING_TYPES[field]) {
            SettingsBackup.SettingType.BOOL -> require(value is Boolean)
            SettingsBackup.SettingType.STRING -> require(value is String)
            SettingsBackup.SettingType.INT -> integer(value)
            SettingsBackup.SettingType.FLOAT -> { decimal(value); require((value as Number).toFloat().isFinite()) }
            SettingsBackup.SettingType.STRING_SET, SettingsBackup.SettingType.JSON_STRING_ARRAY -> stringArray(value)
            null -> Unit // Unknown noncredential values are retained, not applied by this client.
        }
    }
    private fun validateProfileObject(field: String, value: JSONObject) {
        fun fields(names: String, check: (Any) -> Unit) = names.split(' ').forEach { key ->
            if (value.has(key) && !value.isNull(key)) check(value.get(key))
        }
        fun strings(names: String) = fields(names) { require(it is String) }
        fun bools(names: String) = fields(names) { require(it is Boolean) }
        when (field) {
            "playback" -> {
                strings("audioLang subtitleLang forcedPolicy subFont subSize subColor subBackground subBrightness safetyMode excludeKeywords includeKeywords preferKeywords avoidBehavior")
                bools("useAddonOrder instantOnly hideDeadTorrents hdrOnly excludeAV1 keywordsAreRegex hideUnknownResolution preferredAudioOnly autoPickBest")
                fields("subSizeScale maxFileSizeGB", ::decimal)
                fields("maxResolution minResolution", ::integer)
                fields("sourceTypeOrder", ::stringArray)
            }
            "discovery" -> {
                strings("regionOverride filtersData")
                bools("regionOverrideCaptured filtersCaptured tabVisibilityCaptured hideLiveTab hideDiscoverTab hideLibraryTab hideSearchTab showCollectionsHome showCollectionsDiscover")
                fields("hiddenCatalogs catalogOrder hiddenHubCategories", ::stringArray)
                fields("selectedProviders providerOrder") { array ->
                    require(array is JSONArray); (0 until array.length()).forEach { integer(array.get(it)) }
                }
            }
            "addonPreferences" -> {
                fields("disabledAddonURLsOverride", ::stringArray)
                fields("rankingOverride") { rank ->
                    require(rank is JSONObject)
                    if (rank.has("addonOrder") && !rank.isNull("addonOrder")) stringArray(rank.get("addonOrder"))
                    if (rank.has("sourceTypeOrder") && !rank.isNull("sourceTypeOrder")) stringArray(rank.get("sourceTypeOrder"))
                    if (rank.has("useAddonOrder") && !rank.isNull("useAddonOrder")) require(rank.get("useAddonOrder") is Boolean)
                }
            }
        }
    }
    fun validateProjectedProfiles(profiles: JSONObject) {
        for (id in profiles.keys()) {
            if (id == "modifiedSeconds") continue
            val profile = profiles.getJSONObject(id)
            for (field in listOf("avatar", "email")) if (profile.has(field) && !profile.isNull(field)) require(profile.get(field) is String)
            for (field in listOf("playback", "discovery", "addonPreferences")) {
                if (profile.has(field) && !profile.isNull(field)) validateProfileObject(field, profile.getJSONObject(field))
            }
        }
    }
    private fun clock(value: Any): Long {
        require(value is Number)
        return BigDecimal(value.toString()).longValueExact().also { require(it in 0..MAX_CLOCK) }
    }
    private fun actor(value: String) { require(UUID.fromString(value).toString() == value) { "Invalid host actor" } }
    private fun allFields(document: JSONObject): List<JSONObject> = listOf(document.getJSONObject("globals").getJSONObject("fields")) +
        document.getJSONObject("profiles").let { profiles -> profiles.keys().asSequence().map { profiles.getJSONObject(it).getJSONObject("fields") }.toList() }
    private fun maximum(document: JSONObject) = allFields(document).flatMap { fields -> fields.keys().asSequence().map { fields.getJSONObject(it).getLong("clock") }.toList() }.maxOrNull() ?: 0L

    fun merge(scope: VortxAccountScope, local: JSONObject, incoming: JSONObject?): JSONObject {
        val result = local(scope, local)
        if (incoming == null) return result
        validate(scope, incoming)
        val destination = result.getJSONObject("document")
        fun mergeFields(target: JSONObject, source: JSONObject) {
            for (field in source.keys()) {
                val next = source.getJSONObject(field); val old = target.optJSONObject(field)
                val comparison = if (old == null) 1 else compareValuesBy(next, old, { it.getLong("clock") }, { it.getString("actor") })
                if (comparison == 0) require(equal(old!!.get("value"), next.get("value"))) { "Conflicting host preference event" }
                if (comparison > 0) target.put(field, JSONObject(next.toString()))
            }
        }
        mergeFields(destination.getJSONObject("globals").getJSONObject("fields"), incoming.getJSONObject("globals").getJSONObject("fields"))
        val profiles = destination.getJSONObject("profiles")
        val remoteProfiles = incoming.getJSONObject("profiles")
        for (id in remoteProfiles.keys()) {
            val target = profiles.optJSONObject(id) ?: JSONObject().put("fields", JSONObject()).also { profiles.put(id, it) }
            mergeFields(target.getJSONObject("fields"), remoteProfiles.getJSONObject(id).getJSONObject("fields"))
        }
        result.put("counter", maxOf(result.getLong("counter"), maximum(destination)))
        return result
    }

    fun recordProfiles(scope: VortxAccountScope, local: JSONObject, before: JSONObject, after: JSONObject): JSONObject {
        val result = local(scope, local)
        val profiles = result.getJSONObject("document").getJSONObject("profiles")
        for (id in after.keys().asSequence().filter { it != "modifiedSeconds" }.sorted()) {
            val old = before.optJSONObject(id) ?: JSONObject(); val next = after.getJSONObject(id)
            for (field in (old.keys().asSequence().toSet() + next.keys().asSequence().toSet()).sorted()) {
                if (field in nativeFields || equal(old.opt(field), next.opt(field))) continue
                val bucket = profiles.optJSONObject(id) ?: JSONObject().put("fields", JSONObject()).also { profiles.put(id, it) }
                record(result, bucket.getJSONObject("fields"), field, next.opt(field))
            }
        }
        validate(scope, result.getJSONObject("document"))
        return result
    }
    fun recordGlobals(scope: VortxAccountScope, local: JSONObject, changes: JSONObject): JSONObject {
        val result = local(scope, local)
        val fields = result.getJSONObject("document").getJSONObject("globals").getJSONObject("fields")
        for (field in changes.keys().asSequence().sorted()) {
            if (fields.has(field) && equal(fields.getJSONObject(field).get("value"), changes.get(field))) continue
            record(result, fields, field, changes.get(field))
        }
        validate(scope, result.getJSONObject("document"))
        return result
    }
    private fun record(local: JSONObject, fields: JSONObject, field: String, value: Any?) {
        val clock = local.getLong("counter")
        require(clock < MAX_CLOCK) { "Host preference clock exhausted" }
        local.put("counter", clock + 1).put("pending", true)
        fields.put(field, JSONObject().put("clock", clock + 1).put("actor", local.getString("actor")).put("value", value ?: JSONObject.NULL))
    }
    fun projectProfiles(local: JSONObject, base: JSONObject, roster: JSONObject): JSONObject {
        val result = JSONObject(base.toString())
        val profiles = local.getJSONObject("document").getJSONObject("profiles")
        for (id in profiles.keys()) {
            require(roster.has(id)) { "Host preference profile is not in native roster" }
            if (roster.getJSONObject(id).getBoolean("deleted")) continue
            val target = result.optJSONObject(id) ?: JSONObject().put("id", id).put("name", roster.getJSONObject(id).getString("name"))
            val fields = profiles.getJSONObject(id).getJSONObject("fields")
            for (field in fields.keys()) {
                val value = fields.getJSONObject(field).get("value")
                if (value == JSONObject.NULL) target.remove(field) else target.put(field, value)
            }
            result.put(id, target)
        }
        return result
    }
    fun equal(a: Any?, b: Any?): Boolean = when {
        (a == null || a == JSONObject.NULL) && (b == null || b == JSONObject.NULL) -> true
        a is JSONObject && b is JSONObject -> a.keys().asSequence().toSet().let { keys -> keys == b.keys().asSequence().toSet() && keys.all { equal(a.get(it), b.get(it)) } }
        a is JSONArray && b is JSONArray -> a.length() == b.length() && (0 until a.length()).all { equal(a.get(it), b.get(it)) }
        a is Number && b is Number -> BigDecimal(a.toString()).compareTo(BigDecimal(b.toString())) == 0
        else -> a == b
    }
}
