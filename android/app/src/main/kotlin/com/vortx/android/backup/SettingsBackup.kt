package com.vortx.android.backup

import com.vortx.android.profile.UserProfile
import org.json.JSONObject
import java.math.BigDecimal
import java.math.BigInteger
import java.text.SimpleDateFormat
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
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

    data class ResolvedRoster(
        val roster: List<UserProfile>?,
        val modifiedSeconds: Double?,
    )

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
        "vortx.pgsSubtitleOCR",
        "vortx.downloads.queueOrder",
        "vortx.downloads.maxConcurrent",
        "vortx.moveSeeding.launchNagDismissedBuild",
        "vortx.subtitleOffsetMemory.v1",
    )

    /** Per-account sync bookkeeping and Keychain mutation state belong only to the current device. */
    private val DEVICE_LOCAL_KEY_PREFIXES = listOf(
        "vortx.sync.",
        "kcinvalidated.",
    )

    /** Old Keychain fallback slots contain credentials and must be scrubbed from pulled blobs. */
    private val SECRET_KEY_PREFIXES = listOf("kcfallback.")

    /** An app preference that is also safe to sync. Apple `SettingsBackup.swift:117-123`. */
    fun isSyncable(key: String): Boolean =
        isAppPref(key) &&
            !DEVICE_LOCAL_KEYS.contains(key) &&
            DEVICE_LOCAL_KEY_PREFIXES.none { key.startsWith(it) } &&
            SECRET_KEY_PREFIXES.none { key.startsWith(it) }

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
     * `createdAt` is emitted in Apple's canonical UTC second-precision shape. Current Foundation decoders
     * also accept fractional seconds and numeric offsets, which [decodeDomain] deliberately tolerates.
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
        if (!hasString(env, "format") || env.getString("format") != FORMAT_TAG) return null
        if (!hasJsonInt(env, "schema")) return null
        if (!hasString(env, "app")) return null
        if (!hasString(env, "bundleID")) return null
        if (!hasAppleIso8601Date(env, "createdAt")) return null
        if (!hasJsonInt(env, "keyCount")) return null
        if (!hasString(env, "payloadBase64")) return null
        val payload = env.getString("payloadBase64")
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
    fun rosterFromBlob(blob: Any?): List<UserProfile>? {
        val domain = domainFromBlob(blob) ?: return null
        val rosterBytes = domain[ROSTER_KEY] as? ByteArray ?: return null
        return UserProfile.decodeRoster(String(rosterBytes, Charsets.UTF_8))
    }

    /**
     * The roster's modification stamp out of a blob, in epoch SECONDS, or null when absent. Lets a pull
     * from an APPLE-authored doc (which carries no `vortx.rosterModified`) still feed the real tiebreak to
     * `ProfileStore.mergeInRoster` instead of defaulting to "keep local".
     */
    fun rosterModifiedFromBlob(blob: Any?): Double? {
        val v = domainFromBlob(blob)?.get(MODIFIED_KEY) ?: return null
        val seconds = when (v) {
            is Double -> v
            is Long -> v.toDouble() // tolerated: an integral stamp is a valid plist int
            else -> return null
        }
        return seconds.takeIf { it.isFinite() && it >= 0.0 }
    }

    /** The active-profile id out of a blob, or null when absent. Apple stores it as a plist string. */
    fun activeFromBlob(blob: Any?): String? = domainFromBlob(blob)?.get(ACTIVE_KEY) as? String

    private fun domainFromBlob(blob: Any?): Map<String, Any>? {
        val encoded = blob as? String ?: return null
        if (encoded.isEmpty()) return null
        val data = runCatching { Base64.getDecoder().decode(encoded) }.getOrNull() ?: return null
        return decodeDomain(data)
    }

    /**
     * Resolve the lossless settings carrier against `doc.vortx`. A valid, non-empty settings roster always
     * wins same-id fields over the lossy dashboard summary because that summary omits account identity.
     * When `doc.vortx.roster` is present, both carriers are lossless, so their own modification stamps pick
     * same-id fields. Profiles unique to either carrier survive and the maximum stamp moves forward.
     * A missing or unreadable settings blob leaves the fallback untouched.
     */
    fun resolveRosterForPull(
        pulledBlob: Any?,
        fallbackRoster: List<UserProfile>?,
        fallbackModifiedSeconds: Double?,
        fallbackIsLossless: Boolean = false,
    ): ResolvedRoster {
        val settingsRoster = rosterFromBlob(pulledBlob)?.takeIf { it.isNotEmpty() }
            ?: return ResolvedRoster(fallbackRoster, fallbackModifiedSeconds)
        val settingsModifiedSeconds = rosterModifiedFromBlob(pulledBlob)
        val settingsWinsSameId = !fallbackIsLossless ||
            (settingsModifiedSeconds ?: Double.NEGATIVE_INFINITY) >=
            (fallbackModifiedSeconds ?: Double.NEGATIVE_INFINITY)
        val preferred = if (settingsWinsSameId) settingsRoster else fallbackRoster.orEmpty()
        val secondary = if (settingsWinsSameId) fallbackRoster.orEmpty() else settingsRoster
        val preferredIds = preferred.mapTo(HashSet()) { it.id }
        val merged = preferred + secondary.filterNot { preferredIds.contains(it.id) }
        return ResolvedRoster(
            roster = merged,
            // `updatedAt` belongs to the lossy dashboard summary, not to the roster encoded in settings.
            // It may describe a completely unrelated account-doc edit. Only another FULL roster carrier
            // may donate its clock to the high-water mark.
            modifiedSeconds = if (fallbackIsLossless) {
                listOfNotNull(settingsModifiedSeconds, fallbackModifiedSeconds).maxOrNull()
            } else {
                settingsModifiedSeconds
            },
        )
    }

    /**
     * Build the `doc.settings` blob to push: the PULLED blob's domain with only this port's roster keys
     * overwritten, re-encoded. `VortXSyncManager.mergeLocalIntoDoc` uses this beside its `doc.vortx`
     * summary update so both platforms receive the lossless roster carrier.
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
        pulledBlob: Any?,
        roster: List<UserProfile>,
        rosterModifiedSeconds: Double,
        bundleId: String,
        app: String = "VortX",
        activeId: String? = null,
        deviceSettings: Map<String, Any> = emptyMap(),
        now: Date = Date(),
    ): String? {
        if (roster.isEmpty()) return null                       // never-zero

        val base: MutableMap<String, Any> = when {
            pulledBlob == null || pulledBlob == JSONObject.NULL -> LinkedHashMap()
            pulledBlob is String && pulledBlob.isEmpty() -> LinkedHashMap()
            pulledBlob is String -> LinkedHashMap(domainFromBlob(pulledBlob) ?: return null)
            else -> return null
        }

        // LOCAL-WINS, NEVER-DELETE settings read-merge (the app-settings leg, gap 1). [deviceSettings] holds this
        // device's own syncable global settings (Apple's exact keys, plist-native values from [plistSettingsFrom]).
        // Overlaying them onto the pulled domain SETS only the keys this device actually holds and leaves every
        // key it does not carry at the account's value, so a device missing a setting never wipes the account's
        // copy (the same asymmetric read-merge Apple's `mergedSyncBlob` / `apiKeys` use). Roster keys are written
        // AFTER this, so they always win their own slots; [deviceSettings] never carries a roster key.
        base.putAll(deviceSettings)

        // The roster rides as plist DATA of UTF-8 JSON, matching JSONEncoder().encode(profiles) on Apple.
        base[ROSTER_KEY] = UserProfile.encodeRoster(roster).toByteArray(Charsets.UTF_8)
        // A plist REAL of epoch SECONDS, matching Date().timeIntervalSince1970 / double(forKey:) on Apple.
        if (!rosterModifiedSeconds.isFinite() || rosterModifiedSeconds < 0.0) return null
        base[MODIFIED_KEY] = rosterModifiedSeconds
        activeId?.let { base[ACTIVE_KEY] = it }

        val bytes = encode(base, bundleId = bundleId, app = app, now = now) ?: return null
        return Base64.getEncoder().encodeToString(bytes)
    }

    // ------------------------------------------------------------ device app-settings seam (gap 1)

    /**
     * The storage type of a syncable global setting, so a value round-trips into and out of the plist domain and
     * back into Android [android.content.SharedPreferences] under the exact type its typed getter expects. This
     * is what makes an APPLE-authored blob safe to apply here: the plist decodes a bool/int/real/string with no
     * per-key manifest, and a typed getter (`getInt`, `getFloat`, ...) throws a ClassCastException if the wrong
     * type is written, so the target type must be known per key rather than guessed from the decoded value.
     */
    enum class SettingType { BOOL, INT, FLOAT, STRING, STRING_SET }

    /**
     * The GLOBAL device settings that ride `doc.settings` cross-device, each under Apple/web's EXACT key (the
     * same-key mandate) so a value set on one surface round-trips to iOS/tvOS/Mac/web/Android. Deliberately
     * scoped:
     *   - PER-PROFILE prefs (track languages `stremiox.tracks.*`, the `stremiox.streaming.*` source filters) are
     *     NOT here: they travel per profile inside the roster's `PlaybackPrefs`, so carrying the ACTIVE-profile
     *     flat key here too would cross-contaminate a peer whose active profile differs.
     *   - DEVICE-LOCAL keys (streaming cache size, server URL, upscaling, DV toggle, download queue/limits, ...)
     *     are excluded exactly as Apple excludes them (also caught by [isSyncable] as belt-and-braces).
     *   - The account TOKEN is never here: it lives only in the encrypted session store, never in `vortx_settings`.
     *   - Keys whose Android VALUE ENCODING is not provably identical to Apple's (e.g. a bool stored as the string
     *     "0"/"1", or a numeric step stored as a string) are omitted so a type/encoding mismatch can never land a
     *     value a typed getter would reject.
     */
    val SYNCABLE_SETTING_TYPES: Map<String, SettingType> = linkedMapOf(
        // Player + playback toggles
        "stremiox.autoAddLibrary" to SettingType.BOOL,
        "stremiox.directLinksOnly" to SettingType.BOOL,
        "stremiox.autoSkip" to SettingType.BOOL,
        "stremiox.autoplayTrailers" to SettingType.BOOL,
        "stremiox.autoLandscapeInPlayer" to SettingType.BOOL,
        "stremiox.keepPlayingInBackground" to SettingType.BOOL,
        "stremiox.communityTrickplay" to SettingType.BOOL,
        "stremiox.forceSDRTonemap" to SettingType.BOOL,
        "vortx.player.badSourceAutoRetry" to SettingType.BOOL,
        "vortx.player.bufferTuning" to SettingType.BOOL,
        "vortx.player.matchFrameRate" to SettingType.BOOL,
        "vortx.player.focusPrefetch" to SettingType.BOOL,
        "vortx.player.adaptiveProbe" to SettingType.BOOL,
        "vortx.stillWatchingPrompt" to SettingType.BOOL,
        // Player + playback string choices
        "stremiox.sub.font" to SettingType.STRING,
        "stremiox.sub.size" to SettingType.STRING,
        "stremiox.sub.color" to SettingType.STRING,
        "stremiox.sub.brightness" to SettingType.STRING,
        "stremiox.sub.background" to SettingType.STRING,
        "stremiox.sub.sizeScale" to SettingType.FLOAT,
        "stremiox.audioOutputMode" to SettingType.STRING,
        "stremiox.performanceMode" to SettingType.STRING,
        "stremiox.videoSize" to SettingType.STRING,
        "stremiox.hdrToneMapMode" to SettingType.STRING,
        "stremiox.player.seekBarStyle" to SettingType.STRING,
        "stremiox.trailerLanguage" to SettingType.STRING,
        "vortx.player.bufferIntent" to SettingType.STRING,
        "vortx.stillWatchingAfterEpisodes" to SettingType.INT,
        // Appearance + catalog presentation
        "stremiox.theme.accent" to SettingType.STRING,
        "stremiox.theme.oled" to SettingType.BOOL,
        "stremiox.theme.textScale" to SettingType.FLOAT,
        "stremiox.catalog.posterWidthPreset" to SettingType.STRING,
        "stremiox.catalog.posterRadiusPreset" to SettingType.STRING,
        "stremiox.catalog.landscapeCards" to SettingType.BOOL,
        "stremiox.catalog.hidePosterLabels" to SettingType.BOOL,
        // Home / Discover / detail layout
        "vortx.home.showCuratedRails" to SettingType.BOOL,
        "vortx.home.showCollectionsHub" to SettingType.BOOL,
        "vortx.discover.showCollectionsHub" to SettingType.BOOL,
        "vortx.mergeDiscoverSearch" to SettingType.BOOL,
        "vortx.detail.showFinancials" to SettingType.BOOL,
        "vortx.detail.spoilerSafe" to SettingType.BOOL,
        "vortx.spoilerBlur" to SettingType.BOOL,
        "vortx.collections.refreshCadence" to SettingType.STRING,
        "vortx.discover.regionPreference" to SettingType.STRING,
        "vortx.discover.hiddenCategories" to SettingType.STRING_SET,
        // Tabs
        "vortx.tabs.hide.discover" to SettingType.BOOL,
        "vortx.tabs.hide.live" to SettingType.BOOL,
        "vortx.tabs.hide.library" to SettingType.BOOL,
        "vortx.tabs.hide.search" to SettingType.BOOL,
        // Sync mirror flags + language
        "stremiox.sync.mirror.addons" to SettingType.BOOL,
        "stremiox.sync.mirror.library" to SettingType.BOOL,
        "stremiox.sync.mirror.cw" to SettingType.BOOL,
        "stremiox.languageOverride" to SettingType.STRING,
    )

    /**
     * Convert a `vortx_settings` [android.content.SharedPreferences.getAll] snapshot into the plist-native
     * `doc.settings` domain values for the [SYNCABLE_SETTING_TYPES] keys this device actually holds. Absent keys
     * are omitted (never-delete on push), and a stored value whose runtime type does not match the declared
     * [SettingType] is skipped rather than guessed (fail-soft). FLOAT is emitted as a plist REAL (Double) to match
     * Apple's `Double` UserDefaults storage; a STRING_SET is emitted as a sorted plist ARRAY (Apple stores an
     * array), so both directions stay deterministic.
     */
    fun plistSettingsFrom(all: Map<String, *>): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        for ((key, type) in SYNCABLE_SETTING_TYPES) {
            if (!isSyncable(key)) continue
            val raw = all[key] ?: continue
            val encoded: Any = when (type) {
                SettingType.BOOL -> raw as? Boolean ?: continue
                SettingType.INT -> (raw as? Int)?.toLong() ?: continue
                SettingType.FLOAT -> (raw as? Float)?.toDouble() ?: continue
                SettingType.STRING -> raw as? String ?: continue
                SettingType.STRING_SET -> {
                    val set = raw as? Set<*> ?: continue
                    set.filterIsInstance<String>().sorted()
                }
            }
            out[key] = encoded
        }
        return out
    }

    /**
     * Decode the [SYNCABLE_SETTING_TYPES] settings out of a pulled `doc.settings` blob, ready to write back into
     * `vortx_settings` under the exact type each key's getter expects. Returns null when the blob is absent or
     * unreadable (so the caller applies nothing and never wipes local settings); an empty map means the blob was
     * readable but carried none of these keys. A key whose decoded plist value cannot coerce to its declared type
     * is skipped (fail-soft) rather than written under a type a typed getter would reject.
     */
    fun settingsFromBlob(blob: Any?): Map<String, BackupValue>? {
        val domain = domainFromBlob(blob) ?: return null
        val out = LinkedHashMap<String, BackupValue>()
        for ((key, type) in SYNCABLE_SETTING_TYPES) {
            val value = domain[key] ?: continue
            val decoded: BackupValue? = when (type) {
                SettingType.BOOL -> (value as? Boolean)?.let(BackupValue::Bool)
                SettingType.INT -> when (value) {
                    is Long -> BackupValue.IntValue(value.toInt())
                    is Int -> BackupValue.IntValue(value)
                    else -> null
                }
                SettingType.FLOAT -> when (value) {
                    is Double -> BackupValue.FloatValue(value.toFloat())
                    is Long -> BackupValue.FloatValue(value.toFloat())
                    else -> null
                }
                SettingType.STRING -> (value as? String)?.let(BackupValue::Str)
                SettingType.STRING_SET ->
                    (value as? List<*>)?.let { BackupValue.StrSet(it.filterIsInstance<String>().toSet()) }
            }
            decoded?.let { out[key] = it }
        }
        return out
    }

    // ------------------------------------------------------------ file backup (TV-5)

    /**
     * The Android-local file backup (TV-5), the analogue of Apple `SettingsBackup.makeBackup` / `restore`.
     * This is DELIBERATELY separate from the `doc.settings` sync carrier above: a phone exports its own
     * syncable settings to a user-chosen file (VortX-Backup-<date>.json) and imports one back, never routing
     * through the account sync blob. It reuses the same envelope + [BinaryPlist] payload so a file stays
     * readable by the same decoder.
     *
     * TYPE FIDELITY is the one hard problem the sync carrier does not have. Android [android.content.SharedPreferences]
     * distinguishes Int / Long / Float / Boolean / String / Set<String>, but the plist collapses Int into
     * `int` (decoded as Long) and Float into `real` (decoded as Double), and cannot hold a Set. Writing a
     * value back under the wrong type would make a later typed getter throw a ClassCastException, which the
     * fail-soft mandate forbids. So [makeBackup] records a one-char type code per key in a reserved
     * [BACKUP_TYPES_KEY] manifest (a plist string, lossless), and [restoreValues] rebuilds the exact
     * SharedPreferences type from it. Sets are carried as string lists.
     */
    const val BACKUP_TYPES_KEY = "vortx.backup.entryTypes.v1"

    /** A restored value carrying its exact SharedPreferences type, so the caller can put it back verbatim. */
    sealed interface BackupValue {
        data class Bool(val value: Boolean) : BackupValue
        data class IntValue(val value: Int) : BackupValue
        data class LongValue(val value: Long) : BackupValue
        data class FloatValue(val value: Float) : BackupValue
        data class Str(val value: String) : BackupValue
        data class StrSet(val value: Set<String>) : BackupValue
    }

    /**
     * Encode a SharedPreferences snapshot ([android.content.SharedPreferences.getAll]) into a backup file's
     * bytes. Keeps only [isSyncable] keys (so device-local keys are excluded, exactly like the sync carrier
     * and Apple's `makeBackup`). Returns null when there is nothing syncable to back up, or the graph cannot
     * be encoded exactly.
     */
    fun makeBackup(
        all: Map<String, *>,
        bundleId: String,
        app: String = "VortX",
        now: Date = Date(),
    ): ByteArray? {
        val domain = LinkedHashMap<String, Any>()
        val types = JSONObject()
        for ((key, raw) in all) {
            if (raw == null || key == BACKUP_TYPES_KEY || !isSyncable(key)) continue
            val (value, code) = encodeBackupEntry(raw) ?: continue
            domain[key] = value
            types.put(key, code)
        }
        if (domain.isEmpty()) return null
        domain[BACKUP_TYPES_KEY] = types.toString()
        return encode(domain, bundleId = bundleId, app = app, now = now)
    }

    /**
     * Decode a backup file's bytes into typed values ready to write back into SharedPreferences. Returns null
     * for a file that is not a valid backup (Apple's `notABackup` / `corruptPayload` cases). A set-only merge
     * is the caller's responsibility: it must only `put` these keys and never `clear`, so keys absent from the
     * backup keep their current values (Apple `restore`'s never-wipe contract).
     */
    fun restoreValues(bytes: ByteArray): Map<String, BackupValue>? {
        val domain = decodeDomain(bytes) ?: return null
        val types = runCatching { JSONObject(domain[BACKUP_TYPES_KEY] as? String ?: "{}") }
            .getOrDefault(JSONObject())
        val out = LinkedHashMap<String, BackupValue>()
        for ((key, value) in domain) {
            if (key == BACKUP_TYPES_KEY || !isSyncable(key)) continue
            decodeBackupEntry(value, types.optString(key, ""))?.let { out[key] = it }
        }
        return out
    }

    /** SharedPreferences value -> (plist-representable value, one-char type code). */
    private fun encodeBackupEntry(raw: Any): Pair<Any, String>? = when (raw) {
        is Boolean -> raw to "b"
        is Int -> raw.toLong() to "i"
        is Long -> raw to "l"
        is Float -> raw.toDouble() to "f"
        is String -> raw to "s"
        is Set<*> -> raw.filterIsInstance<String>() to "S"
        else -> null // an unrepresentable type is skipped, never guessed (fail-soft)
    }

    /**
     * Plist-decoded value + its recorded type code -> the exact SharedPreferences type. When the manifest has
     * no code for a key (a foreign or older backup), fall back to the decoded value's own type so the restore
     * still lands something sensible rather than dropping the key.
     */
    private fun decodeBackupEntry(value: Any, code: String): BackupValue? = when (code) {
        "b" -> (value as? Boolean)?.let(BackupValue::Bool)
        "i" -> (value as? Long)?.let { BackupValue.IntValue(it.toInt()) }
        "l" -> (value as? Long)?.let(BackupValue::LongValue)
        "f" -> (value as? Double)?.let { BackupValue.FloatValue(it.toFloat()) }
        "s" -> (value as? String)?.let(BackupValue::Str)
        "S" -> (value as? List<*>)?.let { BackupValue.StrSet(it.filterIsInstance<String>().toSet()) }
        else -> when (value) {
            is Boolean -> BackupValue.Bool(value)
            is Long -> BackupValue.LongValue(value)
            is Double -> BackupValue.FloatValue(value.toFloat())
            is String -> BackupValue.Str(value)
            is List<*> -> BackupValue.StrSet(value.filterIsInstance<String>().toSet())
            else -> null
        }
    }

    /**
     * Apple's encoder wire format: UTC, second precision, trailing Z.
     */
    private fun iso8601(date: Date): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(date)

    private fun hasString(objectValue: JSONObject, key: String): Boolean =
        objectValue.has(key) && !objectValue.isNull(key) && objectValue.opt(key) is String

    /**
     * Swift `Codable` requires a JSON integer for both `schema` and `keyCount`; strings/bools fail.
     * Foundation accepts integral decimal/exponent forms such as `1.0` and `1e3`, but rejects values
     * outside signed 64-bit `Int`. BigDecimal avoids Double's rounded Long.MAX boundary accepting 2^63.
     */
    private fun hasJsonInt(objectValue: JSONObject, key: String): Boolean {
        if (!objectValue.has(key) || objectValue.isNull(key)) return false
        val value = objectValue.opt(key)
        if (value !is Number) return false
        val integer = runCatching { BigDecimal(value.toString()).toBigIntegerExact() }.getOrNull()
            ?: return false
        if (integer < SWIFT_INT_MIN || integer > SWIFT_INT_MAX) return false
        // Foundation rejects floating-form Int.min itself and positive values whose Double rounds onto 2^63.
        // It still accepts negative Int.min + 1 decimal/exponent forms even though their Double also rounds to
        // -2^63, so keep the lower check exact rather than applying symmetric floating bounds.
        if (value is BigDecimal || value is Double || value is Float) {
            val floating = value.toDouble()
            if (!floating.isFinite() ||
                integer == SWIFT_INT_MIN || floating >= SWIFT_INT_EXCLUSIVE_BOUND
            ) {
                return false
            }
        }
        return true
    }

    /**
     * Current local Foundation `.iso8601` verification accepts internet date-time with optional fractions
     * plus `Z`, `+HH`, `+HHMM`, or `+HH:MM`; lowercase `t`/`z` is rejected. Keep this grammar aligned with
     * those executed fixtures rather than broadening it independently.
     */
    private fun hasAppleIso8601Date(objectValue: JSONObject, key: String): Boolean {
        if (!hasString(objectValue, key)) return false
        val raw = objectValue.getString(key)
        if (!APPLE_ISO8601.matches(raw)) return false
        val normalized = COMPACT_ISO8601_OFFSET.replace(raw, "\$1:\$2")
        return try {
            OffsetDateTime.parse(normalized, DateTimeFormatter.ISO_OFFSET_DATE_TIME)
            true
        } catch (_: DateTimeParseException) {
            false
        }
    }

    private val APPLE_ISO8601 =
        Regex("""^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}(?::?\d{2})?)$""")
    private val COMPACT_ISO8601_OFFSET = Regex("""([+-]\d{2})(\d{2})$""")
    private const val SWIFT_INT_EXCLUSIVE_BOUND = 9_223_372_036_854_775_808.0
    private val SWIFT_INT_MIN: BigInteger = BigInteger.valueOf(Long.MIN_VALUE)
    private val SWIFT_INT_MAX: BigInteger = BigInteger.valueOf(Long.MAX_VALUE)
}
