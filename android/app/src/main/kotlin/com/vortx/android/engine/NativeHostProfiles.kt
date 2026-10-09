package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.profile.UserProfile
import org.json.JSONArray
import org.json.JSONObject

/** Full authenticated host-owned preference records. Unknown fields survive native projection/edit. */
internal object NativeHostProfiles {
    /** Native fields travel in nativeSync. Every other changed host field still needs outbound
     * reconciliation; a native-carrier upload must not acknowledge that unexported local intent. */
    fun hasUnexportedChanges(before: JSONObject, after: JSONObject): Boolean {
        fun hostOnly(record: JSONObject) = JSONObject(record.toString()).also { value ->
            for (field in listOf("id", "name", "isOwner", "pin", "isKids", "familyEdit", "accentID", "oled", "textScale", "disabledAddons")) value.remove(field)
        }
        return after.keys().asSequence().filter { it != "modifiedSeconds" }.any { id ->
            !sameValue(hostOnly(before.optJSONObject(id) ?: JSONObject()), hostOnly(after.getJSONObject(id)))
        }
    }

    private fun sameValue(left: Any?, right: Any?): Boolean = when {
        left is JSONObject && right is JSONObject -> {
            val keys = left.keys().asSequence().toSet()
            keys == right.keys().asSequence().toSet() && keys.all { sameValue(left.get(it), right.get(it)) }
        }
        left is JSONArray && right is JSONArray -> left.length() == right.length() && (0 until left.length()).all { sameValue(left.get(it), right.get(it)) }
        left is Number && right is Number -> java.math.BigDecimal(left.toString()).compareTo(java.math.BigDecimal(right.toString())) == 0
        else -> left == right
    }

    fun fromDocument(document: JSONObject, roster: List<UserProfile>, modified: Double?): JSONObject {
        val vortx = document.optJSONObject("vortx")
        val native = vortx?.optJSONArray("roster")
        val settings = SettingsBackup.rawRosterFromBlob(document.opt("settings"))
        val settingsWins = (SettingsBackup.rosterModifiedFromBlob(document.opt("settings")) ?: Double.NEGATIVE_INFINITY) >=
            (vortx?.optDouble("rosterModified", Double.NEGATIVE_INFINITY) ?: Double.NEGATIVE_INFINITY)
        fun records(array: JSONArray?): Map<String, JSONObject> = if (array == null) emptyMap() else (0 until array.length()).associate {
            val record = array.getJSONObject(it)
            UserProfile.normalizeId(record.getString("id")) to record
        }
        val first = records(if (settingsWins) settings else native)
        val second = records(if (settingsWins) native else settings)
        return JSONObject().put("modifiedSeconds", modified ?: 0.0).also { host -> roster.forEach { profile ->
            val raw = first[profile.id] ?: second[profile.id] ?: error("Full authenticated profile record missing")
            host.put(profile.id, overlay(raw, UserProfile.decodeProfile(raw).encode(), profile.encode()))
        } }
    }

    fun updated(raw: JSONObject?, profile: UserProfile): JSONObject = overlay(raw ?: JSONObject(),
        raw?.let { UserProfile.decodeProfile(it).encode() } ?: JSONObject(), profile.encode())

    fun roster(host: JSONObject, profiles: List<UserProfile>): JSONArray = JSONArray(profiles.map { updated(host.optJSONObject(it.id), it) })

    private fun overlay(raw: JSONObject, before: JSONObject, after: JSONObject): JSONObject {
        val result = JSONObject(raw.toString())
        val keys = (before.keys().asSequence().toList() + after.keys().asSequence().toList()).distinct()
        for (key in keys) {
            val old = before.opt(key); val next = after.opt(key)
            if (old is JSONObject || next is JSONObject) {
                val nested = overlay(result.optJSONObject(key) ?: JSONObject(), old as? JSONObject ?: JSONObject(), next as? JSONObject ?: JSONObject())
                if (after.has(key) || nested.length() > 0) result.put(key, nested) else result.remove(key)
            } else if (after.has(key)) result.put(key, next) else result.remove(key)
        }
        return result
    }
}
