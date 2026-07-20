package com.vortx.android.sync

import com.vortx.android.profile.PlaybackPrefs
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.profile.WatchEntry
import com.vortx.android.profile.optStringOrNull
import com.vortx.android.profile.toStringList
import org.json.JSONArray
import org.json.JSONObject

/**
 * The encrypted sync DOCUMENT codec: the pure, session-free transforms between the local profile roster
 * + per-profile watch overlays + delete tombstones and the JSON `doc.vortx` block the VortX account
 * stores. Android's analogue of the Apple `VortXSyncManager.vortxSummary` (write side) and its
 * `decodeRoster` / `byProfile` / `deletedProfiles` reads (read side), in
 * `app/SourcesShared/VortXSyncManager.swift`.
 *
 * WHY A JSON ROSTER CARRIER (the one deliberate Apple divergence): Apple carries the roster inside the
 * opaque base64 `doc.settings` blob (a binary-plist of the whole UserDefaults domain) and emits
 * `doc.vortx.profiles` only as a lossy DASHBOARD summary. Android has not ported `SettingsBackup` yet
 * (see the notes in `MirrorSettings` / `TrackPreferences` / `PlayerSettings`), so there is no settings
 * blob to read a roster out of. This codec therefore carries the roster in the vortx block two ways:
 *   - `vortx.roster`  — the FULL, lossless roster (Apple's exact `UserProfile` Codable field names via
 *     [UserProfile.encodeProfile] / [UserProfile.decodeProfile]), so Android round-trips EVERY field
 *     (usesOwnAccount, email, accentID, the whole PlaybackPrefs) with zero loss on Android<->Android sync.
 *   - `vortx.profiles` — the dashboard summary, byte-parity with Apple's `vortxSummary` profiles shape,
 *     so the vortx.tv dashboard (and an Apple client, when it reads the summary) still renders the roster.
 * On READ, [parse] PREFERS `vortx.roster` (lossless) and falls back to reconstructing from
 * `vortx.profiles` (best-effort, for a doc authored by Apple / the web before SettingsBackup lands).
 *
 * NEVER-SHRINK: [buildVortx] deep-copies the pulled vortx block and OVERWRITES only the keys this round
 * owns (profiles / roster / byProfile / activeProfile / updatedAt / rosterModified), so foreign keys
 * another surface wrote (addons, addonsOwnedAt, library, deletedAddons/Ts, deletedLibrary/Ts) survive the
 * write untouched. Existing `byProfile` buckets are carried forward and only overwritten where the local
 * overlay actually has entries, so a device that lacks a profile's overlay never shrinks the account's
 * copy of it. `deletedProfiles` is not overwritten at all: it is READ-MERGED (pulled UNION local), so a
 * device can only ever ADD a delete tombstone and never retract one a peer authored (#145 M6).
 *
 * NEVER-ZERO: a momentarily-empty local roster (there should always be at least the owner, but be
 * defensive) returns the existing vortx block unchanged rather than writing an empty roster over a
 * populated one.
 */
object VortXSyncDoc {

    /** The parsed roster + overlay + tombstone view of a pulled doc, ready for the ordered syncDown apply. */
    data class Parsed(
        /** The remote roster, or null when the doc carries neither `vortx.roster` nor `vortx.profiles`. */
        val roster: List<UserProfile>?,
        /** The roster's modification stamp in epoch-SECONDS (mergeInRoster's tiebreak), or null. */
        val rosterModifiedSeconds: Long?,
        /** Each non-owner profile's overlay library/CW, keyed by profile id then meta id. */
        val overlays: Map<String, Map<String, WatchEntry>>,
        /** Cross-device profile delete tombstones. */
        val deletedProfiles: List<String>,
        /** The remote device's active profile (advisory; selection stays per-device). */
        val activeProfile: String?,
    )

    // ---- Read: doc.vortx -> local-state view ----

    fun parse(doc: JSONObject): Parsed {
        val vortx = doc.optJSONObject("vortx")
            ?: return Parsed(null, null, emptyMap(), emptyList(), null)

        // Roster: prefer the FULL lossless carrier (Android-authored); else reconstruct from the dashboard
        // summary (Apple / web-authored) so a cross-surface doc still yields a usable roster.
        val roster: List<UserProfile>? = vortx.optJSONArray("roster")?.let { arr ->
            (0 until arr.length()).mapNotNull { i -> arr.optJSONObject(i)?.let { UserProfile.decodeProfile(it) } }
        } ?: vortx.optJSONArray("profiles")?.let { arr ->
            (0 until arr.length()).mapNotNull { i -> arr.optJSONObject(i)?.let { rosterFromSummary(it) } }
        }

        // Modification tiebreak in epoch-SECONDS: prefer the explicit Android key; else derive from Apple's
        // epoch-MS `updatedAt` (divide by 1000). ALWAYS read as Long (optLong) — updatedAt is a 64-bit
        // epoch-ms value, and optInt would truncate it. null when neither is present (mergeInRoster then
        // keeps the local roster, the safe default).
        val modified: Long? = when {
            vortx.has("rosterModified") -> vortx.optLong("rosterModified")
            vortx.has("updatedAt") -> vortx.optLong("updatedAt") / 1000L
            else -> null
        }

        val overlays = LinkedHashMap<String, Map<String, WatchEntry>>()
        vortx.optJSONObject("byProfile")?.let { byProfile ->
            val keys = byProfile.keys()
            while (keys.hasNext()) {
                val profileId = keys.next()
                val library = byProfile.optJSONObject(profileId)?.optJSONArray("library") ?: continue
                val entries = LinkedHashMap<String, WatchEntry>()
                for (i in 0 until library.length()) {
                    val item = library.optJSONObject(i) ?: continue
                    val metaId = item.optString("id", "")
                    if (metaId.isEmpty()) continue
                    entries[metaId] = overlayEntryFrom(item)
                }
                if (entries.isNotEmpty()) overlays[profileId] = entries
            }
        }

        val deleted = vortx.optJSONArray("deletedProfiles")?.toStringList() ?: emptyList()
        val active = vortx.optStringOrNull("activeProfile")
        return Parsed(roster, modified, overlays, deleted, active)
    }

    /**
     * Reconstruct a [WatchEntry] from a `byProfile[].library[]` item. `t` / `d` are in SECONDS on the
     * wire (Apple `vortxSummary`), so multiply back to ms; `v` -> videoId and `poster` empty-strings map
     * to null (Apple's `encodeIfPresent`); `w` -> watchedVideoIds. Mirrors Apple `syncDown`'s byProfile loop.
     */
    private fun overlayEntryFrom(item: JSONObject): WatchEntry = WatchEntry(
        videoId = item.optString("v", "").takeUnless { it.isEmpty() },
        timeOffsetMs = item.optInt("t", 0) * 1000,
        durationMs = item.optInt("d", 0) * 1000,
        lastWatched = item.optString("lastWatched", ""),
        name = item.optString("name", ""),
        type = item.optString("type", "movie"),
        poster = item.optString("poster", "").takeUnless { it.isEmpty() },
        watchedVideoIds = item.optJSONArray("w")?.toStringList() ?: emptyList(),
    )

    /**
     * Best-effort reconstruction of a [UserProfile] from a dashboard summary entry (only reached for a
     * doc authored by Apple / the web that carries no full `vortx.roster`). Lossy by nature: the summary
     * omits `usesOwnAccount` and `email`, so an own-account binding reconstructs as a shared profile until
     * SettingsBackup lands and the full roster rides the settings blob. The owner-clobber guard in
     * [ProfileStore.mergeInRoster] protects the owner regardless.
     */
    private fun rosterFromSummary(o: JSONObject): UserProfile {
        val settings = o.optJSONObject("settings")
        val playback = settings?.optJSONObject("playback")?.let { playbackFromSummary(it) }
        return UserProfile(
            id = UserProfile.normalizeId(o.optString("id", "").ifEmpty { UserProfile.newId() }),
            name = o.optString("name", "Profile"),
            avatar = settings?.optString("avatar", "🍿") ?: "🍿",
            accentID = settings?.optString("accent", "ember") ?: "ember",
            oled = settings?.optBoolean("oled", false) ?: false,
            textScale = settings?.optDouble("textScale", 1.0) ?: 1.0,
            pin = o.optStringOrNull("pinHash")?.takeUnless { it.isEmpty() },
            usesOwnAccount = false,
            email = null,
            isOwner = o.optBoolean("main", false),
            familyEdit = o.optBoolean("familyEdit", false),
            playback = playback,
            disabledAddons = o.optJSONArray("disabledAddons")?.toStringList()?.takeUnless { it.isEmpty() },
            isKids = settings?.optBoolean("isKids", false) ?: false,
        )
    }

    /** Reconstruct [PlaybackPrefs] from the dashboard summary playback dict (note `forced` == forcedPolicy). */
    private fun playbackFromSummary(p: JSONObject): PlaybackPrefs = PlaybackPrefs(
        audioLang = p.optString("audioLang", ""),
        subtitleLang = p.optString("subtitleLang", ""),
        forcedPolicy = p.optString("forced", ""),
        subFont = p.optString("subFont", ""),
        subSize = p.optString("subSize", ""),
        subColor = p.optString("subColor", ""),
        subBackground = p.optString("subBackground", ""),
        subSizeScale = if (p.has("subSizeScale")) p.optDouble("subSizeScale") else null,
        sourceTypeOrder = p.optJSONArray("sourceTypeOrder")?.toStringList(),
        useAddonOrder = if (p.has("useAddonOrder")) p.optBoolean("useAddonOrder") else null,
        safetyMode = p.optStringOrNull("safetyMode"),
        instantOnly = if (p.has("instantOnly")) p.optBoolean("instantOnly") else null,
        hideDeadTorrents = if (p.has("hideDeadTorrents")) p.optBoolean("hideDeadTorrents") else null,
        hdrOnly = if (p.has("hdrOnly")) p.optBoolean("hdrOnly") else null,
        excludeAV1 = if (p.has("excludeAV1")) p.optBoolean("excludeAV1") else null,
        excludeKeywords = p.optStringOrNull("excludeKeywords"),
        includeKeywords = p.optStringOrNull("includeKeywords"),
        keywordsAreRegex = if (p.has("keywordsAreRegex")) p.optBoolean("keywordsAreRegex") else null,
        maxResolution = if (p.has("maxResolution")) p.optInt("maxResolution") else null,
        maxFileSizeGB = if (p.has("maxFileSizeGB")) p.optDouble("maxFileSizeGB") else null,
        minResolution = if (p.has("minResolution")) p.optInt("minResolution") else null,
        hideUnknownResolution = if (p.has("hideUnknownResolution")) p.optBoolean("hideUnknownResolution") else null,
        preferredAudioOnly = if (p.has("preferredAudioOnly")) p.optBoolean("preferredAudioOnly") else null,
    )

    // ---- Write: local-state -> doc.vortx ----

    /**
     * Build the `doc.vortx` block from the current local roster + overlays + tombstones, merged onto the
     * freshly-pulled [existingVortx] (deep-copied so the caller's pulled doc is never mutated). Owns only
     * the profile keys; every foreign vortx key survives (never-shrink). A momentarily-empty local roster
     * returns the existing block unchanged (never-zero). Mirrors Apple `vortxSummary`.
     */
    fun buildVortx(store: ProfileStore, existingVortx: JSONObject?): JSONObject {
        val roster = store.profiles
        val deleted = store.deletedProfileIDs

        // NEVER-ZERO: an empty local roster must not shrink the account's populated set. Carry the account's
        // existing vortx block forward unchanged rather than writing an empty roster over it.
        if (roster.isEmpty()) {
            return existingVortx?.let { JSONObject(it.toString()) } ?: JSONObject()
        }

        // Start from a deep copy of the pulled block so foreign keys this round does not own (addons,
        // addonsOwnedAt, library, deletedAddons/Ts, deletedLibrary/Ts) survive untouched (never-shrink).
        val v = existingVortx?.let { JSONObject(it.toString()) } ?: JSONObject()

        // profiles: the dashboard summary shape (byte-parity with Apple), excluding any tombstoned profile.
        val profilesArr = JSONArray()
        for (p in roster) {
            if (deleted.contains(p.id) && !p.isOwner) continue
            profilesArr.put(summaryFor(p))
        }
        v.put("profiles", profilesArr)

        // roster: the FULL lossless carrier (Apple `UserProfile` Codable field names) for Android<->Android.
        val fullRoster = JSONArray()
        for (p in roster) {
            if (deleted.contains(p.id) && !p.isOwner) continue
            fullRoster.put(UserProfile.encodeProfile(p))
        }
        v.put("roster", fullRoster)

        // byProfile: each NON-owner profile's overlay library/CW (the owner's history lives in the account
        // library, not an overlay). Carry existing buckets forward and overwrite only where the LOCAL overlay
        // has entries, so a device lacking a profile's overlay never shrinks the account's copy (never-shrink).
        val byProfile = existingVortx?.optJSONObject("byProfile")?.let { JSONObject(it.toString()) } ?: JSONObject()
        for (p in roster) {
            if (p.isOwner) continue
            val entries = store.watchEntries(p.id)
            if (entries.isEmpty()) continue
            val library = JSONArray()
            for ((metaId, e) in entries) library.put(overlayItem(metaId, e))
            byProfile.put(p.id, JSONObject().put("library", library))
        }
        if (byProfile.length() > 0) v.put("byProfile", byProfile) else v.remove("byProfile")

        store.activeID?.let { v.put("activeProfile", it) }

        // Durable cross-device delete tombstones (app-authoritative; the dashboard only READS them). Empty
        // set is omitted so a fresh account never writes the key.
        //
        // READ-MERGE, never rebuild-from-local (#145 M6). This was the one key that broke the never-shrink
        // contract this block otherwise honors: `v` is a deep copy of the pulled block, so `remove` here
        // ACTIVELY DELETED the account's tombstones whenever the LOCAL set happened to be empty (a fresh
        // install / reinstall), and `put(local)` overwrote a peer's tombstone this device had not folded.
        // Either way the next union-merge RESURRECTED the deleted profile. UNION the pulled set with the
        // local one instead: this device may only ADD a tombstone, never retract one another device authored.
        // Ids are normalized (Apple emits UPPERCASE `uuidString`; normalizeId uppercases) and the owner is
        // dropped defensively, so a foreign-cased id cannot fork into a second, non-matching tombstone.
        // Sorted for a deterministic array that is byte-identical to Apple `vortxSummary` for the same set.
        // The union can only be empty when the pulled set was empty too, so `remove` is now just the
        // fresh-account/omit-when-empty shape guard (and strips a malformed empty key) - it can no longer
        // drop a populated set. Mirrors Apple `vortxSummary`'s deletedProfiles read-merge.
        val priorDeleted = existingVortx?.optJSONArray("deletedProfiles")?.toStringList().orEmpty()
            .map { UserProfile.normalizeId(it) }
            .filter { it != UserProfile.OWNER_ID }
        val deletedUnion = (deleted + priorDeleted).sorted()
        if (deletedUnion.isNotEmpty()) v.put("deletedProfiles", JSONArray(deletedUnion)) else v.remove("deletedProfiles")

        // updatedAt: epoch-MS, byte-parity with Apple (the dashboard reads it). rosterModified: the
        // epoch-SECONDS tiebreak a peer Android device folds via mergeInRoster's `incomingModified`.
        v.put("updatedAt", System.currentTimeMillis())
        v.put("rosterModified", store.rosterModified)
        return v
    }

    /** The dashboard summary entry for one profile, byte-parity with Apple `vortxSummary`'s profiles map. */
    private fun summaryFor(p: UserProfile): JSONObject {
        val settings = JSONObject().apply {
            put("avatar", p.avatar)
            put("accent", p.accentID)
            put("oled", p.oled)
            put("textScale", p.textScale)
            put("isKids", p.isKids)
            p.playback?.let { put("playback", playbackSummary(it)) }
        }
        return JSONObject().apply {
            put("id", p.id)
            put("name", p.name)
            put("locked", p.hasPin)          // the dashboard shows a lock; the pinHash proves it
            put("main", p.isOwner)
            put("familyEdit", p.familyEdit)
            put("pinHash", p.pin ?: "")      // salted SHA-256, never the raw PIN
            put("settings", settings)
            put("disabledAddons", JSONArray(p.disabledAddons ?: emptyList<String>()))
        }
    }

    /**
     * The dashboard playback summary (byte-parity with Apple `vortxSummary`: note `forced` key, and the
     * Lane A prefer/avoid/autoPick fields are intentionally NOT in the summary — they still round-trip via
     * the full `roster` carrier). Optional fields are omitted when null (Apple's conditional puts).
     */
    private fun playbackSummary(pb: PlaybackPrefs): JSONObject = JSONObject().apply {
        put("audioLang", pb.audioLang)
        put("subtitleLang", pb.subtitleLang)
        put("forced", pb.forcedPolicy)
        put("subFont", pb.subFont)
        put("subSize", pb.subSize)
        put("subColor", pb.subColor)
        put("subBackground", pb.subBackground)
        pb.subSizeScale?.let { put("subSizeScale", it) }
        pb.sourceTypeOrder?.let { put("sourceTypeOrder", JSONArray(it)) }
        pb.useAddonOrder?.let { put("useAddonOrder", it) }
        pb.safetyMode?.let { put("safetyMode", it) }
        pb.instantOnly?.let { put("instantOnly", it) }
        pb.hideDeadTorrents?.let { put("hideDeadTorrents", it) }
        pb.hdrOnly?.let { put("hdrOnly", it) }
        pb.excludeAV1?.let { put("excludeAV1", it) }
        pb.excludeKeywords?.let { put("excludeKeywords", it) }
        pb.includeKeywords?.let { put("includeKeywords", it) }
        pb.keywordsAreRegex?.let { put("keywordsAreRegex", it) }
        pb.maxResolution?.let { put("maxResolution", it) }
        pb.maxFileSizeGB?.let { put("maxFileSizeGB", it) }
        pb.minResolution?.let { put("minResolution", it) }
        pb.hideUnknownResolution?.let { put("hideUnknownResolution", it) }
        pb.preferredAudioOnly?.let { put("preferredAudioOnly", it) }
    }

    /** One overlay library item, byte-parity with Apple `vortxSummary`'s byProfile library map (t/d in SECONDS). */
    private fun overlayItem(metaId: String, e: WatchEntry): JSONObject = JSONObject().apply {
        put("id", metaId)
        put("name", e.name)
        put("type", e.type)
        put("poster", e.poster ?: "")
        put("t", e.timeOffsetMs / 1000)
        put("d", e.durationMs / 1000)
        put("lastWatched", e.lastWatched)
        put("v", e.videoId ?: "")
        put("w", JSONArray(e.watchedVideoIds))
    }
}
