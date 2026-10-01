package com.vortx.android.sync

import com.vortx.android.profile.PlaybackPrefs
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.profile.WatchEntry
import com.vortx.android.profile.optStringOrNull
import com.vortx.android.profile.toStringList
import com.vortx.android.data.AddonTombstones
import com.vortx.android.engine.PublicAddressPolicy
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/**
 * The encrypted sync DOCUMENT codec: the pure, session-free transforms between the local profile roster
 * + per-profile watch overlays + delete tombstones and the JSON `doc.vortx` block the VortX account
 * stores. Android's analogue of the Apple `VortXSyncManager.vortxSummary` (write side) and its
 * `decodeRoster` / `byProfile` / `deletedProfiles` reads (read side), in
 * `app/SourcesShared/VortXSyncManager.swift`.
 *
 * WHY A SECOND JSON ROSTER CARRIER: Apple carries the roster inside the opaque base64 `doc.settings`
 * blob (a binary-plist of the whole UserDefaults domain) and emits `doc.vortx.profiles` only as a lossy
 * DASHBOARD summary. Android now reads and writes that canonical settings carrier too, while retaining
 * the older full `doc.vortx.roster` for compatibility with deployed Android clients. This codec carries:
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

    /** An installable account-owned descriptor. The raw object is retained so opaque manifest fields survive. */
    data class AddonDescriptor(
        val transportUrl: String,
        val raw: JSONObject,
    )

    /** Owner library record. On the wire t/d are seconds; in memory they remain zero-safe milliseconds. */
    data class OwnerLibraryItem(
        val metaId: String,
        val type: String,
        val name: String,
        val poster: String?,
        val videoId: String?,
        val timeOffsetMs: Long,
        val durationMs: Long,
        /** A genuine producer event clock only; null is intentionally not replaced with "now". */
        val lastWatched: String?,
        val watched: String? = null,
        val currentVideoWatched: Boolean? = null,
        val timesWatched: Long? = null,
        val removed: Boolean = false,
        val wholeTitleWatched: Boolean? = null,
        val eventEpochMs: Long? = null,
        /** Native mutation clock is only a conflict floor, never a substitute for a watch clock. */
        val nativeEventEpochMs: Long? = null,
        /** Internal carrier authority, not a native membership field. */
        val historyOnly: Boolean = false,
        /** Sparse history producers omit watch flags; omission is not an explicit unwatch. */
        val declaredWatchFields: Set<String>? = null,
        /** Internal permission derived from an authenticated newer addedAt stamp, never decoded from a row. */
        val membershipAddedAt: Double? = null,
        /** Internal CAS admission from an exact account-owned raw/projection pair; never decoded from wire. */
        val conditionalHistory: ConditionalOwnerHistory? = null,
    ) {
        val identity: String get() = "$type:$metaId"
    }

    data class ConditionalOwnerHistory(val expected: OwnerLibraryItem, val priorEventEpochMs: Long, val priorLastWatchedEpochMs: Long)

    /** The parsed roster + overlay + tombstone view of a pulled doc, ready for the ordered syncDown apply. */
    data class Parsed(
        /** The remote roster, or null when the doc carries neither `vortx.roster` nor `vortx.profiles`. */
        val roster: List<UserProfile>?,
        /** The roster's modification stamp in epoch-SECONDS (mergeInRoster's tiebreak), or null. */
        val rosterModifiedSeconds: Double?,
        /** True only when [roster] came from the full `vortx.roster`, never the lossy dashboard summary. */
        val rosterIsLossless: Boolean,
        /** Each non-owner profile's overlay library/CW, keyed by profile id then meta id. */
        val overlays: Map<String, Map<String, WatchEntry>>,
        /** Cross-device profile delete tombstones. */
        val deletedProfiles: List<String>,
        /** Back-compatible effective owner-library removal set. */
        val deletedLibrary: List<String>,
        /** LWW owner-library stamps, keyed by normalized id then removedAt/addedAt. */
        val deletedLibraryTs: Map<String, Map<String, Double>>,
        /** Back-compatible effective add-on removal set. */
        val deletedAddons: List<String>,
        /** LWW add-on stamps, keyed by normalized transport URL then removedAt/addedAt. */
        val deletedAddonsTs: Map<String, Map<String, Double>>,
        /** Stamp-less removals authored by the web client; only syncDown may mint these into stamps. */
        val webAddonRemovals: List<String>,
        /** App-owned and web-owned installable descriptors, app rows winning duplicate identities. */
        val addons: List<AddonDescriptor>,
        /** Shared top-level priority spine. Null means the document did not carry an order. */
        val addonOrder: List<String>?,
        /** App-owned vortx.library, falling back to the website's top-level library import. */
        val ownerLibrary: List<OwnerLibraryItem>?,
        /** The remote device's active profile (advisory; selection stays per-device). */
        val activeProfile: String?,
        val ownerHistory: List<OwnerLibraryItem> = emptyList(),
    )

    // ---- Read: doc.vortx -> local-state view ----

    fun parse(doc: JSONObject): Parsed {
        val webAddonRemovals = parseAddonIds(doc.optJSONArray("webAddonRemovals"))
        val vortx = doc.optJSONObject("vortx")
            ?: return Parsed(
                null,
                null,
                false,
                emptyMap(),
                emptyList(),
                emptyList(),
                emptyMap(),
                emptyList(),
                emptyMap(),
                webAddonRemovals,
                ownedAddons(doc, null),
                parseAddonOrder(doc.optJSONArray("addonOrder")),
                ownerLibrary(doc, null),
                null,
            )

        // Roster: prefer the FULL lossless carrier (Android-authored); else reconstruct from the dashboard
        // summary (Apple / web-authored) so a cross-surface doc still yields a usable roster.
        val fullRoster = vortx.optJSONArray("roster")
        val roster: List<UserProfile>? = fullRoster?.let { arr ->
            (0 until arr.length()).mapNotNull { i -> arr.optJSONObject(i)?.let { UserProfile.decodeProfile(it) } }
        } ?: vortx.optJSONArray("profiles")?.let { arr ->
            (0 until arr.length()).mapNotNull { i -> arr.optJSONObject(i)?.let { rosterFromSummary(it) } }
        }

        // Modification tiebreak in fractional epoch SECONDS: preserve an explicit Double exactly; else
        // derive from Apple's epoch-ms `updatedAt` without dropping its millisecond component. Non-numeric,
        // negative, or non-finite values are absent rather than becoming JSONObject's synthetic zero.
        val modified: Double? = when {
            vortx.has("rosterModified") -> finiteClock(vortx.opt("rosterModified"))
            vortx.has("updatedAt") -> finiteClock(vortx.opt("updatedAt"))?.div(1000.0)
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
        val deletedLibrary = vortx.optJSONArray("deletedLibrary")?.toStringList() ?: emptyList()
        val deletedLibraryTs = parseLibraryTimestamps(vortx.optJSONObject("deletedLibraryTs"))
        val deletedAddons = parseAddonIds(vortx.optJSONArray("deletedAddons"))
        val deletedAddonsTs = parseAddonTimestamps(vortx.optJSONObject("deletedAddonsTs"))
        val active = vortx.optStringOrNull("activeProfile")
        return Parsed(
            roster,
            modified,
            fullRoster != null,
            overlays,
            deleted,
            deletedLibrary,
            deletedLibraryTs,
            deletedAddons,
            deletedAddonsTs,
            webAddonRemovals,
            ownedAddons(doc, vortx),
            parseAddonOrder(doc.optJSONArray("addonOrder")),
            ownerLibrary(doc, vortx),
            active,
            ownerHistory(vortx),
        )
    }

    internal fun ownerHistory(vortx: JSONObject?): List<OwnerLibraryItem> {
        val rows = vortx?.optJSONObject("byProfile")?.optJSONObject(UserProfile.OWNER_ID)?.optJSONArray("ownerHistory") ?: return emptyList()
        if (rows.length() > 10_000) return emptyList()
        return (0 until rows.length()).mapNotNull { index -> rows.optJSONObject(index)?.let(::ownerHistoryItem) }
    }

    internal fun ownerHistoryItem(raw: JSONObject): OwnerLibraryItem? {
        for (field in listOf("id", "type", "name", "v")) if ((raw.opt(field) as? String).isNullOrBlank()) return null
        val event = OwnerLibraryHistoryPolicy.unsignedInteger(raw.opt("eventEpochMs")) ?: return null
        if (event !in 1..9_007_199_254_740_991L) return null
        val time = (raw.opt("t") as? Number)?.toDouble() ?: return null
        val duration = (raw.opt("d") as? Number)?.toDouble() ?: return null
        if (!time.isFinite() || !duration.isFinite() || time !in 0.0..2_000_000.0 || duration <= 0 || duration > 2_000_000) return null
        val item = ownerLibraryItem(raw) ?: return null
        if (OwnerLibraryHistoryPolicy.watchClock(item) == null) return null
        return item.copy(removed = true, historyOnly = true,
            declaredWatchFields = setOf("watched", "currentVideoWatched", "timesWatched", "wholeTitleWatched").filterTo(hashSetOf()) { raw.has(it) })
    }

    internal fun mergeLocalOwnerHistory(vortx: JSONObject, local: List<OwnerLibraryItem>?) {
        val history = local.orEmpty().filter { it.historyOnly && ownerHistoryItem(OwnerLibraryHistoryPolicy.encode(it, JSONObject())) != null }
        if (history.isEmpty()) return
        if (vortx.has("byProfile") && vortx.optJSONObject("byProfile") == null) return
        val byProfile = vortx.optJSONObject("byProfile") ?: JSONObject().also { vortx.put("byProfile", it) }
        if (byProfile.has(UserProfile.OWNER_ID) && byProfile.optJSONObject(UserProfile.OWNER_ID) == null) return
        val owner = byProfile.optJSONObject(UserProfile.OWNER_ID) ?: JSONObject().also { byProfile.put(UserProfile.OWNER_ID, it) }
        if (owner.has("ownerHistory") && owner.optJSONArray("ownerHistory") == null) return
        val previous = owner.optJSONArray("ownerHistory")
        if ((previous?.length() ?: 0) > 10_000) return
        val merged = OwnerLibraryHistoryPolicy.merge(previous, history, emptySet(), ::ownerHistoryItem)
        if (merged.length() <= 10_000) owner.put("ownerHistory", merged)
    }

    /**
     * App data wins over a website/Stremio import when present. Invalid rows are independently ignored;
     * absence stays null so a partial document can never mean "clear the engine library".
     */
    internal fun ownerLibrary(doc: JSONObject, vortx: JSONObject? = doc.optJSONObject("vortx")): List<OwnerLibraryItem>? {
        val rows = vortx?.optJSONArray("library") ?: doc.optJSONArray("library") ?: return null
        return buildMap<String, OwnerLibraryItem> {
            for (index in 0 until rows.length()) {
                val raw = rows.optJSONObject(index) ?: continue
                val item = ownerLibraryItem(raw) ?: continue
                putIfAbsent(item.identity, item.copy(declaredWatchFields =
                    setOf("watched", "currentVideoWatched", "timesWatched", "wholeTitleWatched").filterTo(hashSetOf()) { raw.has(it) }))
            }
        }.values.toList()
    }

    internal fun ownerLibraryItem(row: JSONObject): OwnerLibraryItem? {
        val id = row.opt("id") as? String ?: return null
        val type = row.opt("type") as? String ?: return null
        if (!isTypedCatalogIdentity(id) || type !in setOf("movie", "series")) return null
        fun nullableType(key: String, valid: (Any) -> Boolean): Boolean =
            !row.has(key) || row.isNull(key) || valid(row.get(key))
        if (!nullableType("lastWatched") { it is String } || !nullableType("v") { it is String } ||
            !nullableType("watched") { it is String } || !nullableType("currentVideoWatched") { it is Boolean } ||
            !nullableType("wholeTitleWatched") { it is Boolean } || !nullableType("removed") { it is Boolean } ||
            !nullableType("timesWatched") { OwnerLibraryHistoryPolicy.unsignedInteger(it)?.let { n -> n <= 0xffff_ffffL } == true } ||
            !nullableType("eventEpochMs") { OwnerLibraryHistoryPolicy.unsignedInteger(it)?.let { n -> n > 0 } == true }) return null
        val lastWatched = (row.opt("lastWatched") as? String)?.takeIf { it.isNotBlank() }
        if (lastWatched != null && runCatching { java.time.Instant.parse(lastWatched).toEpochMilli() > 0 }.getOrDefault(false).not()) return null
        val hasEvent = lastWatched != null || (!row.isNull("eventEpochMs") && row.has("eventEpochMs"))
        for (key in listOf("t", "d")) {
            val value = (row.opt(key) as? Number)?.toDouble()
            if (hasEvent && (value == null || !value.isFinite() || value < 0 || value * 1000 >= Long.MAX_VALUE.toDouble())) return null
        }
        fun wireSeconds(key: String): Long = (row.opt(key) as? Number)?.toDouble()
            ?.takeIf { it.isFinite() && it >= 0.0 }?.times(1000.0)?.toLong() ?: 0L
        return OwnerLibraryItem(
            metaId = id,
            type = type,
            name = (row.opt("name") as? String).orEmpty(),
            poster = (row.opt("poster") as? String)?.takeIf { it.isNotBlank() },
            videoId = (row.opt("v") as? String)?.takeIf { it.isNotBlank() },
            timeOffsetMs = wireSeconds("t"),
            durationMs = wireSeconds("d"),
            lastWatched = lastWatched,
            watched = row.opt("watched") as? String,
            currentVideoWatched = row.opt("currentVideoWatched") as? Boolean,
            timesWatched = OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("timesWatched"))?.takeIf { it <= 0xffff_ffffL },
            removed = row.opt("removed") as? Boolean ?: false,
            wholeTitleWatched = if (type == "movie") row.opt("wholeTitleWatched") as? Boolean else null,
            eventEpochMs = OwnerLibraryHistoryPolicy.unsignedInteger(row.opt("eventEpochMs"))?.takeIf { it > 0 },
        )
    }

    /** Reject synthetic IDs before they can reach the native account library. */
    internal fun isTypedCatalogIdentity(id: String): Boolean =
        (id.startsWith("tt") && id.length > 2 && id.drop(2).all(Char::isDigit)) ||
            (id.startsWith("tmdb:") && id.length > 5 && id.drop(5).all(Char::isDigit))

    /** Merge only a positive native snapshot; do not delete peer data because a local model is empty. */
    internal fun mergeLocalOwnerLibrary(
        vortx: JSONObject,
        local: List<OwnerLibraryItem>?,
        removed: Set<String>,
    ) {
        local ?: return
        vortx.put("library", OwnerLibraryHistoryPolicy.merge(vortx.optJSONArray("library"), local, removed))
    }

    /**
     * Account-owned add-ons are a stable app-first union of `vortx.addons` and website `doc.addons`.
     * URL-only legacy rows remain valid account records but are deliberately not returned here: native
     * InstallAddon needs a manifest, and an incomplete remote row must never turn into an empty install.
     */
    internal fun ownedAddons(doc: JSONObject, vortx: JSONObject? = doc.optJSONObject("vortx")): List<AddonDescriptor> {
        val byIdentity = LinkedHashMap<String, AddonDescriptor>()
        fun addAll(rows: JSONArray?) {
            rows ?: return
            for (index in 0 until rows.length()) {
                val raw = rows.optJSONObject(index) ?: continue
                val descriptor = addonDescriptor(raw) ?: continue
                val identity = AddonPublicationProofs.endpoint(descriptor.transportUrl)
                if (identity.isNotEmpty() && identity !in byIdentity) byIdentity[identity] = descriptor
            }
        }
        // App descriptors are canonical on conflict; website-only entries append in their document order.
        addAll(vortx?.optJSONArray("addons"))
        addAll(doc.optJSONArray("addons"))
        return byIdentity.values.toList()
    }

    /** Parse one safely-installable descriptor without rejecting compatible shallow records elsewhere in a doc. */
    internal fun addonDescriptor(raw: JSONObject): AddonDescriptor? {
        // Do not coerce arbitrary JSON values to strings: this object is dispatched directly to the native
        // engine during account hydration, so it has the same public-network admission as a pasted install.
        val url = (raw.opt("transportUrl") as? String)?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        if (
            uri.scheme?.lowercase() !in setOf("http", "https") ||
            uri.host.isNullOrBlank() || uri.rawUserInfo != null ||
            runCatching { PublicAddressPolicy.requireLiteralPublicOrHostname(uri.host) }.isFailure
        ) return null
        val manifest = raw.optJSONObject("manifest") ?: return null
        // Native's manifest serde needs real string values; `optString` would turn numbers/objects into
        // seemingly valid ids and feed malformed account material into InstallAddon.
        val id = manifest.opt("id") as? String ?: return null
        val name = manifest.opt("name") as? String ?: return null
        if (id.isBlank() || name.isBlank()) return null
        return AddonDescriptor(url, JSONObject(raw.toString()))
    }

    private fun parseAddonOrder(raw: JSONArray?): List<String>? {
        raw ?: return null
        val seen = HashSet<String>()
        val out = ArrayList<String>(minOf(raw.length(), MAX_ADDON_ORDER_ENTRIES))
        for (index in 0 until raw.length()) {
            if (out.size == MAX_ADDON_ORDER_ENTRIES) break
            val url = raw.opt(index) as? String ?: continue
            val normalized = AddonTombstones.normalize(url)
            if (normalized.isNotEmpty() && seen.add(normalized)) out += normalized
        }
        return out
    }

    /**
     * Read-merge local engine descriptors into the app-owned carrier. Never replaces a known-good remote
     * descriptor with an empty local snapshot; local descriptors win only for identities they actually hold.
     */
    internal fun mergeLocalAddons(
        vortx: JSONObject,
        local: List<AddonDescriptor>,
        removed: Set<String>,
    ): JSONObject {
        if (local.isEmpty()) return vortx
        val merged = mutableListOf<Any>()
        val positions = mutableMapOf<String, Int>()
        val prior = vortx.optJSONArray("addons")
        for (index in 0 until (prior?.length() ?: 0)) {
            val raw = prior!!.get(index)
            val descriptor = (raw as? JSONObject)?.let(::addonDescriptor)
            if (descriptor == null) { merged.add(raw); continue }
            val identity = AddonPublicationProofs.endpoint(descriptor.transportUrl)
            if (AddonTombstones.normalize(descriptor.transportUrl) in removed) continue
            if (identity !in positions) { positions[identity] = merged.size; merged.add(raw) }
        }
        for (descriptor in local) {
            val identity = AddonPublicationProofs.endpoint(descriptor.transportUrl)
            if (AddonTombstones.normalize(descriptor.transportUrl) !in removed && identity.isNotEmpty()) {
                val position = positions[identity]
                if (position == null) { positions[identity] = merged.size; merged.add(descriptor.raw) }
                else merged[position] = descriptor.raw
            }
        }
        if (merged.isNotEmpty()) {
            vortx.put("addons", JSONArray(merged))
            if (!vortx.has("addonsOwnedAt")) vortx.put("addonsOwnedAt", System.currentTimeMillis())
        }
        return vortx
    }

    private fun JSONArray?.orEmptyObjects(): List<JSONObject> {
        this ?: return emptyList()
        return buildList { for (index in 0 until length()) optJSONObject(index)?.let(::add) }
    }

    private const val MAX_ADDON_ORDER_ENTRIES = 1024

    private fun parseLibraryTimestamps(raw: JSONObject?): Map<String, Map<String, Double>> {
        raw ?: return emptyMap()
        return buildMap {
            for (id in raw.keys()) {
                val source = raw.optJSONObject(id) ?: continue
                val entry = buildMap {
                    finiteClock(source.opt("removedAt"))?.let { put("removedAt", it) }
                    finiteClock(source.opt("addedAt"))?.let { put("addedAt", it) }
                }
                if (entry.isNotEmpty()) put(id, entry)
            }
        }
    }

    /** Strict only for the add-on wire fields introduced in this sync lane. Other array readers keep their
     * established compatibility behavior, while malformed peer values here are simply ignored. */
    private fun parseAddonIds(raw: JSONArray?): List<String> {
        raw ?: return emptyList()
        return buildList {
            for (index in 0 until raw.length()) {
                (raw.opt(index) as? String)?.let(::add)
            }
        }
    }

    /** Accept only object-shaped per-URL stamp entries with finite numeric clocks. */
    private fun parseAddonTimestamps(raw: JSONObject?): Map<String, Map<String, Double>> {
        raw ?: return emptyMap()
        return buildMap {
            for (url in raw.keys()) {
                val source = raw.opt(url) as? JSONObject ?: continue
                val entry = buildMap {
                    finiteClock(source.opt("removedAt"))?.let { put("removedAt", it) }
                    finiteClock(source.opt("addedAt"))?.let { put("addedAt", it) }
                }
                if (entry.isNotEmpty()) put(url, entry)
            }
        }
    }

    private fun finiteClock(value: Any?): Double? =
        (value as? Number)?.toDouble()?.takeIf { it.isFinite() && it >= 0.0 }

    /** Publish the fractional clock without an integral conversion that would collapse same-second edits. */
    internal fun writeRosterModified(target: JSONObject, modifiedSeconds: Double) {
        require(modifiedSeconds.isFinite() && modifiedSeconds >= 0.0)
        target.put("rosterModified", modifiedSeconds)
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
    internal fun playbackFromSummary(p: JSONObject): PlaybackPrefs = PlaybackPrefs(
        audioLang = p.optString("audioLang", ""),
        subtitleLang = p.optString("subtitleLang", ""),
        forcedPolicy = p.optString("forced", ""),
        subFont = p.optString("subFont", ""),
        subSize = p.optString("subSize", ""),
        subColor = p.optString("subColor", ""),
        subBackground = p.optString("subBackground", ""),
        subSizeScale = if (p.has("subSizeScale")) p.optDouble("subSizeScale") else null,
        subBrightness = p.optStringOrNull("subBrightness"),
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
        // fractional epoch-SECONDS tiebreak a peer folds via mergeInRoster's `incomingModified`.
        v.put("updatedAt", System.currentTimeMillis())
        writeRosterModified(v, store.rosterModified)
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
    internal fun playbackSummary(pb: PlaybackPrefs): JSONObject = JSONObject().apply {
        put("audioLang", pb.audioLang)
        put("subtitleLang", pb.subtitleLang)
        put("forced", pb.forcedPolicy)
        put("subFont", pb.subFont)
        put("subSize", pb.subSize)
        put("subColor", pb.subColor)
        put("subBackground", pb.subBackground)
        pb.subSizeScale?.let { put("subSizeScale", it) }
        pb.subBrightness?.let { put("subBrightness", it) }
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
