package com.vortx.android.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Durable cross-device REMOVE tombstones for add-ons, the Android port of Apple `AddonTombstones`. The app
 * OWNS this set (it maps to `doc.vortx.deletedAddons`, the app's namespace) so an add-on the user removed on
 * one device is never resurrected by a peer device's UNION hydrate or a stale pre-removal cloud blob, nor by
 * the engine re-seeding OFFICIAL_ADDONS on a reset (#137).
 *
 * ANDROID SYNC: [VortXSyncManager] folds the app and web account fields into this store on every successful
 * pull, then publishes [all] plus [timestampsForSync] on its read-merge push without replacing foreign account
 * fields. The repository enforces the effective set at its installed-add-on read boundary: a Remove tombstones
 * the transport URL (protected stubs excepted), an explicit re-install forgets it, and engine-seeded add-ons are
 * re-uninstalled when they remain effectively removed.
 *
 * LAST-WRITER-WINS model. Each transportUrl carries two per-entry timestamps: `removedAt` (stamped by
 * [tombstone]) and `addedAt` (stamped by [forget]). A URL is EFFECTIVELY removed iff `removedAt > addedAt`.
 * Entries are never deleted and each stamp only ever moves forward (local writes and the merge fold both take
 * the per-id MAX), so the set stays a monotone, union-style structure; the only extra bit over a plain set is
 * the recency of the last install versus the last removal, which is what lets a genuine reinstall out-race a
 * stale removal.
 *
 * WIRE COMPATIBILITY. The legacy `stremiox.addons.deleted` array keeps its old shape (an array of URLs), now
 * computed as the EFFECTIVE removed set, so older builds keep reading it. The companion stamp maps
 * (`stremiox.addons.removedAt` / `stremiox.addons.addedAt`, url -> ms) carry the timestamps; clients that do
 * not know them ignore them. An incoming URL that appears only in the legacy array with NO stamp entry folds
 * at the migration epoch, so any real later reinstall out-races it.
 *
 * SAFETY: PROTECTED stubs (Cinemeta, Local Files: protected=true) must NEVER be tombstoned by a caller (a
 * logout resets the engine to exactly those, so tombstoning one would wrongly suppress an essential default
 * forever, and the UI has no Remove for them). A REMOVABLE official add-on (YouTube, WatchHub, ...:
 * official=true, protected=false) CAN be tombstoned: the engine re-seeds OFFICIAL_ADDONS on every reset, so
 * without a tombstone a user's deletion of one is resurrected on the next launch (#137). The state only ever
 * changes from EXPLICIT install/remove intent, never from an inferred diff.
 *
 * Uses Apple's EXACT UserDefaults keys so the same values ride the cross-device settings-backup blob.
 */
internal interface AddonTombstonePersistence {
    fun read(key: String): String?
    fun write(key: String, value: String?)
}

private class SharedPrefsTombstonePersistence(
    private val prefs: SharedPreferences,
) : AddonTombstonePersistence {
    override fun read(key: String): String? = prefs.getString(key, null)
    override fun write(key: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }
}

class AddonTombstones internal constructor(
    private val persistence: AddonTombstonePersistence,
    private val nowMs: () -> Double,
    private val accountScope: () -> String?,
) {
    internal constructor(
        persistence: AddonTombstonePersistence,
        nowMs: () -> Double = { System.currentTimeMillis().toDouble() },
    ) : this(persistence, nowMs, { activeAccountScope })

    constructor(context: Context) : this(
        SharedPrefsTombstonePersistence(
            context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE),
        ),
    )

    private data class State(
        val removedAt: MutableMap<String, Double>,
        val addedAt: MutableMap<String, Double>,
    )

    private fun currentScope(): String? = accountScope()?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }

    /** The current durable removal set (normalized transportUrls that are EFFECTIVELY removed). */
    fun all(): Set<String> = synchronized(PROCESS_LOCK) {
        currentScope()?.let { effectiveRemoved(load(it)) } ?: emptySet()
    }

    /**
     * The per-url timestamp map for the wire (`doc.vortx.deletedAddonsTs`). Carries BOTH stamps for every
     * tracked url, not just the effectively-removed ones, so a peer folding this learns a genuine reinstall's
     * `addedAt` and stops re-emitting a stale removal.
     */
    fun timestampsForSync(): Map<String, Map<String, Double>> = synchronized(PROCESS_LOCK) {
        val scope = currentScope() ?: return@synchronized emptyMap()
        val state = load(scope)
        val urls = state.removedAt.keys + state.addedAt.keys
        val out = LinkedHashMap<String, Map<String, Double>>(urls.size)
        for (url in urls) {
            val entry = LinkedHashMap<String, Double>(2)
            state.removedAt[url]?.let { entry["removedAt"] = it }
            state.addedAt[url]?.let { entry["addedAt"] = it }
            if (entry.isNotEmpty()) out[url] = entry
        }
        out
    }

    /**
     * Record an add-on removal so it sticks across devices. Callers MUST guard PROTECTED before calling.
     * Returns true when the url becomes NEWLY effectively-removed.
     */
    fun tombstone(transportUrl: String): Boolean = synchronized(PROCESS_LOCK) {
        val scope = currentScope() ?: return@synchronized false
        val key = normalize(transportUrl)
        if (key.isEmpty() || key.length > MAX_ID_LENGTH) return false
        val state = load(scope)
        val wasRemoved = isRemoved(key, state)
        state.removedAt[key] = maxOf(state.removedAt[key] ?: 0.0, nowMs())
        save(scope, state)
        !wasRemoved && isRemoved(key, state)
    }

    /**
     * Forget a removal tombstone so an EXPLICIT fresh install of the same add-on is honored instead of being
     * suppressed forever by an old removal. Returns true when the url flips from removed to present.
     */
    fun forget(transportUrl: String): Boolean = synchronized(PROCESS_LOCK) {
        val scope = currentScope() ?: return@synchronized false
        val key = normalize(transportUrl)
        if (key.isEmpty() || key.length > MAX_ID_LENGTH) return false
        val state = load(scope)
        val wasRemoved = isRemoved(key, state)
        state.addedAt[key] = maxOf(state.addedAt[key] ?: 0.0, nowMs())
        save(scope, state)
        wasRemoved && !isRemoved(key, state)
    }

    /**
     * Fold an incoming peer's add-on tombstones. [legacyIds] is the back-compat `doc.vortx.deletedAddons`
     * array (stamp-less effective removed set); [stamps] is the `doc.vortx.deletedAddonsTs` map. Both fold by
     * per-id MAX so the merge stays a monotone union-style fold. A legacy url with NO stamp entry folds at the
     * migration epoch, so any real later install out-races it. [webIds] is the stamp-less web-authored
     * `doc.webAddonRemovals`: a url is minted removedAt=now ONLY IF this device has never tracked it (no local
     * removedAt AND no local addedAt AND no published stamp), matching Apple's single-mint chokepoint. Returns
     * true when the EFFECTIVE removed set changed.
     */
    fun merge(
        legacyIds: List<String>,
        stamps: Map<String, Map<String, Double>>,
        webIds: List<String> = emptyList(),
    ): Boolean = synchronized(PROCESS_LOCK) {
        val scope = currentScope() ?: return@synchronized false
        val state = load(scope)
        val before = effectiveRemoved(state)
        val futureThresholdMs = nowMs() + 48.0 * 60.0 * 60.0 * 1000.0
        var maxFutureSeen = 0.0

        val stamped = HashSet<String>()
        for ((rawUrl, entry) in stamps) {
            val url = normalize(rawUrl)
            if (url.isEmpty() || url.length > MAX_ID_LENGTH) continue
            var applied = false
            entry["removedAt"]?.let { r ->
                if (r.isFinite()) {
                    if (r > futureThresholdMs) maxFutureSeen = maxOf(maxFutureSeen, r)
                    state.removedAt[url] = maxOf(state.removedAt[url] ?: 0.0, r)
                    applied = true
                }
            }
            entry["addedAt"]?.let { a ->
                if (a.isFinite()) {
                    if (a > futureThresholdMs) maxFutureSeen = maxOf(maxFutureSeen, a)
                    state.addedAt[url] = maxOf(state.addedAt[url] ?: 0.0, a)
                    applied = true
                }
            }
            if (applied) stamped.add(url)
        }
        for (rawUrl in legacyIds) {
            val url = normalize(rawUrl)
            if (url.isEmpty() || url.length > MAX_ID_LENGTH || url in stamped) continue
            state.removedAt[url] = maxOf(state.removedAt[url] ?: 0.0, MIGRATION_EPOCH_MS)
        }
        for (rawUrl in webIds) {
            val url = normalize(rawUrl)
            if (url.isEmpty() || url.length > MAX_ID_LENGTH || url in stamped) continue
            if (state.removedAt[url] != null || state.addedAt[url] != null) continue
            state.removedAt[url] = nowMs()
        }

        save(scope, state)
        if (maxFutureSeen > 0.0) {
            Log.d(TAG, "add-on tombstone fold saw a stamp ${maxFutureSeen.toLong()} beyond now+48h (peer clock skew)")
        }
        effectiveRemoved(load(scope)) != before
    }

    /**
     * One-shot baseline used on the first run of this build: stamp `addedAt = now` for a set of
     * currently-installed add-ons, so a stale pre-tombstone peer array cannot re-uninstall an add-on the user
     * demonstrably has. Skips any url whose folded removedAt is a real, post-epoch removal.
     */
    fun baselineInstalled(transportUrls: List<String>) = synchronized(PROCESS_LOCK) {
        val scope = currentScope() ?: return@synchronized
        if (transportUrls.isEmpty()) return
        val state = load(scope)
        val now = nowMs()
        for (raw in transportUrls) {
            val url = normalize(raw)
            if (url.isEmpty() || url.length > MAX_ID_LENGTH) continue
            val removed = state.removedAt[url]
            if (removed != null && removed > MIGRATION_EPOCH_MS) continue
            state.addedAt[url] = maxOf(state.addedAt[url] ?: 0.0, now)
        }
        save(scope, state)
    }

    // ---- State ----

    private fun isRemoved(url: String, state: State): Boolean =
        (state.removedAt[url] ?: 0.0) > (state.addedAt[url] ?: 0.0)

    private fun effectiveRemoved(state: State): Set<String> {
        val out = HashSet<String>(state.removedAt.size)
        for ((url, removed) in state.removedAt) {
            if (removed > (state.addedAt[url] ?: 0.0)) out.add(url)
        }
        return out
    }

    private fun load(scope: String): State {
        val removedAt = loadMap(scopedKey(REMOVED_AT_KEY, scope))
        val addedAt = loadMap(scopedKey(ADDED_AT_KEY, scope))
        // Fold the legacy plain removal array at the migration epoch on EVERY load. The max-fold is monotone
        // and idempotent, so no once-flag is needed (a flag has three holes: a kill between setting it and
        // doing the work loses the set, a downgrade reads a frozen array, and a downgrade-then-upgrade skips
        // re-migration). Mirrors Apple `load`.
        // Pre-scope values have no trustworthy owner. Deliberately quarantine them rather than assigning a
        // prior account's removals to whichever account signs in next.
        return State(removedAt, addedAt)
    }

    private fun save(scope: String, state: State) {
        val bounded = capped(state)
        persistence.write(scopedKey(REMOVED_AT_KEY, scope), encodeMap(bounded.removedAt))
        persistence.write(scopedKey(ADDED_AT_KEY, scope), encodeMap(bounded.addedAt))
        // Dual-write the effective removed set back to the legacy key so an older build still reads current
        // removals (it reads this array directly; load() re-folds it at the epoch on the next upgrade).
        persistence.write(scopedKey(LEGACY_DELETED_KEY, scope), JSONArray(effectiveRemoved(bounded).toList()).toString())
    }

    /**
     * Keep the most-recently-touched URLs (by the later of their two stamps) and drop the oldest. URLs are
     * evicted WHOLE (both stamps together), so a half-drop can never flip an installed add-on back to removed.
     */
    private fun capped(state: State): State {
        val urls = state.removedAt.keys + state.addedAt.keys
        if (urls.size <= MAX_ENTRIES) return state
        val keep = urls.sortedByDescending { url ->
            maxOf(state.removedAt[url] ?: 0.0, state.addedAt[url] ?: 0.0)
        }.take(MAX_ENTRIES).toSet()
        val removedAt = HashMap<String, Double>(keep.size)
        val addedAt = HashMap<String, Double>(keep.size)
        for (url in keep) {
            state.removedAt[url]?.let { removedAt[url] = it }
            state.addedAt[url]?.let { addedAt[url] = it }
        }
        return State(removedAt, addedAt)
    }

    private fun loadMap(key: String): MutableMap<String, Double> {
        val raw = persistence.read(key) ?: return HashMap()
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return HashMap()
        val out = HashMap<String, Double>(obj.length())
        val keys = obj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            val v = obj.optDouble(k, Double.NaN)
            if (v.isFinite()) out[k] = v
        }
        return out
    }

    private fun readArray(key: String): List<String>? {
        val raw = persistence.read(key) ?: return null
        val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return null
        return (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { s -> s.isNotEmpty() } }
    }

    private fun encodeMap(map: Map<String, Double>): String = JSONObject().apply {
        for ((url, value) in map) put(url, value)
    }.toString()

    companion object {
        /** Apple's EXACT UserDefaults keys, so the values ride the same cross-device settings-backup blob. */
        private const val REMOVED_AT_KEY = "stremiox.addons.removedAt"
        private const val ADDED_AT_KEY = "stremiox.addons.addedAt"
        private const val LEGACY_DELETED_KEY = "stremiox.addons.deleted"

        /** Shared with [com.vortx.android.sources.SeriesSourceSticky] / [SourcePreferencesStore]. */
        private const val PREFS_FILE = "vortx_settings"
        private const val TAG = "AddonTombstones"

        /** A migrated legacy removal folds in at this fixed low epoch, so any real later reinstall out-races it. */
        const val MIGRATION_EPOCH_MS: Double = 1.0

        private const val MAX_ENTRIES = 10_000
        private const val MAX_ID_LENGTH = 2048
        private val PROCESS_LOCK = Any()

        @Volatile private var activeAccountScope: String? = null

        /** Session ownership comes only from VortXSyncManager; signed-out callers see no persisted state. */
        fun activateAccount(accountId: String?) {
            activeAccountScope = accountId?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        }

        private fun scopedKey(key: String, scope: String): String = "$key.account.$scope"

        /** Trim + lowercase, applied on both the write and the match side, matching Apple `normalize`. */
        fun normalize(url: String): String = url.trim().lowercase()
    }
}
