package com.vortx.android.profile

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

/**
 * One viewer of the app: local view settings (name, avatar, theme, parental PIN) plus an optional
 * binding to its own Stremio account. The Android port of Apple `app/SourcesShared/Profiles.swift`
 * `UserProfile` + its nested `PlaybackPrefs`.
 *
 * Profiles without their own account share the primary one, so a "Kids" profile can be the same
 * account with a different look and a PIN on the way out.
 *
 * WIRE FORMAT (byte-for-byte with Apple): the roster is JSON-encoded to the SAME field names Apple's
 * `Codable` synthesizes ([encode]/[decode] below) so the roster the sync wave pushes/pulls round-trips
 * across platforms with no loss. [id] is the UPPERCASE canonical UUID string (Swift `UUID.uuidString`
 * is uppercase; Java `UUID.toString()` is lowercase, so every id is normalized to uppercase — this is
 * load-bearing for both the JSON id and the salted PIN hash below). Nil optionals are OMITTED (Apple's
 * `encodeIfPresent`); decode is tolerant so rosters saved by older builds still load.
 *
 * Kotlin note: Apple's struct uses `var`; the port is an immutable `data class` mutated with [copy]
 * (the ecc immutability rule), so [ProfileStore] rebuilds the roster list rather than mutating in place.
 */
data class UserProfile(
    val id: String = newId(),
    val name: String,
    val avatar: String,
    val accentID: String = "ember",
    val oled: Boolean = false,
    /** App UI text scale (0.80 to 1.40). Per-profile appearance, applied on switch. */
    val textScale: Double = 1.0,
    /** 4-digit parental gate, null = open. Stored as the salted [pinHash], never the raw digits. */
    val pin: String? = null,
    /** true = its own Stremio session in its own token slot. */
    val usesOwnAccount: Boolean = false,
    /** Bound account email, display only. */
    val email: String? = null,
    /**
     * The account's main profile (the one created by migration). It uses the account's own watch
     * history, exactly like before profiles existed. Every other shared profile keeps its own.
     */
    val isOwner: Boolean = false,
    /**
     * Family head (the account owner) may edit this profile from the vortx.tv dashboard WITHOUT its
     * PIN. Governs WEB edit permission only, not the on-device profile-switch PIN gate.
     */
    val familyEdit: Boolean = false,
    /**
     * Per-profile playback preferences (languages, subtitle style, source-ranking taste + filters),
     * mirrored into the flat preference keys the ranker/player read when this profile becomes active.
     * null = never customized (pre-feature roster); seeded from the flat values on first load.
     */
    val playback: PlaybackPrefs? = null,
    /**
     * Add-on transport URLs this profile has turned OFF. A per-profile, local overlay: the add-on
     * stays installed on the account, it is just hidden from THIS profile. null/empty = every
     * installed add-on is on.
     */
    val disabledAddons: List<String>? = null,
    /**
     * Kids profile: a parental-controls flag. When active the source list hides adult content and
     * CAM/fake junk regardless of the global filters (see `StreamRanking.passesUserFilters`).
     */
    val isKids: Boolean = false,
) {
    /** Whether this profile carries a parental PIN. Mirrors Apple `hasPin`. */
    val hasPin: Boolean get() = !(pin ?: "").isEmpty()

    /**
     * Whether this profile's history is the account library itself (the owner, and any profile on its
     * own account) or a private synced overlay (every other shared profile). Mirrors Apple
     * `usesEngineHistory`.
     */
    val usesEngineHistory: Boolean get() = isOwner || usesOwnAccount

    /**
     * Whether [input] unlocks this profile. Accepts hashed entries and the legacy plaintext ones from
     * rosters saved before hashing existed. Mirrors Apple `pinMatches`.
     */
    fun pinMatches(input: String): Boolean {
        val stored = pin
        if (stored.isNullOrEmpty()) return true
        if (stored.startsWith("sha256:")) return stored == pinHash(input, id)
        return stored == input   // legacy plaintext, migration-only
    }

    /** [PlaybackPrefs] with every dashboard/sync field, the Android port of Apple `PlaybackPrefs`. */
    fun encode(): JSONObject = encodeProfile(this)

    companion object {
        /**
         * The one and only owner-profile id. The account owner is a singleton, so it carries a FIXED id
         * on every device and install (minting a fresh random id per install was the root of the
         * duplicate-"Main" bug). UPPERCASE canonical to match Apple `UserProfile.ownerID.uuidString`.
         */
        const val OWNER_ID = "00000000-0000-0000-0000-00000000A11C"

        /** A fresh UUID in Apple's canonical (uppercase) form, so ids line up across platforms. */
        fun newId(): String = UUID.randomUUID().toString().uppercase()

        /** Normalize any UUID string to Apple's canonical uppercase form (Java emits lowercase). */
        fun normalizeId(raw: String): String = raw.uppercase()

        /**
         * Salted SHA-256 hash for a PIN, stored instead of the raw digits so a PIN can be changed but
         * never read back. The salt is the profile id (stable across devices, so hashed PINs survive
         * roster sync).
         *
         * BYTE-FOR-BYTE with Apple `UserProfile.pinHash`:
         *   digest = SHA256( UTF-8( "<UPPERCASE-uuidString>:<raw>" ) )
         *   result = "sha256:" + lowercase-hex(digest)
         * Apple's `profileID.uuidString` is UPPERCASE; ids here are already normalized uppercase, and the
         * extra [normalizeId] guard keeps a stray lowercase id from ever diverging the hash. A PIN set on
         * one platform therefore verifies on another via the synced roster.
         *
         * NOTE (mirrors Apple): a parental gate, NOT a security boundary. The salt travels in the synced
         * roster, so it is not secret; the hash only stops trivial plaintext readback.
         */
        fun pinHash(raw: String, profileId: String): String {
            val salt = normalizeId(profileId)
            val bytes = "$salt:$raw".toByteArray(Charsets.UTF_8)
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            return "sha256:" + digest.joinToString("") { "%02x".format(it) }
        }

        // ---- JSON codec (matches Apple's synthesized Codable: property-name keys, encodeIfPresent) ----

        fun encodeRoster(profiles: List<UserProfile>): String {
            val array = JSONArray()
            for (p in profiles) array.put(encodeProfile(p))
            return array.toString()
        }

        fun decodeRoster(json: String): List<UserProfile>? = runCatching {
            val array = JSONArray(json)
            (0 until array.length()).map { decodeProfile(array.getJSONObject(it)) }
        }.getOrNull()

        fun encodeProfile(p: UserProfile): JSONObject = JSONObject().apply {
            put("id", normalizeId(p.id))
            put("name", p.name)
            put("avatar", p.avatar)
            put("accentID", p.accentID)
            put("oled", p.oled)
            put("textScale", p.textScale)
            p.pin?.let { put("pin", it) }                       // encodeIfPresent
            put("usesOwnAccount", p.usesOwnAccount)
            p.email?.let { put("email", it) }                   // encodeIfPresent
            put("isOwner", p.isOwner)
            put("familyEdit", p.familyEdit)
            p.playback?.let { put("playback", PlaybackPrefs.encode(it)) }   // encodeIfPresent
            p.disabledAddons?.let { put("disabledAddons", JSONArray(it)) }  // encodeIfPresent
            put("isKids", p.isKids)
        }

        /** Tolerant decode: missing keys fall back to the same defaults as Apple's custom `init(from:)`. */
        fun decodeProfile(o: JSONObject): UserProfile = UserProfile(
            id = normalizeId(o.optString("id", "").ifEmpty { newId() }),
            name = o.optString("name", "Profile"),
            avatar = o.optString("avatar", "🍿"),     // 🍿
            accentID = o.optString("accentID", "ember"),
            oled = o.optBoolean("oled", false),
            textScale = o.optDouble("textScale", 1.0),
            pin = o.optStringOrNull("pin"),
            usesOwnAccount = o.optBoolean("usesOwnAccount", false),
            email = o.optStringOrNull("email"),
            isOwner = o.optBoolean("isOwner", false),
            familyEdit = o.optBoolean("familyEdit", false),
            playback = o.optJSONObject("playback")?.let { PlaybackPrefs.decode(it) },
            disabledAddons = o.optJSONArray("disabledAddons")?.toStringList(),
            isKids = o.optBoolean("isKids", false),
        )
    }
}

/**
 * What follows a viewer between profiles: track languages, subtitle look, and the whole source-ranking
 * taste + per-profile stream filters. Synced with the roster, so a profile keeps its preferences across
 * devices. Raw-string/optional fields mirror Apple `UserProfile.PlaybackPrefs` one-to-one so the wire
 * format round-trips; the optionals decode as null on older rosters (Apple's `decodeIfPresent`).
 */
data class PlaybackPrefs(
    val audioLang: String,
    val subtitleLang: String,
    val forcedPolicy: String,
    val subFont: String,
    val subSize: String,
    val subColor: String,
    val subBackground: String,
    val subSizeScale: Double? = null,
    /** Raw `SourceType` values, top priority first. */
    val sourceTypeOrder: List<String>? = null,
    val useAddonOrder: Boolean? = null,
    // Per-profile stream filters (null = "leave the flat SourcePreferences keys as they are").
    val safetyMode: String? = null,
    val instantOnly: Boolean? = null,
    val hideDeadTorrents: Boolean? = null,
    val hdrOnly: Boolean? = null,
    val excludeAV1: Boolean? = null,
    val excludeKeywords: String? = null,
    val includeKeywords: String? = null,
    val keywordsAreRegex: Boolean? = null,
    val maxResolution: Int? = null,          // 0 = no cap, else 720 / 1080 / 4000 (4K)
    val maxFileSizeGB: Double? = null,       // 0 = no cap
    val minResolution: Int? = null,          // 0 = no floor, else 720 / 1080 / 2160 (#117)
    val hideUnknownResolution: Boolean? = null,
    val preferredAudioOnly: Boolean? = null,
    // Smart Source Selection (Lane A).
    val preferKeywords: String? = null,
    val avoidBehavior: String? = null,       // "hide" (drop) or "rank" (demote-but-visible)
    val autoPickBest: Boolean? = null,
) {
    companion object {
        fun encode(p: PlaybackPrefs): JSONObject = JSONObject().apply {
            put("audioLang", p.audioLang)
            put("subtitleLang", p.subtitleLang)
            put("forcedPolicy", p.forcedPolicy)
            put("subFont", p.subFont)
            put("subSize", p.subSize)
            put("subColor", p.subColor)
            put("subBackground", p.subBackground)
            p.subSizeScale?.let { put("subSizeScale", it) }
            p.sourceTypeOrder?.let { put("sourceTypeOrder", JSONArray(it)) }
            p.useAddonOrder?.let { put("useAddonOrder", it) }
            p.safetyMode?.let { put("safetyMode", it) }
            p.instantOnly?.let { put("instantOnly", it) }
            p.hideDeadTorrents?.let { put("hideDeadTorrents", it) }
            p.hdrOnly?.let { put("hdrOnly", it) }
            p.excludeAV1?.let { put("excludeAV1", it) }
            p.excludeKeywords?.let { put("excludeKeywords", it) }
            p.includeKeywords?.let { put("includeKeywords", it) }
            p.keywordsAreRegex?.let { put("keywordsAreRegex", it) }
            p.maxResolution?.let { put("maxResolution", it) }
            p.maxFileSizeGB?.let { put("maxFileSizeGB", it) }
            p.minResolution?.let { put("minResolution", it) }
            p.hideUnknownResolution?.let { put("hideUnknownResolution", it) }
            p.preferredAudioOnly?.let { put("preferredAudioOnly", it) }
            p.preferKeywords?.let { put("preferKeywords", it) }
            p.avoidBehavior?.let { put("avoidBehavior", it) }
            p.autoPickBest?.let { put("autoPickBest", it) }
        }

        fun decode(o: JSONObject): PlaybackPrefs = PlaybackPrefs(
            audioLang = o.optString("audioLang", ""),
            subtitleLang = o.optString("subtitleLang", ""),
            forcedPolicy = o.optString("forcedPolicy", ""),
            subFont = o.optString("subFont", ""),
            subSize = o.optString("subSize", ""),
            subColor = o.optString("subColor", ""),
            subBackground = o.optString("subBackground", ""),
            subSizeScale = o.optDoubleOrNull("subSizeScale"),
            sourceTypeOrder = o.optJSONArray("sourceTypeOrder")?.toStringList(),
            useAddonOrder = o.optBooleanOrNull("useAddonOrder"),
            safetyMode = o.optStringOrNull("safetyMode"),
            instantOnly = o.optBooleanOrNull("instantOnly"),
            hideDeadTorrents = o.optBooleanOrNull("hideDeadTorrents"),
            hdrOnly = o.optBooleanOrNull("hdrOnly"),
            excludeAV1 = o.optBooleanOrNull("excludeAV1"),
            excludeKeywords = o.optStringOrNull("excludeKeywords"),
            includeKeywords = o.optStringOrNull("includeKeywords"),
            keywordsAreRegex = o.optBooleanOrNull("keywordsAreRegex"),
            maxResolution = o.optIntOrNull("maxResolution"),
            maxFileSizeGB = o.optDoubleOrNull("maxFileSizeGB"),
            minResolution = o.optIntOrNull("minResolution"),
            hideUnknownResolution = o.optBooleanOrNull("hideUnknownResolution"),
            preferredAudioOnly = o.optBooleanOrNull("preferredAudioOnly"),
            preferKeywords = o.optStringOrNull("preferKeywords"),
            avoidBehavior = o.optStringOrNull("avoidBehavior"),
            autoPickBest = o.optBooleanOrNull("autoPickBest"),
        )
    }
}

// ---- org.json null-tolerant helpers (Apple's decodeIfPresent semantics) ----

internal fun JSONObject.optStringOrNull(key: String): String? =
    if (has(key) && !isNull(key)) getString(key) else null

internal fun JSONObject.optBooleanOrNull(key: String): Boolean? =
    if (has(key) && !isNull(key)) getBoolean(key) else null

internal fun JSONObject.optIntOrNull(key: String): Int? =
    if (has(key) && !isNull(key)) getInt(key) else null

internal fun JSONObject.optDoubleOrNull(key: String): Double? =
    if (has(key) && !isNull(key)) getDouble(key) else null

internal fun JSONArray.toStringList(): List<String> =
    (0 until length()).map { getString(it) }
