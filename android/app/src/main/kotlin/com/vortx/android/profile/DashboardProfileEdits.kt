package com.vortx.android.profile

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Pure dashboard roster fold. Document transport/ownership stays in the existing sync lease. */
internal object DashboardProfileEdits {
    data class Result(val profiles: List<UserProfile>, val deletedIDs: Set<String>, val modified: Double)

    fun safeIncoming(local: List<UserProfile>, incoming: List<UserProfile>, lossless: Boolean): List<UserProfile> =
        if (lossless) incoming else incoming.filter { peer -> local.none { it.id == peer.id } }

    fun apply(base: List<UserProfile>, tombstones: Set<String>, localModified: Double, edits: JSONObject?,
        mirrorUpdatedAt: Any? = null): Result {
        val rows = base.toMutableList()
        val deletions = mutableSetOf<String>()
        var acceptedEdit = false
        val floor = localModified.takeIf { it.isFinite() && it >= 0 } ?: 0.0
        // Website editedAt is epoch milliseconds; native roster clocks are seconds.
        val millis = (edits?.opt("editedAt") as? Number)?.toDouble()?.takeIf { it.isFinite() && it > 0 }
            ?: return Result(base, emptySet(), floor)
        val seconds = millis / 1000.0
        val mirrorSeconds = (mirrorUpdatedAt as? Number)?.toDouble()?.takeIf { it.isFinite() && it >= 0 }?.div(1000.0) ?: 0.0
        val acceptFields = seconds > maxOf(floor, mirrorSeconds)
        val patches = edits?.optJSONArray("roster") ?: return Result(base, emptySet(), floor)
        for (i in 0 until patches.length()) {
            val patch = patches.optJSONObject(i) ?: continue
            val rawID = patch.opt("id") as? String ?: continue
            val id = runCatching { UUID.fromString(rawID).toString().uppercase() }.getOrNull() ?: continue
            if (!id.equals(rawID, ignoreCase = true)) continue
            if (patch.opt("deleted") == true) {
                if (id != UserProfile.OWNER_ID && rows.none { it.id == id && it.isOwner }) {
                    deletions += id
                    rows.removeAll { it.id == id }
                }
                continue
            }
            if (id in tombstones || id in deletions) continue
            val index = rows.indexOfFirst { it.id == id }
            if (index >= 0 && !acceptFields) continue
            val name = (patch.opt("name") as? String)?.trim()?.takeIf { it.isNotEmpty() }
            val original = if (index >= 0) rows[index] else {
                if (name == null || id == UserProfile.OWNER_ID) continue
                UserProfile(id = id, name = name, avatar = "🍿")
            }
            // Patch a full record, never decode a partial web row as if it were a native profile.
            val full = UserProfile.encodeProfile(original)
            var acceptedRow = index < 0
            name?.let { full.put("name", it); acceptedRow = true }
            (patch.opt("familyEdit") as? Boolean)?.let { full.put("familyEdit", it); acceptedRow = true }
            if (patch.has("pin")) {
                when (val pin = patch.opt("pin")) {
                    JSONObject.NULL -> { full.remove("pin"); acceptedRow = true }
                    is String -> {
                        if (pin.isEmpty()) full.remove("pin") else full.put("pin", pin)
                        acceptedRow = true
                    }
                }
            }
            patch.optJSONArray("disabledAddons")?.let { disabled ->
                val raw = (0 until disabled.length()).map { disabled.opt(it) }
                if (raw.all { it is String }) {
                    val values = raw.filterIsInstance<String>().distinct().sorted()
                    if (values.isEmpty()) full.remove("disabledAddons") else full.put("disabledAddons", JSONArray(values))
                    acceptedRow = true
                }
            }
            patch.optJSONObject("settings")?.let { settings ->
                for ((web, native) in listOf("avatar" to "avatar", "accent" to "accentID", "accentID" to "accentID")) {
                    (settings.opt(web) as? String)?.takeIf { it.isNotEmpty() }?.let { full.put(native, it); acceptedRow = true }
                }
                for (key in listOf("oled", "isKids")) (settings.opt(key) as? Boolean)?.let { full.put(key, it); acceptedRow = true }
                (settings.opt("textScale") as? Number)?.toDouble()?.takeIf { it.isFinite() && it > 0 }
                    ?.let { full.put("textScale", it); acceptedRow = true }
                settings.optJSONObject("playback")?.let { incoming ->
                    val playback = full.optJSONObject("playback") ?: JSONObject()
                    for (key in incoming.keys()) {
                        val value = incoming.opt(key)
                        // Website's 2160 cap is native 4000 (the ranker's 4K bucket), as on Apple.
                        // Keeping 2160 would silently hide every 4K stream after a web profile edit.
                        val translated = if (key == "maxResolution" && value is Number && value.toDouble() == 2160.0) 4000 else value
                        playback.put(if (key == "forced") "forcedPolicy" else key, translated)
                    }
                    full.put("playback", playback)
                    if (incoming.length() > 0) acceptedRow = true
                }
            }
            // A rejected row must not consume its clock: a corrected payload at the same stamp
            // should still apply. Valid same-value edits may acknowledge the received watermark.
            val updated = runCatching { UserProfile.decodeProfile(full) }.getOrNull() ?: continue
            if (!acceptedRow) continue
            acceptedEdit = true
            if (index >= 0) rows[index] = updated else rows += updated
        }
        return Result(rows, deletions, if (acceptedEdit || deletions.isNotEmpty()) maxOf(floor, seconds) else floor)
    }
}
