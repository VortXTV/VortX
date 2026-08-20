package com.vortx.android.search

import android.content.Context
import android.net.Uri
import com.vortx.android.profile.ProfileStore
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/// Saved magnets and pasted links, per profile (SD-1), the Android port of Apple `SavedLinksStore.swift`
/// (issue #81). This is the LOCAL layer by design: a magnet or ad-hoc URL has no catalog meta id, and
/// injecting a synthetic item into the engine library corrupts account-wide sync for the official clients
/// (the poisoned-account incident, `ProfileSync.swift` and the repo invariant "never write app data
/// into libraryItem documents"). So saved links live only here, in a plain (non-secret) SharedPreferences file
/// -- keyed per profile so one profile's saved links never surface on another.
///
/// A saved magnet can additionally remember the EXACT file the user played (`infoHash`/`fileIdx`), so a
/// season pack reopens the same episode instead of re-picking the largest file. That binding is local only
/// and never carries catalog meta.
class SavedLinksStore(context: Context) {
    data class Entry(
        val id: String,          // the magnet / URL itself, the dedupe key
        val link: String,
        val name: String,
        val poster: String? = null,
        val isMagnet: Boolean,
        val savedAt: Long,       // epoch millis
        val infoHash: String? = null,
        val fileIdx: Int? = null,
    )

    private val prefs =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    private fun key(profileId: String): String = KEY_PREFIX + profileId

    private fun bucket(): String = ProfileStore.sharedOrNull()?.activeID ?: DEFAULT_BUCKET

    private fun load(profileId: String): List<Entry> {
        val raw = prefs.getString(key(profileId), null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { entryFromJson(array.optJSONObject(it)) }
        }.getOrDefault(emptyList())
    }

    /// All saved entries for the ACTIVE profile, newest first.
    fun all(): List<Entry> = load(bucket()).sortedByDescending { it.savedAt }

    fun isSaved(link: String): Boolean = load(bucket()).any { it.id == link }

    /// Save (or move-to-top) an entry for the active profile. Keyed by the link, so saving the same one
    /// twice de-dupes and refreshes its position.
    fun save(entry: Entry) {
        val profileId = bucket()
        val updated = listOf(entry) + load(profileId).filter { it.id != entry.id }
        persist(profileId, updated.take(CAP))
    }

    fun remove(link: String) {
        val profileId = bucket()
        persist(profileId, load(profileId).filter { it.id != link })
    }

    /// #81: after a magnet file actually plays, remember the EXACT file on its ALREADY-saved entry so
    /// re-opening replays the same file. Update-only: an entry the user did not choose to save is never
    /// auto-added, so the list is not cluttered by one-off plays. Local only; never touches the account
    /// library.
    fun bindPlayedFile(magnetLink: String, playUrl: String) {
        val parts = torrentParts(playUrl) ?: return
        val profileId = bucket()
        val existing = load(profileId).firstOrNull { it.id == magnetLink } ?: return
        save(existing.copy(infoHash = parts.first, fileIdx = parts.second))
    }

    private fun persist(profileId: String, list: List<Entry>) {
        val array = JSONArray()
        list.forEach { array.put(entryToJson(it)) }
        prefs.edit().putString(key(profileId), array.toString()).apply()
    }

    private fun entryToJson(e: Entry): JSONObject = JSONObject()
        .put("id", e.id)
        .put("link", e.link)
        .put("name", e.name)
        .apply { if (e.poster != null) put("poster", e.poster) }
        .put("isMagnet", e.isMagnet)
        .put("savedAt", e.savedAt)
        .apply {
            if (e.infoHash != null) put("infoHash", e.infoHash)
            if (e.fileIdx != null) put("fileIdx", e.fileIdx)
        }

    private fun entryFromJson(o: JSONObject?): Entry? {
        o ?: return null
        val id = o.optString("id").takeIf { it.isNotEmpty() } ?: return null
        return Entry(
            id = id,
            link = o.optString("link", id),
            name = o.optString("name", id),
            poster = o.optStringOrNull("poster"),
            isMagnet = o.optBoolean("isMagnet", id.startsWith("magnet:", ignoreCase = true)),
            savedAt = o.optLong("savedAt", 0L),
            infoHash = o.optStringOrNull("infoHash"),
            fileIdx = if (o.has("fileIdx") && !o.isNull("fileIdx")) o.optInt("fileIdx") else null,
        )
    }

    private fun JSONObject.optStringOrNull(k: String): String? =
        if (has(k) && !isNull(k)) optString(k).takeIf { it.isNotEmpty() } else null

    companion object {
        const val PREFS_FILE = "vortx_saved_links"
        const val KEY_PREFIX = "stremiox.savedLinks."
        const val DEFAULT_BUCKET = "default"
        const val CAP = 100

        /// #81: pull `(infoHash, fileIdx)` from a torrent play URL of the form `{base}/{infoHash}/{fileIdx}`
        /// (what the resolver builds for a magnet). Returns null for direct/debrid/HLS URLs, so only real
        /// torrent files get the exact-file binding. Mirrors Apple `SavedLinksStore.torrentParts`.
        fun torrentParts(playUrl: String): Pair<String, Int>? {
            val parts = runCatching { Uri.parse(playUrl) }.getOrNull()?.pathSegments?.filter { it.isNotEmpty() }
                ?: return null
            if (parts.size < 2) return null
            val idx = parts.last().toIntOrNull() ?: return null
            val hash = parts[parts.size - 2].lowercase(Locale.ROOT)
            if (hash.length < 32 || !hash.all { it in '0'..'9' || it in 'a'..'f' }) return null
            return hash to idx
        }
    }
}
