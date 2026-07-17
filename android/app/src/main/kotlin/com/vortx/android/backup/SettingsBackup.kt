package com.vortx.android.backup

import com.vortx.android.profile.UserProfile
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The Android port of Apple `app/SourcesShared/SettingsBackup.swift`: the portable settings envelope that
 * the VortX account sync reuses as its `doc.settings` payload.
 *
 * WHY THIS UNIT EXISTS (the cross-platform bug it closes). Apple carries the profile roster ONLY inside
 * `doc.settings`. Both of its read paths prove it:
 *   - `VortXSyncManager.swift:794` (push)  reads the cloud roster via `decodeRoster(fromSettingsBlob:)`
 *   - `VortXSyncManager.swift:921-934` (pull) restores the roster via `SettingsBackup.restore`
 * Apple never reads `doc.vortx.roster`, which is the carrier Android invented while this unit was
 * unported (`sync/VortXSyncDoc.kt:19-30`). So today the roster does NOT round-trip:
 *   - Android to Apple: Apple's `decodeRoster` returns nil for an Android-authored doc, so its push skips
 *     the union and then OVERWRITES `doc.settings` from its own local roster. Every Android-authored
 *     profile is silently dropped from the account.
 *   - Apple to Android: Android falls back to the lossy `vortx.profiles` dashboard summary, which has no
 *     `usesOwnAccount` and no `email`, so an own-account binding reconstructs as a shared profile.
 *
 * THE SHAPE DIVERGENCE, EXACTLY. Both platforms agree on the key (`stremiox.profiles`,
 * Apple `Profiles.swift:167` == Android `ProfileStore.kt:668`) and on the roster JSON itself
 * (`UserProfile.encodeProfile` already mirrors Apple's synthesized `Codable`: property-name keys,
 * uppercase UUID ids, `encodeIfPresent` omission). They diverge on the CARRIER and on the VALUE TYPE:
 *   - carrier: Apple = a base64 JSON envelope wrapping a base64 BINARY PLIST of the whole UserDefaults
 *     domain; Android = a plain JSON array under a different doc key.
 *   - value type: Apple stores the roster as plist DATA, and every Apple read casts hard to `Data`
 *     (`Profiles.swift:692`, `Profiles.swift:869`, `VortXSyncManager.swift:749` all `as? Data` /
 *     `data(forKey:)`). Android persists the same JSON as a SharedPreferences STRING
 *     (`ProfileStore.kt:430`). Writing the roster as a plist STRING would make every one of those casts
 *     return nil, so Apple would see an empty roster and clobber it. [ROSTER_KEY] is therefore written as
 *     a plist data node holding the UTF-8 JSON bytes, which is what `JSONEncoder().encode(profiles)`
 *     produces on Apple (`Profiles.swift:718-719`).
 *
 * NEVER-SHRINK / FAIL-CLOSED. Apple's `restore` writes EVERY key of the blob into `UserDefaults` and only
 * ever SETS (`SettingsBackup.swift:147-153`), so the blob is the settings channel between Apple devices,
 * not just a roster carrier. [settingsBlobFor] therefore starts from the PULLED domain and overwrites only
 * the roster keys this port owns, and returns null (leave the account's blob untouched) whenever it cannot
 * fully round-trip what it pulled. Publishing a partial blob would wipe every Apple key we failed to read.
 * This is the same read-merge discipline as `VortXSyncDoc.buildVortx` and the `apiKeys` merge.
 *
 * NOT PORTED, DELIBERATELY: Apple's `makeBackup` / `restore` (they read and write the whole live
 * `UserDefaults` domain) and the export/import file UI. Android's local settings live in SharedPreferences
 * under different keys, so mirroring the whole domain would push Android-only keys into Apple's
 * `UserDefaults`. This port owns the roster keys and passes every foreign key through untouched. The
 * whole-domain transfer is a separate decision, not a prerequisite for roster parity.
 */
object SettingsBackup {

    /** Envelope schema. Apple `SettingsBackup.swift:20`. */
    const val SCHEMA = 1

    /** The only field Apple's `decodeDomain` validates. Apple `SettingsBackup.swift:21`, `:111`. */
    const val FORMAT_TAG = "vortx-backup"

    /** The roster key, identical on both platforms. Apple `Profiles.swift:167`. */
    const val ROSTER_KEY = "stremiox.profiles"

    /** The active-selection key. Apple `Profiles.swift:168`, read as a String (`Profiles.swift:696`). */
    const val ACTIVE_KEY = "stremiox.profiles.active"

    /**
     * The roster LWW tiebreak, in epoch SECONDS. Apple writes `Date().timeIntervalSince1970`
     * (`Profiles.swift:725`) and reads it back with `double(forKey:)` (`Profiles.swift:975-976`), so this
     * is a plist REAL. Android's `ProfileStore.rosterModified` is already epoch-seconds
     * (`ProfileStore.kt:438`, `:445`), so it converts straight across. Writing millis here would make every
     * Android push look like the year 57000 to Apple and always win the merge.
     */
    const val MODIFIED_KEY = "stremiox.profiles.modified"

    /**
     * Framework/OS keys that can appear in Apple's app domain but are not our preferences. Byte-parity with
     * Apple `SettingsBackup.swift:25` so a blob authored by Apple filters identically here.
     */
    private val SKIP_PREFIXES =
        listOf("Apple", "NS", "com.apple.", "WebKit", "WebDatabase", "PK", "MetricKit", "INNext")

    /** Apple `SettingsBackup.swift:27-29`. */
    fun isAppPref(key: String): Boolean = SKIP_PREFIXES.none { key.startsWith(it) }

    /**
     * PER-DEVICE keys that must NEVER sync between devices. Byte-parity with Apple
     * `SettingsBackup.swift:37-44`: each device keeps its own streaming-cache size (sized to its own
     * storage), its own streaming server, its own upscaling, and its own Dolby Vision toggle (which depends
     * on THAT device's display and decoder). Filtered out of BOTH directions, so an Android push can never
     * carry a peer's DV choice back over a freshly-toggled Apple device.
     */
    val DEVICE_LOCAL_KEYS: Set<String> = setOf(
        "stremiox.diskCacheBytes",
        "stremiox.serverURL",
        "stremiox.videoUpscaling",
        "stremiox.dvRemux",
    )

    /** An app preference that is ALSO safe to sync. Apple `SettingsBackup.swift:47-49`. */
    fun isSyncable(key: String): Boolean = isAppPref(key) && !DEVICE_LOCAL_KEYS.contains(key)

    /**
     * The 0.4 rename seam. Both empty today, matching Apple `SettingsBackup.swift:57-58`. Populate IN
     * LOCKSTEP with Apple when the `stremiox.` prefix moves to `vortx.`: a one-sided rename would split the
     * account's roster into two keys and each platform would read an empty roster from the other.
     */
    val KEY_PREFIX_MIGRATIONS: Map<String, String> = emptyMap()
    val KEY_MIGRATIONS: Map<String, String> = emptyMap()

    /** Apple `SettingsBackup.swift:60-66`. */
    fun migratedKey(key: String): String {
        KEY_MIGRATIONS[key]?.let { return it }
        for ((old, new) in KEY_PREFIX_MIGRATIONS) {
            if (key.startsWith(old)) return new + key.substring(old.length)
        }
        return key
    }

    // ------------------------------------------------------------ envelope

    /**
     * Wrap a defaults dictionary into the portable JSON envelope. Apple `SettingsBackup.swift:95-105`.
     *
     * Every one of the seven fields is REQUIRED: Apple decodes into a non-optional `Codable` struct, so a
     * missing field throws and the whole blob is rejected as `notABackup` (`SettingsBackup.swift:111`).
     * `createdAt` must be ISO8601 with NO fractional seconds, because Swift's `.iso8601` strategy uses
     * `ISO8601DateFormatter` with default `.withInternetDateTime`, which does not parse them.
     *
     * Returns null when the domain holds a value [BinaryPlist] cannot represent exactly.
     */
    fun encode(domain: Map<String, Any>, bundleId: String, app: String, now: Date = Date()): ByteArray? {
        val plist = BinaryPlist.encode(domain) ?: return null
        val env = JSONObject().apply {
            put("format", FORMAT_TAG)
            put("schema", SCHEMA)
            put("app", app)
            put("bundleID", bundleId)
            put("createdAt", iso8601(now))
            put("keyCount", domain.size)
            put("payloadBase64", Base64.getEncoder().encodeToString(plist))
        }
        return env.toString().toByteArray(Charsets.UTF_8)
    }

    /**
     * Validate and unwrap a backup back into a defaults dictionary, app-syncable keys only. Apple
     * `SettingsBackup.swift:108-121`. Returns null for Apple's `notABackup` / `corruptPayload` cases, which
     * are expected inputs (the blob arrives over the network), not programming errors.
     */
    fun decodeDomain(data: ByteArray): Map<String, Any>? {
        val env = runCatching { JSONObject(String(data, Charsets.UTF_8)) }.getOrNull() ?: return null
        if (env.optString("format") != FORMAT_TAG) return null
        val payload = env.optString("payloadBase64", "")
        if (payload.isEmpty()) return null
        val plist = runCatching { Base64.getDecoder().decode(payload) }.getOrNull() ?: return null
        val decoded = BinaryPlist.decode(plist) as? Map<*, *> ?: return null
        val out = LinkedHashMap<String, Any>()
        for ((k, v) in decoded) {
            val key = k as? String ?: continue
            if (v != null && isSyncable(key)) out[key] = v
        }
        return out
    }

    // ------------------------------------------------------------ roster seam

    /**
     * Decode just the profile roster out of a doc's `settings` blob. The exact port of Apple
     * `VortXSyncManager.decodeRoster(fromSettingsBlob:)` (`VortXSyncManager.swift:746-752`), including its
     * `as? Data` cast: the roster rides as plist DATA holding UTF-8 JSON, never as a plist string.
     *
     * Returns null when the blob is absent, unreadable, or carries no roster, so a caller can skip the
     * union when there is nothing to merge (Apple's exact contract).
     */
    fun rosterFromBlob(blob: String?): List<UserProfile>? {
        val domain = domainFromBlob(blob) ?: return null
        val rosterBytes = domain[ROSTER_KEY] as? ByteArray ?: return null
        return UserProfile.decodeRoster(String(rosterBytes, Charsets.UTF_8))
    }

    /**
     * The roster's modification stamp out of a blob, in epoch SECONDS, or null when absent. Lets a pull
     * from an APPLE-authored doc (which carries no `vortx.rosterModified`) still feed the real tiebreak to
     * `ProfileStore.mergeInRoster` instead of defaulting to "keep local".
     */
    fun rosterModifiedFromBlob(blob: String?): Long? {
        val v = domainFromBlob(blob)?.get(MODIFIED_KEY) ?: return null
        return when (v) {
            is Double -> v.toLong()
            is Long -> v          // tolerated: an integral stamp is a valid plist int
            else -> null
        }
    }

    /** The active-profile id out of a blob, or null when absent. Apple stores it as a plist string. */
    fun activeFromBlob(blob: String?): String? = domainFromBlob(blob)?.get(ACTIVE_KEY) as? String

    private fun domainFromBlob(blob: String?): Map<String, Any>? {
        if (blob.isNullOrEmpty()) return null
        val data = runCatching { Base64.getDecoder().decode(blob) }.getOrNull() ?: return null
        return decodeDomain(data)
    }

    /**
     * Build the `doc.settings` blob to push: the PULLED blob's domain with only this port's roster keys
     * overwritten, re-encoded. This is the write half of the round-trip, and the one D5 wires into
     * `VortXSyncManager.mergeLocalIntoDoc` next to `doc["vortx"] = ...`.
     *
     * Returns null meaning "do not touch `doc["settings"]`", in three cases, each deliberate:
     *   1. [roster] is empty. NEVER-ZERO: a momentarily empty local roster must not overwrite the account's
     *      populated one. Mirrors `VortXSyncDoc.buildVortx`'s guard (`VortXSyncDoc.kt:190-192`).
     *   2. [pulledBlob] is present but does NOT decode. FAIL-CLOSED: the blob is the settings channel
     *      between Apple devices, so republishing it from a partial read would drop every key we could not
     *      parse. Skipping the push loses nothing permanently; the next push retries.
     *   3. The rebuilt domain cannot be encoded exactly.
     * A null/absent [pulledBlob] is NOT a failure: that is a fresh or Android-only account, where a
     * roster-only blob is complete and correct.
     *
     * [activeId] is opt-in. Apple keeps `ACTIVE_KEY` OUT of `DEVICE_LOCAL_KEYS`, so it does ride the blob
     * on Apple, but selection is per-device on Android (`VortXSyncDoc.kt` treats `activeProfile` as
     * advisory). Left null, the pulled value passes through untouched rather than being clobbered.
     */
    fun settingsBlobFor(
        pulledBlob: String?,
        roster: List<UserProfile>,
        rosterModifiedSeconds: Long,
        bundleId: String,
        app: String = "VortX",
        activeId: String? = null,
        now: Date = Date(),
    ): String? {
        if (roster.isEmpty()) return null                       // never-zero

        val base: MutableMap<String, Any> = if (pulledBlob.isNullOrEmpty()) {
            LinkedHashMap()                                     // fresh account: nothing to preserve
        } else {
            LinkedHashMap(domainFromBlob(pulledBlob) ?: return null)   // fail-closed on an unreadable blob
        }

        // The roster rides as plist DATA of UTF-8 JSON, matching JSONEncoder().encode(profiles) on Apple.
        base[ROSTER_KEY] = UserProfile.encodeRoster(roster).toByteArray(Charsets.UTF_8)
        // A plist REAL of epoch SECONDS, matching Date().timeIntervalSince1970 / double(forKey:) on Apple.
        base[MODIFIED_KEY] = rosterModifiedSeconds.toDouble()
        activeId?.let { base[ACTIVE_KEY] = it }

        val bytes = encode(base, bundleId = bundleId, app = app, now = now) ?: return null
        return Base64.getEncoder().encodeToString(bytes)
    }

    /**
     * Apple's `.iso8601` wire format: UTC, second precision, trailing Z. Fractional seconds would make
     * Swift's decoder throw and reject the whole envelope as `notABackup`.
     */
    private fun iso8601(date: Date): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(date)
}
