package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.profile.UserProfile
import org.json.JSONArray
import org.json.JSONObject

/** Full authenticated host-owned preference records. Unknown fields survive native projection/edit. */
internal object NativeHostProfiles {
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
