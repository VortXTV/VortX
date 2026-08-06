package com.vortx.android.profile

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.MetaItem
import com.vortx.android.model.TrackPreferences
import com.vortx.android.sources.SourcePreferencesStore
import com.vortx.android.sources.SourceType
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray

/**
 * The profile roster and the active selection, the Android port of Apple `ProfileStore`
 * (`app/SourcesShared/Profiles.swift`). The roster persists as JSON in [SharedPreferences] (the direct
 * analogue of Apple's `UserDefaults`), under Apple's EXACT keys and living in the shared `vortx_settings`
 * file so it rides the same cross-device settings-backup blob as the other stores. Each own-account
 * profile keeps its Stremio token in its own slot; the pre-profiles primary slot serves every shared
 * profile.
 *
 * This is the LINCHPIN foundation the sync engine, realtime, and Trakt mirrors (next waves) build on,
 * and that per-profile watch / prefs / ranking key off. It ports the hard-won roster-merge guards
 * (union-never-shrink, owner-singleton, dup-Main / delete-resurrection) faithfully; see the WHY
 * comments; do NOT simplify them.
 *
 * SINGLETON: Apple has `ProfileStore.shared`; Android needs a `Context` for [SharedPreferences], so
 * [init] is called once from `VortXApplication.onCreate` (the same pattern `MediaServerRepository.init`
 * uses) and the rest of the app reads [shared] / [sharedOrNull].
 *
 * SEAMS (default no-op) the sync/auth/theme waves wire without touching this file: [onRosterPush]
 * (schedule a roster push), [onApplyTheme] (push appearance into the theme layer), [tokenProvider]
 * (resolve a per-profile token slot), plus the [WatchOverlayStore] push seams.
 *
 * RELOAD HOOKS: on every profile switch / sync fold, [notifySwitchListeners] fires the registered
 * listeners; `EngineStremioRepository` registers `{ SourcePreferences.reload(); SourcePin.reload() }`,
 * and `SourcePinStore` reads [activeProfileId] for its per-profile key, so per-profile source-ranking
 * isolation becomes real the moment a switch happens.
 */
class ProfileStore private constructor(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    private val overlay = WatchOverlayStore(prefs)

    // ---- Observable-ish state (plain fields; callers on the main thread, mirroring Apple's @Published) ----

    var profiles: List<UserProfile> = emptyList()
        private set
    var activeID: String? = null
        private set

    private val _activeProfile = MutableStateFlow<UserProfile?>(null)
    val activeProfile = _activeProfile.asStateFlow()

    /** The launch picker shows once per cold start, and only when there is a real choice to make. */
    var pickedThisLaunch: Boolean = false

    /**
     * Durable cross-device delete tombstones: profile ids the user has DELETED. The app owns this set so
     * a deleted profile can never be resurrected by a peer device's union-merge or a stale pre-delete
     * cloud blob. The owner id is never tombstoned.
     */
    var deletedProfileIDs: Set<String> = emptySet()
        private set

    // ---- Seams ----

    /** Schedule a cross-device roster push after a genuine edit. Wired by the sync wave. */
    var onRosterPush: (List<UserProfile>) -> Unit = {}

    /** Push a profile's appearance (accent, OLED, text scale) into the theme layer. Wired by the theme wave. */
    var onApplyTheme: (UserProfile) -> Unit = {}

    private fun publishActiveProfile() {
        _activeProfile.value = active
        _activeProfile.value?.let(onApplyTheme)
    }

    /** Resolve the token stored in a per-profile keychain/keystore slot. Wired by the auth wave. */
    var tokenProvider: (slot: String) -> String? = { null }

    /**
     * Rebuild the Home board after a per-profile prefs apply (Home is per-profile: it hides this
     * profile's disabled add-ons). Mirrors Apple `applyPlayback`'s trailing `CoreBridge.rebuildBoardRows`.
     * Default no-op; the engine/UI wave wires it.
     */
    var onRebuildBoard: () -> Unit = {}

    private val switchListeners = mutableListOf<() -> Unit>()

    // ---- Derived reads ----

    val active: UserProfile? get() = profiles.firstOrNull { it.id == activeID }
    val needsPicker: Boolean get() = profiles.size > 1 && !pickedThisLaunch

    /**
     * The active profile id string, in Apple's canonical uppercase form. `SourcePinStore` reads this for
     * its per-profile key; falls back to the owner id so a pre-roster read is still deterministic.
     */
    val activeProfileId: String get() = active?.id ?: UserProfile.OWNER_ID

    /** Whether the ACTIVE profile is a Kids profile. Read at ranking-snapshot build time so the ranker's
     *  Kids content guard (hard-hide adult/junk + Avoid words always DROP, never merely demote) engages,
     *  mirroring Apple `ProfileStore.activeIsKids()` feeding `StreamRanking.passesUserFilters`. */
    val activeIsKids: Boolean get() = active?.isKids == true

    /**
     * Whether the active profile reads/writes the engine (account) history (owner or own-account) or its
     * private overlay (every other shared profile). The split every watch path must respect. Mirrors
     * Apple `activeUsesEngineHistory`.
     */
    val activeUsesEngineHistory: Boolean get() = active?.usesEngineHistory ?: true

    /** The token slot the rest of the app reads the session from right now. Mirrors Apple `activeKeychainAccount`. */
    val activeKeychainAccount: String get() = active?.let { keychainAccount(it) } ?: PRIMARY_TOKEN_ACCOUNT

    /**
     * The token slot for [profile]. The owner IS the primary account (always the primary slot, whatever
     * `usesOwnAccount` says; a synced roster once flipped that flag on the owner and "signed out" every
     * device). Mirrors Apple `keychainAccount(for:)`.
     */
    fun keychainAccount(profile: UserProfile): String = keychainAccount(profile.isOwner, profile.usesOwnAccount, profile.id)

    private fun keychainAccount(isOwner: Boolean, usesOwnAccount: Boolean, id: String): String = when {
        isOwner -> PRIMARY_TOKEN_ACCOUNT
        usesOwnAccount -> "$PRIMARY_TOKEN_ACCOUNT.$id"
        else -> PRIMARY_TOKEN_ACCOUNT
    }

    // ---- Watch overlay passthrough (owner path is engine-backed and routed elsewhere) ----

    /** The active overlay profile's live watch map (empty for the owner). */
    val watch: Map<String, WatchEntry> get() = overlay.watch
    fun continueWatching(): List<MetaItem> = overlay.continueWatching()
    fun libraryItems(): List<MetaItem> = overlay.libraryItems()
    fun resumeOffset(metaId: String, videoId: String, type: String) = overlay.resumeOffset(metaId, videoId, type)
    fun watchedVideoIds(metaId: String) = overlay.watchedVideoIds(metaId)
    fun recordProgress(metaId: String, videoId: String, positionSeconds: Double, durationSeconds: Double, name: String, type: String, poster: String?) =
        overlay.recordProgress(metaId, videoId, positionSeconds, durationSeconds, name, type, poster)
    fun setWatched(isWatched: Boolean, metaId: String, videoIds: List<String>, name: String, type: String, poster: String?) =
        overlay.setWatched(isWatched, metaId, videoIds, name, type, poster)
    fun markWatched(metaId: String, videoId: String, name: String, type: String, poster: String?) =
        overlay.markWatched(metaId, videoId, name, type, poster)
    fun addLibraryEntry(metaId: String, name: String, type: String, poster: String?) =
        overlay.addLibraryEntry(metaId, name, type, poster)
    fun finishedWatching(metaId: String) = overlay.finishedWatching(metaId)
    fun removeWatchEntry(metaId: String) = overlay.removeWatchEntry(metaId)
    /** The stored overlay for ANY profile (for the sync wave to emit each profile's CW/library). */
    fun watchEntries(profileId: String) = overlay.entries(profileId)
    fun applyRemoteOverlay(profileId: String, incoming: Map<String, WatchEntry>) {
        val engineBacked = profiles.firstOrNull { it.id == UserProfile.normalizeId(profileId) }?.usesEngineHistory ?: false
        overlay.applyRemoteOverlay(profileId, incoming, engineBacked)
    }
    /** Expose the overlay's sync seams so the sync wave can wire cloud push. */
    val watchOverlay: WatchOverlayStore get() = overlay

    // ---- Reload-hook registration (the switch listeners the earlier waves left seams for) ----

    /** Register a listener fired on every profile switch / sync fold. Idempotent per distinct listener. */
    fun addSwitchListener(listener: () -> Unit) {
        if (!switchListeners.contains(listener)) switchListeners.add(listener)
    }

    private fun notifySwitchListeners() = switchListeners.forEach { it() }

    // ---- Lifecycle ----

    private fun bootstrap() {
        loadDeletedTombstones()
        load()
        if (profiles.isEmpty()) migrateFromSingleAccount()
        hashLegacyPins()
        // Rosters saved before history separation existed have no owner; the migrated first profile is
        // the account's main one.
        if (profiles.none { it.isOwner } && profiles.isNotEmpty()) {
            profiles = profiles.mapIndexed { i, p -> if (i == 0) p.copy(isOwner = true) else p }
            persist(touch = false)
        }
        val before = profiles
        normalizeOwner()
        if (activeID == null || profiles.none { it.id == activeID }) activeID = profiles.firstOrNull()?.id
        if (profiles != before) persist(touch = false)
        active?.let(::writeAddonKidsMirror)
        // One-time seed: pre-feature rosters share one flat set of playback preferences, so copying it into
        // every profile preserves today's behavior exactly; from then on each profile diverges.
        if (profiles.any { it.playback == null }) {
            val seed = currentPlaybackPrefs(null)
            profiles = profiles.map { if (it.playback == null) it.copy(playback = seed) else it }
            persist(touch = false)
        }
        overlay.activate(active?.id, activeUsesEngineHistory)
        publishActiveProfile()
    }

    // ---- Selection / CRUD ----

    /** Make [candidate] active: applies its prefs immediately and reports the account work left. Apple `select`. */
    fun select(candidate: UserProfile): SwitchOutcome {
        val profile =
            profiles.firstOrNull { it.id == candidate.id } ?: return SwitchOutcome.SameAccount
        // FIRST, before activeID moves: fold the live flat-key state into the OUTGOING profile, so a
        // viewer's Settings filter edits (which bind straight to the flat keys) are not overwritten by the
        // resetUnset apply below. The equality guard keeps this a no-op when the roster already matches.
        capturePlayback()
        val beforeAccount = active?.let { keychainAccount(it) }
        activeID = profile.id
        pickedThisLaunch = true
        persist(touch = false)   // selection is per-device, not a roster edit
        applyPlayback(profile, resetUnset = true)   // a switch resets unset filters to defaults, never inherits
        notifySwitchListeners()   // SourcePreferences.reload() + SourcePinStore.reload()
        overlay.activate(profile.id, profile.usesEngineHistory)
        publishActiveProfile()
        val nowAccount = keychainAccount(profile)
        if (nowAccount == beforeAccount) return SwitchOutcome.SameAccount
        val token = tokenProvider(nowAccount)
        return if (!token.isNullOrEmpty()) SwitchOutcome.SwitchAccount(token) else SwitchOutcome.NeedsSignIn
    }

    fun add(profile: UserProfile) {
        profiles = profiles + profile
        persist()
    }

    fun update(profile: UserProfile) {
        val idx = profiles.indexOfFirst { it.id == profile.id }
        if (idx < 0) return
        profiles = profiles.toMutableList().also { it[idx] = profile }
        persist()
        if (profile.id == activeID) {
            applyPlayback(profile)
            publishActiveProfile()
        }
    }

    /**
     * Flip an add-on on/off for the ACTIVE profile. A local per-profile overlay, NOT an account change.
     * Mirrors Apple `toggleAddon`.
     */
    fun toggleAddon(base: String) {
        val profile = active ?: return
        val set = (profile.disabledAddons ?: emptyList()).toMutableSet()
        if (set.contains(base)) set.remove(base) else set.add(base)
        update(profile.copy(disabledAddons = if (set.isEmpty()) null else set.sorted()))
    }

    fun isAddonDisabledForActive(base: String): Boolean = (active?.disabledAddons ?: emptyList()).contains(base)

    /** Remove a profile (never the last one). Mirrors Apple `remove`. */
    fun remove(profile: UserProfile): SwitchOutcome? {
        if (profiles.size <= 1 || profiles.none { it.id == profile.id }) return null
        profiles = profiles.filter { it.id != profile.id }
        overlay.clearCache(profile.id)
        tombstone(profile.id)   // durable cross-device delete; the union-merge can no longer resurrect it
        persist()
        return if (activeID == profile.id) profiles.firstOrNull()?.let { select(it) } else null
    }

    // ---- Per-profile playback preferences ----

    /**
     * The live flat-key filter values as a [PlaybackPrefs] snapshot. Filter fields are read LIVE from the
     * flat `SourcePreferences` keys (so a capture folds a Settings edit); track/subtitle fields are carried
     * from [base] (or device defaults) so a capture never wipes values a synced Apple roster set but that
     * Android does not yet apply. Mirrors the intent of Apple `currentPlaybackPrefs`.
     *
     * SCOPE NOTE: this wave manages ONLY the source-filter flat keys (unambiguous 1:1 mapping to
     * `SourcePreferencesStore`). Track-language + subtitle-style + theme application are deferred to when
     * their Android readers/vocab mapping land; the roster still CARRIES those fields so they round-trip
     * for cross-device sync.
     */
    private fun currentPlaybackPrefs(base: PlaybackPrefs?): PlaybackPrefs {
        val lang = TrackPreferences.deviceLanguages.firstOrNull() ?: "en"
        return PlaybackPrefs(
            audioLang = base?.audioLang ?: lang,
            subtitleLang = base?.subtitleLang ?: lang,
            forcedPolicy = base?.forcedPolicy ?: "forced",
            // Subtitle style: carry a synced value, else seed Apple's documented SubtitleStyle.default*
            // (modern / m / white / outline), NOT "": an empty string synced to Apple blanks its styling.
            subFont = base?.subFont ?: DEFAULT_SUB_FONT,
            subSize = base?.subSize ?: DEFAULT_SUB_SIZE,
            subColor = base?.subColor ?: DEFAULT_SUB_COLOR,
            subBackground = base?.subBackground ?: DEFAULT_SUB_BACKGROUND,
            subSizeScale = base?.subSizeScale,
            // Android does not apply the Apple brightness vocabulary yet, but it must carry the value
            // losslessly so a profile round-trip cannot erase an Apple-side preference.
            subBrightness = base?.subBrightness,
            // The FULL resolved order (never null), like Apple's SourcePreferences.typeOrder. A null here
            // would diff against the default order applyPlayback writes, spuriously re-pushing the roster.
            sourceTypeOrder = readFullOrder(),
            useAddonOrder = prefs.getBoolean(SourcePreferencesStore.ADDON_ORDER_KEY, false),
            safetyMode = prefs.getString(SourcePreferencesStore.SAFETY_KEY, "off"),
            instantOnly = prefs.getBoolean(SourcePreferencesStore.INSTANT_ONLY_KEY, false),
            hideDeadTorrents = prefs.getBoolean(SourcePreferencesStore.HIDE_DEAD_KEY, false),
            hdrOnly = prefs.getBoolean(SourcePreferencesStore.HDR_ONLY_KEY, false),
            excludeAV1 = prefs.getBoolean(SourcePreferencesStore.EXCLUDE_AV1_KEY, false),
            excludeKeywords = prefs.getString(SourcePreferencesStore.EXCLUDE_KEY, ""),
            includeKeywords = prefs.getString(SourcePreferencesStore.INCLUDE_KEY, ""),
            keywordsAreRegex = prefs.getBoolean(SourcePreferencesStore.REGEX_KEY, false),
            maxResolution = prefs.getInt(SourcePreferencesStore.MAX_RESOLUTION_KEY, 0),
            maxFileSizeGB = prefs.getFloat(SourcePreferencesStore.MAX_FILE_SIZE_KEY, 0f).toDouble(),
            minResolution = prefs.getInt(SourcePreferencesStore.MIN_RESOLUTION_KEY, 0),
            hideUnknownResolution = prefs.getBoolean(SourcePreferencesStore.HIDE_UNKNOWN_RES_KEY, false),
            preferredAudioOnly = prefs.getBoolean(SourcePreferencesStore.PREFERRED_AUDIO_KEY, false),
            preferKeywords = prefs.getString(SourcePreferencesStore.PREFER_KEY, ""),
            avoidBehavior = prefs.getString(SourcePreferencesStore.AVOID_BEHAVIOR_KEY, "hide"),
            autoPickBest = prefs.getBoolean(SourcePreferencesStore.AUTO_PICK_BEST_KEY, false),
        )
    }

    /** The full resolved source-type order (all 5 types, media servers fronted), mirroring
     *  `SourcePreferencesStore.readOrder` exactly so a capture never diverges from an apply. Never empty. */
    private fun readFullOrder(): List<String> {
        val saved = prefs.getString(SourcePreferencesStore.ORDER_KEY, "").orEmpty()
            .split(",").mapNotNull { SourceType.fromStorage(it.trim()) }.toMutableList()
        if (saved.isNotEmpty() && !saved.contains(SourceType.MEDIA_SERVER)) saved.add(0, SourceType.MEDIA_SERVER)
        for (t in SourceType.allCases) if (!saved.contains(t)) saved.add(t)
        return saved.map { it.storageValue }
    }

    /**
     * Write [profile]'s per-profile filter preferences into the flat `SourcePreferences` keys the ranker
     * reads, plus the disabled-add-on + Kids mirrors. Mirrors Apple `applyPlayback`: `resetUnset`
     * distinguishes a real SWITCH (an unset field is written back to its documented default, so the new
     * profile never INHERITS the last one's filters) from a background sync fold (an unset field is left
     * as-is, so a peer's null can never wipe live keys at pull time). Every value type MATCHES the
     * `SourcePreferencesStore` getter (Int/Float/Bool/String) so a later read never throws a class-cast.
     */
    private fun applyPlayback(profile: UserProfile, resetUnset: Boolean = false) {
        writeAddonKidsMirror(profile)
        val p = profile.playback
        val e = prefs.edit()
        val defaultOrder = SourceType.allCases.joinToString(",") { it.storageValue }

        if (p?.sourceTypeOrder != null) e.putString(SourcePreferencesStore.ORDER_KEY, p.sourceTypeOrder.joinToString(","))
        else if (resetUnset) e.putString(SourcePreferencesStore.ORDER_KEY, defaultOrder)
        applyBool(e, SourcePreferencesStore.ADDON_ORDER_KEY, p?.useAddonOrder, false, resetUnset)
        applyString(e, SourcePreferencesStore.SAFETY_KEY, p?.safetyMode, "off", resetUnset)
        applyBool(e, SourcePreferencesStore.INSTANT_ONLY_KEY, p?.instantOnly, false, resetUnset)
        applyBool(e, SourcePreferencesStore.HIDE_DEAD_KEY, p?.hideDeadTorrents, false, resetUnset)
        applyBool(e, SourcePreferencesStore.HDR_ONLY_KEY, p?.hdrOnly, false, resetUnset)
        applyBool(e, SourcePreferencesStore.EXCLUDE_AV1_KEY, p?.excludeAV1, false, resetUnset)
        applyString(e, SourcePreferencesStore.EXCLUDE_KEY, p?.excludeKeywords, "", resetUnset)
        applyString(e, SourcePreferencesStore.INCLUDE_KEY, p?.includeKeywords, "", resetUnset)
        applyBool(e, SourcePreferencesStore.REGEX_KEY, p?.keywordsAreRegex, false, resetUnset)
        applyInt(e, SourcePreferencesStore.MAX_RESOLUTION_KEY, p?.maxResolution, 0, resetUnset)
        applyFloat(e, SourcePreferencesStore.MAX_FILE_SIZE_KEY, p?.maxFileSizeGB, 0.0, resetUnset)
        applyInt(e, SourcePreferencesStore.MIN_RESOLUTION_KEY, p?.minResolution, 0, resetUnset)
        applyBool(e, SourcePreferencesStore.HIDE_UNKNOWN_RES_KEY, p?.hideUnknownResolution, false, resetUnset)
        applyBool(e, SourcePreferencesStore.PREFERRED_AUDIO_KEY, p?.preferredAudioOnly, false, resetUnset)
        applyString(e, SourcePreferencesStore.PREFER_KEY, p?.preferKeywords, "", resetUnset)
        applyString(e, SourcePreferencesStore.AVOID_BEHAVIOR_KEY, p?.avoidBehavior, "hide", resetUnset)
        applyBool(e, SourcePreferencesStore.AUTO_PICK_BEST_KEY, p?.autoPickBest, false, resetUnset)
        e.apply()
        // Every apply changes stream FILTERING / RANKING order, so drop the memoized scores and rebuild the
        // per-profile Home board. Mirrors the tail of Apple `applyPlayback`. This makes a per-profile
        // add-on toggle (via update -> applyPlayback) take effect immediately, not only on the next switch.
        // On a switch this double-invalidates with the reload hook, which is harmless.
        StreamRanking.invalidateCaches()
        onRebuildBoard()
    }

    private fun applyBool(e: SharedPreferences.Editor, key: String, v: Boolean?, def: Boolean, reset: Boolean) {
        if (v != null) e.putBoolean(key, v) else if (reset) e.putBoolean(key, def)
    }
    private fun applyString(e: SharedPreferences.Editor, key: String, v: String?, def: String, reset: Boolean) {
        if (v != null) e.putString(key, v) else if (reset) e.putString(key, def)
    }
    private fun applyInt(e: SharedPreferences.Editor, key: String, v: Int?, def: Int, reset: Boolean) {
        if (v != null) e.putInt(key, v) else if (reset) e.putInt(key, def)
    }
    private fun applyFloat(e: SharedPreferences.Editor, key: String, v: Double?, def: Double, reset: Boolean) {
        if (v != null) e.putFloat(key, v.toFloat()) else if (reset) e.putFloat(key, def.toFloat())
    }

    /** Flat mirrors of the active profile's disabled add-ons + Kids flag (Apple's off-main read keys). */
    private fun writeAddonKidsMirror(profile: UserProfile) {
        prefs.edit()
            .putString(ACTIVE_DISABLED_ADDONS_KEY, JSONArray(profile.disabledAddons ?: emptyList<String>()).toString())
            .putBoolean(ACTIVE_KIDS_KEY, profile.isKids)
            .apply()
    }

    /**
     * Fold the live flat filter keys back into the active profile so a Settings edit survives a switch and
     * follows the profile across devices. The equality guard stops [select]'s own flat-key writes from
     * echoing back as roster edits. Mirrors Apple `capturePlayback`.
     */
    fun capturePlayback() {
        val profile = active ?: return
        val now = currentPlaybackPrefs(profile.playback)
        if (samePlayback(profile.playback, now)) return
        update(profile.copy(playback = now))
    }

    /**
     * Playback equality that compares `maxFileSizeGB` at Float precision. That field persists as a Float
     * (`SourcePreferencesStore` uses `putFloat`), so an Apple-authored Double like 1.1 re-reads as
     * 1.100000023841858; a raw Double compare would treat that as a change and spuriously re-push the
     * roster (and drift the value). Every other field compares exactly via data-class equality.
     */
    private fun samePlayback(a: PlaybackPrefs?, b: PlaybackPrefs?): Boolean {
        if (a == null || b == null) return a == b
        return a.copy(maxFileSizeGB = null) == b.copy(maxFileSizeGB = null) &&
            a.maxFileSizeGB?.toFloat() == b.maxFileSizeGB?.toFloat()
    }

    // ---- Persistence ----

    private fun migrateFromSingleAccount() {
        val email = prefs.getString(EMAIL_KEY, null)
        // Mirror Apple's `.capitalized` on the local part for the common single-token case.
        val name = email?.substringBefore("@")?.lowercase()?.replaceFirstChar { it.uppercase() } ?: "Main"
        val first = UserProfile(
            id = UserProfile.OWNER_ID,
            name = name,
            avatar = "🍿",
            accentID = "vortx",
            email = email,
            isOwner = true,
        )
        profiles = listOf(first)
        activeID = first.id
        persist(touch = false)   // migration isn't an edit; don't race a remote roster pull
    }

    private fun load() {
        prefs.getString(LIST_KEY, null)?.let { UserProfile.decodeRoster(it) }?.let { profiles = it }
        activeID = prefs.getString(ACTIVE_KEY, null)?.let { UserProfile.normalizeId(it) }
    }

    /** One-time: rosters from before PIN hashing carry raw digits; replace them with salted hashes. Apple `hashLegacyPins`. */
    private fun hashLegacyPins() {
        var changed = false
        profiles = profiles.map { p ->
            val raw = p.pin
            if (!raw.isNullOrEmpty() && !raw.startsWith("sha256:")) {
                changed = true
                p.copy(pin = UserProfile.pinHash(raw, p.id))
            } else p
        }
        if (changed) persist(touch = false)
    }

    /**
     * [touch] marks a real roster edit (add/update/remove): it bumps the local modification time and
     * schedules a push. `touch = false` is routine housekeeping (migration, per-device selection, merges,
     * tombstone prune): write only, never push. Android has no global UserDefaults observer arming an
     * auto-push, so a plain write with no [onRosterPush] IS the suppression Apple routes through
     * `suppressHousekeeping`.
     */
    private fun persist(touch: Boolean = true) {
        prefs.edit()
            .putString(LIST_KEY, UserProfile.encodeRoster(profiles))
            .putString(ACTIVE_KEY, activeID)
            .apply()
        if (touch) {
            // Fractional epoch SECONDS, matching Apple's `Date().timeIntervalSince1970` Double. Integer
            // seconds collapsed every edit within the same second into a tie and truncated Apple clocks.
            writeRosterClock(
                nextLocalRosterClock(
                    nowSeconds = System.currentTimeMillis() / 1000.0,
                    priorModified = rosterModified,
                ),
            )
            onRosterPush(profiles)
        }
    }

    /**
     * Local fractional epoch-SECONDS stamp of the last real roster edit. SharedPreferences has no Double
     * primitive, so the exact IEEE-754 bits live in a private sync-bookkeeping Long. The canonical Apple
     * key remains a whole-second Long for safe rollback to older Android builds; a missing exact key is
     * migrated from that legacy value on first read.
     */
    val rosterModified: Double
        get() {
            val exactBits = if (prefs.contains(MODIFIED_BITS_KEY)) {
                runCatching { prefs.getLong(MODIFIED_BITS_KEY, 0L) }.getOrNull()
            } else {
                null
            }
            val legacySeconds = legacyRosterClock()
            val resolved = decodeStoredRosterClock(exactBits, legacySeconds) ?: return 0.0
            // An older app updates only the canonical Long and leaves our exact-bits key behind. Heal both
            // representations from the newest valid value so returning to this build cannot revive that stale key.
            if (exactBits != resolved.toRawBits() || legacySeconds != resolved.toLong()) {
                writeRosterClock(resolved)
            }
            return resolved
        }

    private fun legacyRosterClock(): Long? =
        if (prefs.contains(MODIFIED_KEY)) runCatching { prefs.getLong(MODIFIED_KEY, 0L) }.getOrNull() else null

    private fun writeRosterClock(seconds: Double) {
        if (!seconds.isFinite() || seconds < 0.0) return
        prefs.edit()
            .putLong(MODIFIED_BITS_KEY, seconds.toRawBits())
            .putLong(MODIFIED_KEY, seconds.toLong())
            .apply()
    }

    /**
     * Adopt a pulled roster's monotone high-water mark even when its fields already equal local state.
     * Without this write, a later unrelated push republishes an older clock through both carriers and a
     * stale peer can win the next same-id fold. This is housekeeping, so it never schedules a push.
     */
    private fun adoptRosterWatermark(next: Double) {
        if (next > rosterModified) writeRosterClock(next)
    }

    // ---- Delete tombstones ----

    private fun loadDeletedTombstones() {
        deletedProfileIDs = prefs.getString(DELETED_KEY, null)?.let { raw ->
            runCatching {
                val a = JSONArray(raw)
                (0 until a.length()).map { a.getString(it) }.toSet()
            }.getOrNull()
        } ?: emptySet()
    }

    private fun saveDeletedTombstones() {
        prefs.edit().putString(DELETED_KEY, JSONArray(deletedProfileIDs.toList()).toString()).apply()
    }

    /** Record a profile deletion so it sticks across devices. NEVER the owner. Idempotent. Apple `tombstone`. */
    private fun tombstone(id: String) {
        val key = UserProfile.normalizeId(id)
        if (key == UserProfile.OWNER_ID || deletedProfileIDs.contains(key)) return
        deletedProfileIDs = deletedProfileIDs + key
        saveDeletedTombstones()
    }

    /** Fold incoming tombstones into the local set (dropping the owner defensively). Apple `mergeDeletedTombstones`. */
    fun mergeDeletedTombstones(incoming: List<String>): Boolean {
        val add = incoming.map { UserProfile.normalizeId(it) }
            .filter { it != UserProfile.OWNER_ID && !deletedProfileIDs.contains(it) }
        if (add.isEmpty()) return false
        deletedProfileIDs = deletedProfileIDs + add
        saveDeletedTombstones()
        pruneTombstonedProfiles()
        return true
    }

    /** Remove any live profile whose id is tombstoned (never the owner). Apple `pruneTombstonedProfiles`. */
    private fun pruneTombstonedProfiles() {
        val before = profiles
        profiles = profiles.filterNot { deletedProfileIDs.contains(it.id) && !it.isOwner }
        if (profiles == before) return
        if (activeID == null || profiles.none { it.id == activeID }) activeID = profiles.firstOrNull()?.id
        active?.let { applyPlayback(it) }
        persist(touch = false)
        overlay.activate(active?.id, activeUsesEngineHistory)
        publishActiveProfile()
    }

    /** Apply the LOCAL delete tombstones to the live roster (called after EVERY sync pull). Apple `applyLocalTombstones`. */
    fun applyLocalTombstones() = pruneTombstonedProfiles()

    // ---- Roster sync folds ----

    /** Adopt a remote roster wholesale (newest side wins). Mirrors Apple `adoptRemoteRoster`. */
    fun adoptRemoteRoster(remote: List<UserProfile>) {
        profiles = remote
        afterRosterFold()
    }

    /**
     * Re-read the roster from the restored defaults (after a settings-backup restore), KEEPING this
     * device's active selection (selection is per-device). Mirrors Apple `reloadFromDefaults`.
     */
    fun reloadFromDefaults() {
        val list = prefs.getString(LIST_KEY, null)?.let { UserProfile.decodeRoster(it) } ?: return
        val keep = activeID
        profiles = list
        normalizeOwner()
        activeID = when {
            keep != null && profiles.any { it.id == keep } -> keep
            profiles.none { it.id == activeID } -> profiles.firstOrNull()?.id
            else -> activeID
        }
        active?.let { applyPlayback(it); notifySwitchListeners() }
        persist(touch = false)
        overlay.activate(active?.id, activeUsesEngineHistory)
        publishActiveProfile()
    }

    /**
     * UNION the live roster with [incoming] by profile id, the core cross-device safety guarantee: a
     * profile present on only ONE side is ALWAYS kept, so a cloud blob carrying fewer profiles can never
     * delete a richer local roster, and vice versa. For an id on BOTH sides, the newer roster (by
     * [incomingModified] vs [rosterModified], both epoch-SECONDS) wins the fields; either way the id is retained. Delete
     * tombstones are subtracted from the union. Mirrors Apple `mergeInRoster`.
     */
    fun mergeInRoster(incoming: List<UserProfile>, incomingModified: Double? = null) {
        if (incoming.isEmpty()) return
        val transition = rosterPullMergeTransition(
            local = profiles,
            incoming = incoming,
            deletedProfileIDs = deletedProfileIDs,
            localModified = rosterModified,
            incomingModified = incomingModified,
        )
        applyRosterPullMergeTransition(
            transition = transition,
            replaceProfiles = { merged ->
                profiles = merged
                afterRosterFold()
            },
            // The carrier watermark is state too. Persist it even when the roster payload is identical.
            adoptWatermark = ::adoptRosterWatermark,
            schedulePush = { onRosterPush(profiles) },
        )
    }

    /** Whether [incoming] is a genuinely different roster (by the SET of ids). Mirrors Apple `rosterDiffers`. */
    fun rosterDiffers(incoming: List<UserProfile>): Boolean =
        profiles.map { it.id }.toSet() != incoming.map { it.id }.toSet()

    /** Shared tail for a wholesale/union fold: heal the owner, keep the active selection if it survived
     *  (else fall to the first), re-apply the active profile's prefs + fire the reload hooks, persist
     *  without pushing, and re-point the watch overlay. */
    private fun afterRosterFold() {
        normalizeOwner()
        if (profiles.none { it.id == activeID }) activeID = profiles.firstOrNull()?.id
        active?.let { applyPlayback(it); notifySwitchListeners() }
        persist(touch = false)
        overlay.activate(active?.id, activeUsesEngineHistory)
        publishActiveProfile()
    }

    // ---- Owner normalization + duplicate collapse (the hard-won guards) ----

    /**
     * The owner profile can never be an own-account profile; scrub the flag. Then enforce the owner
     * SINGLETON: one account, one owner, with a STABLE id. A restore/merge can leave more than one (the
     * account owner adopted alongside a leftover local placeholder minted with a random id, the
     * duplicate-"Main" bug). Collapse to ONE direction-independently: keep the genuine account owner
     * (identified by its account email), DROP the duplicates (an owner reads the account history and
     * carries no private overlay, so a clone has nothing unique to lose). Then re-key the survivor onto
     * the stable owner id so every device converges. Mirrors Apple `normalizeOwner`.
     */
    private fun normalizeOwner() {
        val list = profiles.map { if (it.isOwner) it.copy(usesOwnAccount = false) else it }.toMutableList()
        val ownerIdx = list.indices.filter { list[it].isOwner }
        val firstOwner = ownerIdx.firstOrNull()
        if (firstOwner == null) { profiles = list; return }

        val signedInEmail = prefs.getString(EMAIL_KEY, null)
        val keepIdx = ownerIdx.firstOrNull { !signedInEmail.isNullOrEmpty() && list[it].email == signedInEmail }
            ?: ownerIdx.firstOrNull { !(list[it].email ?: "").isEmpty() }
            ?: ownerIdx.firstOrNull { list[it].id == activeID }
            ?: firstOwner
        val keepID = list[keepIdx].id

        if (ownerIdx.size > 1) {
            val dropIDs = ownerIdx.filter { list[it].id != keepID }.map { list[it].id }.toSet()
            list.removeAll { it.isOwner && dropIDs.contains(it.id) }
            if (activeID != null && dropIDs.contains(activeID)) activeID = keepID
        }

        // Re-key the surviving owner onto the stable id (skip if it carries a PIN because its hash is salted with
        // the current id, so re-keying would silently break the PIN, or if some other profile already
        // holds the stable id).
        val survivor = list.indexOfFirst { it.isOwner }
        if (survivor >= 0) {
            val o = list[survivor]
            if (o.id != UserProfile.OWNER_ID && !o.hasPin &&
                list.none { it.id == UserProfile.OWNER_ID && !it.isOwner }
            ) {
                val old = o.id
                list[survivor] = o.copy(id = UserProfile.OWNER_ID)
                if (activeID == old) activeID = UserProfile.OWNER_ID
            }
        }
        profiles = list
        collapseEmptyDuplicateSecondaries()
    }

    /**
     * Collapse ACCIDENTAL duplicate secondaries: when two or more non-owner profiles share the same name
     * (trimmed, case-insensitive), an EMPTY one (no watch overlay) is almost always a cross-device sync
     * artifact, the same person's profile re-created with a fresh id on another device, so the union
     * keeps both and the user sees a second "Daksh" a delete cannot clear. Drop AND tombstone the empty
     * duplicate. A profile that carries its OWN watch history is NEVER auto-removed. Mirrors Apple
     * `collapseEmptyDuplicateSecondaries`.
     */
    private fun collapseEmptyDuplicateSecondaries() {
        val secondaries = profiles.filter { !it.isOwner }
        if (secondaries.size <= 1) return
        fun nameKey(p: UserProfile) = p.name.trim().lowercase()
        fun hasHistory(id: String) = overlay.entries(id).isNotEmpty()

        val ordered = secondaries.sortedWith(
            compareByDescending<UserProfile> { hasHistory(it.id) }.thenBy { it.id },
        )
        val keptNames = HashSet<String>()
        val dropIDs = HashSet<String>()
        for (p in ordered) {
            val k = nameKey(p)
            if (k.isEmpty()) continue
            if (keptNames.contains(k)) {
                if (!hasHistory(p.id)) dropIDs.add(p.id)   // empty same-name dup: safe to remove
            } else {
                keptNames.add(k)
            }
        }
        if (dropIDs.isEmpty()) return
        dropIDs.forEach { tombstone(it) }   // durable: never resurrects via the union-merge
        profiles = profiles.filterNot { dropIDs.contains(it.id) }
        if (activeID != null && dropIDs.contains(activeID)) activeID = profiles.firstOrNull()?.id
    }

    /** What the account layer must do after a switch. Mirrors Apple `SwitchOutcome`. */
    sealed interface SwitchOutcome {
        data object SameAccount : SwitchOutcome
        data class SwitchAccount(val token: String) : SwitchOutcome
        data object NeedsSignIn : SwitchOutcome
    }

    companion object {
        const val PREFS_FILE = "vortx_settings"

        // Apple's EXACT keys.
        private const val LIST_KEY = "stremiox.profiles"
        private const val ACTIVE_KEY = "stremiox.profiles.active"
        private const val MODIFIED_KEY = "stremiox.profiles.modified"
        private const val MODIFIED_BITS_KEY = "vortx.sync.profiles.modified.doubleBits"
        private const val DELETED_KEY = "stremiox.profiles.deleted"
        private const val EMAIL_KEY = "stremiox.email"
        const val ACTIVE_DISABLED_ADDONS_KEY = "stremiox.profile.disabledAddons"
        const val ACTIVE_KIDS_KEY = "stremiox.profile.isKids"

        /** The pre-profiles single-account token slot; shared profiles keep using it. Apple `primaryTokenAccount`. */
        const val PRIMARY_TOKEN_ACCOUNT = "stremiox.authKey"

        // Apple `SubtitleStyle.default*` (app/Sources/Player/SubtitleStyle.swift), so a fresh profile seeds
        // real style values instead of "" (which would blank Apple's subtitles when synced across).
        private const val DEFAULT_SUB_FONT = "modern"
        private const val DEFAULT_SUB_SIZE = "m"
        private const val DEFAULT_SUB_COLOR = "white"
        private const val DEFAULT_SUB_BACKGROUND = "outline"

        @Volatile
        private var instance: ProfileStore? = null

        /** Initialize once (from `VortXApplication.onCreate`); idempotent. Returns the shared instance. */
        fun init(context: Context): ProfileStore =
            instance ?: synchronized(this) {
                instance ?: ProfileStore(context).also { it.bootstrap(); instance = it }
            }

        /** The shared instance; throws if [init] was never called. */
        val shared: ProfileStore get() = instance ?: error("ProfileStore.init(context) not called")

        /** The shared instance, or null before [init] (safe for early-boot wiring lambdas). */
        fun sharedOrNull(): ProfileStore? = instance
    }
}

/** Pure clock fold shared by field selection and the persisted high-water mark. */
internal data class RosterClockDecision(
    val preferIncoming: Boolean,
    val effectiveModified: Double,
)

internal fun rosterClockDecision(localModified: Double, incomingModified: Double?): RosterClockDecision {
    val local = localModified.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0
    val incoming = incomingModified?.takeIf { it.isFinite() && it >= 0.0 }
    return RosterClockDecision(
        preferIncoming = incoming != null && incoming > local,
        effectiveModified = incoming?.let { maxOf(local, it) } ?: local,
    )
}

/** Exact SharedPreferences representation with a legacy whole-second migration path. */
internal fun decodeStoredRosterClock(exactBits: Long?, legacySeconds: Long?): Double? {
    val exact = exactBits?.let(Double::fromBits)?.takeIf { it.isFinite() && it >= 0.0 }
    val legacy = legacySeconds?.toDouble()?.takeIf { it >= 0.0 }
    return when {
        exact == null -> legacy
        legacy == null -> exact
        else -> maxOf(exact, legacy)
    }
}

/**
 * A local edit is a Lamport-style advance over both wall time and the persisted roster watermark. This
 * keeps it newer than a future peer clock, survives a wall-clock rollback, and prevents same-millisecond ties.
 */
internal fun nextLocalRosterClock(nowSeconds: Double, priorModified: Double): Double {
    val prior = priorModified.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0
    val now = nowSeconds.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0
    val successor = Math.nextUp(prior)
    return if (successor.isFinite()) maxOf(now, successor) else prior
}

/**
 * Pure production seam for a pulled roster fold. A pull can persist content and/or adopt a newer
 * watermark, but never requests a push; this prevents an equal payload clock adoption from echoing.
 */
internal data class RosterPullMergeTransition(
    val profiles: List<UserProfile>,
    val effectiveModified: Double,
    val contentChanged: Boolean,
    val pushRequired: Boolean,
)

internal fun rosterPullMergeTransition(
    local: List<UserProfile>,
    incoming: List<UserProfile>,
    deletedProfileIDs: Set<String>,
    localModified: Double,
    incomingModified: Double?,
): RosterPullMergeTransition {
    val clock = rosterClockDecision(localModified, incomingModified)
    val incomingByID = incoming.associateBy { it.id }
    val localByID = local.associateBy { it.id }
    val merged = local.map { existing ->
        val remote = incomingByID[existing.id] ?: return@map existing
        // A freshly reinstalled placeholder owner may adopt the hydrated cloud owner even if its local
        // clock is newer. The exact signature keeps this from overriding a real rename.
        if (existing.id == UserProfile.OWNER_ID && existing.name == "Main" &&
            (existing.email ?: "").isEmpty() &&
            (remote.name != "Main" || !(remote.email ?: "").isEmpty())
        ) {
            remote
        } else if (clock.preferIncoming) {
            remote
        } else {
            existing
        }
    }.toMutableList()
    for (remote in incoming) if (!localByID.containsKey(remote.id)) merged.add(remote)
    merged.removeAll { deletedProfileIDs.contains(it.id) && !it.isOwner }
    return RosterPullMergeTransition(
        profiles = merged,
        effectiveModified = clock.effectiveModified,
        contentChanged = merged != local,
        pushRequired = false,
    )
}

/** Execute the pure transition through the same callbacks production uses, allowing behavioral JVM tests. */
internal fun applyRosterPullMergeTransition(
    transition: RosterPullMergeTransition,
    replaceProfiles: (List<UserProfile>) -> Unit,
    adoptWatermark: (Double) -> Unit,
    schedulePush: () -> Unit,
) {
    if (transition.contentChanged) replaceProfiles(transition.profiles)
    adoptWatermark(transition.effectiveModified)
    if (transition.pushRequired) schedulePush()
}
