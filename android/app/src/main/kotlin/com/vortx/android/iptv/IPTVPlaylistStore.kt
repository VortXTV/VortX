package com.vortx.android.iptv

import android.content.Context
import com.vortx.android.integrations.SecureTokenStore
import org.json.JSONArray
import org.json.JSONObject

/// Local record of the IPTV playlists the user has added (M3U URLs and Xtream Codes logins), each converted
/// by the hosted `iptv.vortx.tv` worker into a first-party add-on that flows through VortX's existing catalog
/// pipeline. Kotlin port of the Apple `app/SourcesShared/IPTVPlaylistStore.swift`, keeping the same storage
/// split, the same removal-tombstone map, and the same account sync blob shape so the two platforms converge.
///
/// STORAGE (the Apple UserDefaults / Keychain split, and the exact split
/// [com.vortx.android.mediaserver.MediaServerRepository] uses on Android): the non-secret record metadata
/// (display name, kind, worker slug, installed transport URL, createdAt) lives in plain SharedPreferences;
/// the credential-bearing bits (Xtream host / user / pass, and any credential-carrying M3U or XMLTV URL) live
/// in the encrypted [SecureTokenStore] under `vortx.iptv.cred.<slug>`, so they never enter a settings backup
/// and never leave the device except to the worker over the signed edge.
///
/// TESTABILITY: all merge / tombstone / round-trip logic sits on the [IPTVPersistence] seam so it is
/// unit-testable with an in-memory fake (the Android module has no Robolectric harness). Production binds
/// [SharedPreferencesIPTVPersistence]; the process-wide instance is [IPTVPlaylists].
class IPTVPlaylistStore(private val persistence: IPTVPersistence) {

    /// The installed playlists, newest first, held in memory and re-persisted whole on every mutation (the
    /// same whole-array rewrite Apple's `persistList()` does).
    private var loaded: List<IPTVPlaylist> = load()

    /// The installed playlists, newest first. A snapshot for the settings screen.
    fun playlists(): List<IPTVPlaylist> = loaded

    /// Re-read the persisted playlists (the Apple `reloadFromDefaults`). A read must never write, so this does
    /// not persist and does not nudge sync; it exists so a future account-settings pull or backup restore that
    /// writes the underlying store directly is picked up instead of being flushed over by a stale in-memory
    /// array.
    fun reload() {
        loaded = load()
    }

    // MARK: Mutations

    /// Record a freshly-registered playlist: stash its credentials in the encrypted store and prepend its
    /// metadata. Idempotent by slug (a re-add of the same slug replaces the existing entry). Mirrors Apple
    /// `add(_:credentials:)`.
    fun add(playlist: IPTVPlaylist, credentials: IPTVCredentials) {
        persistence.writeCredential(playlist.id, encodeCredentials(credentials))
        clearRemovedTombstone(playlist.id)
        loaded = listOf(playlist) + loaded.filter { it.id != playlist.id }
        persistList()
    }

    /// Forget a playlist locally: drop its credentials and its metadata, stamp a removal tombstone. The caller
    /// is responsible for uninstalling the add-on and calling the worker's revoke first. Mirrors Apple
    /// `remove(slug:)`.
    fun remove(slug: String) {
        persistence.writeCredential(slug, null)
        loaded = loaded.filter { it.id != slug }
        stampRemovedTombstone(slug)
        persistList()
    }

    /// The stored credentials for a slug, or null when absent. Mirrors Apple `credentials(for:)`.
    fun credentials(slug: String): IPTVCredentials? =
        persistence.readCredential(slug)?.let(::decodeCredentials)

    /// True when a playlist with this transport URL is already recorded (so the UI can avoid duplicates).
    /// Mirrors Apple `contains(transportUrl:)`.
    fun contains(transportUrl: String): Boolean = loaded.any { it.transportUrl == transportUrl }

    // MARK: Sync blob (the account-encrypted channel)

    /// The JSON string mirrored on the account channel under `vortx.iptv`, or null when there is nothing to
    /// sync (no playlists AND no tombstones). The credentials ride the doc as an opaque `cred` string, exactly
    /// as the Apple store carries them, so a reinstalled device's restored playlists can live again. Mirrors
    /// the Apple `syncBlob()`. Wired to the sync lane in a later wave; the shape is fixed now so both
    /// platforms converge.
    fun syncBlob(): String? {
        val removed = loadRemoved()
        if (loaded.isEmpty() && removed.isEmpty()) return null
        val playlistsJson = JSONArray()
        for (p in loaded) {
            val obj = JSONObject()
                .put("id", p.id)
                .put("name", p.name)
                .put("kind", p.kind.wire)
                .put("transportUrl", p.transportUrl)
                .put("createdAt", p.createdAtMillis)
            // The credential JSON rides as an opaque string, so a future field added to IPTVCredentials rides
            // along without a blob-schema change and an older client passes it through untouched.
            persistence.readCredential(p.id)?.takeIf { it.isNotEmpty() }?.let { obj.put("cred", it) }
            playlistsJson.put(obj)
        }
        val removedJson = JSONObject()
        for ((slug, stamp) in removed) removedJson.put(slug, stamp)
        return JSONObject()
            .put("v", 1)
            .put("playlists", playlistsJson)
            .put("removed", removedJson)
            .toString()
    }

    /// Apply a pulled sync blob: union-merge playlists by slug, honor removal tombstones (a `removed` stamp
    /// newer than a playlist's `createdAt` deletes it locally), and adopt a synced credential into the
    /// encrypted store ONLY when the local slot is empty (the encrypted store stays the source of truth).
    /// NEVER deletes a locally-added playlist the remote simply lacks (the same asymmetric read-merge as the
    /// debrid / media-server guards). Persists inline WITHOUT nudging sync. Mirrors the Apple `applySyncBlob`.
    fun applySyncBlob(json: String) {
        val root = runCatching { JSONObject(json) }.getOrNull() ?: return
        val remote = root.optJSONArray("playlists") ?: JSONArray()
        val remoteRemoved = root.optJSONObject("removed") ?: JSONObject()

        // Merge remote removal tombstones into the local map (keep the newest stamp per slug).
        val localRemoved = loadRemoved().toMutableMap()
        for (slug in remoteRemoved.keys()) {
            val stamp = remoteRemoved.optDouble(slug, 0.0)
            if (stamp > (localRemoved[slug] ?: 0.0)) localRemoved[slug] = stamp
        }

        val bySlug = LinkedHashMap<String, IPTVPlaylist>()
        for (p in loaded) bySlug[p.id] = p
        var changed = false

        for (i in 0 until remote.length()) {
            val obj = remote.optJSONObject(i) ?: continue
            val slug = obj.optString("id").takeIf { it.isNotEmpty() } ?: continue
            val name = obj.optString("name").takeIf { it.isNotEmpty() } ?: continue
            val kind = IPTVKind.fromWire(obj.optString("kind")) ?: continue
            val transportUrl = obj.optString("transportUrl").takeIf { it.isNotEmpty() } ?: continue
            val createdAt = obj.optLong("createdAt", System.currentTimeMillis())

            // A removal newer than this playlist's add wins: drop it and do not resurrect.
            val tombstone = localRemoved[slug]
            if (tombstone != null && tombstone > createdAt.toDouble()) {
                if (bySlug.remove(slug) != null) {
                    persistence.writeCredential(slug, null)
                    changed = true
                }
                continue
            }
            // Credentials: adopt into the encrypted store only when the local slot is empty (store
            // authoritative). This is the leg that makes a reinstalled device's restored playlists live again.
            if (persistence.readCredential(slug) == null) {
                obj.optString("cred").takeIf { it.isNotEmpty() }?.let { persistence.writeCredential(slug, it) }
            }
            val record = IPTVPlaylist(id = slug, name = name, kind = kind, transportUrl = transportUrl, createdAtMillis = createdAt)
            if (bySlug[slug] != record) {
                bySlug[slug] = record
                changed = true
            }
        }

        // Persist the merged tombstones regardless (a pure tombstone pull still needs to stick).
        writeRemoved(localRemoved)
        if (!changed) return
        loaded = bySlug.values.sortedByDescending { it.createdAtMillis } // newest-first, mirroring add()
        persistList()
    }

    // MARK: Persistence (metadata)

    private fun load(): List<IPTVPlaylist> {
        val raw = persistence.readPlaylistsJson() ?: return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        return (0 until array.length()).mapNotNull { array.optJSONObject(it)?.let(::parsePlaylist) }
    }

    private fun parsePlaylist(obj: JSONObject): IPTVPlaylist? {
        val id = obj.optString("id").takeIf { it.isNotEmpty() } ?: return null
        val kind = IPTVKind.fromWire(obj.optString("kind")) ?: return null
        val transportUrl = obj.optString("transportUrl").takeIf { it.isNotEmpty() } ?: return null
        return IPTVPlaylist(
            id = id,
            name = obj.optString("name").takeIf { it.isNotEmpty() } ?: kind.label,
            kind = kind,
            transportUrl = transportUrl,
            createdAtMillis = obj.optLong("createdAt", System.currentTimeMillis()),
        )
    }

    private fun persistList() {
        val array = JSONArray()
        for (p in loaded) {
            array.put(
                JSONObject()
                    .put("id", p.id)
                    .put("name", p.name)
                    .put("kind", p.kind.wire)
                    .put("transportUrl", p.transportUrl)
                    .put("createdAt", p.createdAtMillis),
            )
        }
        persistence.writePlaylistsJson(array.toString())
    }

    // MARK: Removal tombstones (last-writer-wins across devices)

    /// Required by the union-merge in [applySyncBlob]: without a tombstone, a peer still holding a playlist the
    /// user removed here would re-add it on the next pull (a resurrection). Mirrors Apple's removal map: slug
    /// -> removal stamp (epoch millis, stored as a JSON number).
    private fun loadRemoved(): Map<String, Double> {
        val raw = persistence.readRemovedJson() ?: return emptyMap()
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return emptyMap()
        val map = HashMap<String, Double>()
        for (slug in obj.keys()) map[slug] = obj.optDouble(slug, 0.0)
        return map
    }

    private fun writeRemoved(map: Map<String, Double>) {
        val obj = JSONObject()
        for ((slug, stamp) in map) obj.put(slug, stamp)
        persistence.writeRemovedJson(obj.toString())
    }

    private fun stampRemovedTombstone(slug: String) {
        val map = loadRemoved().toMutableMap()
        map[slug] = System.currentTimeMillis().toDouble()
        writeRemoved(map)
    }

    private fun clearRemovedTombstone(slug: String) {
        val map = loadRemoved().toMutableMap()
        if (map.remove(slug) != null) writeRemoved(map)
    }

    // MARK: Credential (de)serialize

    /// Serialize [IPTVCredentials] with the SAME JSON keys the Apple `IPTVCredentials` Codable produces
    /// (`m3uURL` / `xtreamHost` / `xtreamUser` / `xtreamPass` / `xmltvURL`), so a credential adopted from a
    /// cross-platform sync blob round-trips. Absent fields are omitted.
    private fun encodeCredentials(credentials: IPTVCredentials): String {
        val obj = JSONObject()
        credentials.m3uUrl?.let { obj.put("m3uURL", it) }
        credentials.xtreamHost?.let { obj.put("xtreamHost", it) }
        credentials.xtreamUser?.let { obj.put("xtreamUser", it) }
        credentials.xtreamPass?.let { obj.put("xtreamPass", it) }
        credentials.xmltvUrl?.let { obj.put("xmltvURL", it) }
        return obj.toString()
    }

    private fun decodeCredentials(json: String): IPTVCredentials? {
        val obj = runCatching { JSONObject(json) }.getOrNull() ?: return null
        return IPTVCredentials(
            m3uUrl = obj.optString("m3uURL").takeIf { it.isNotEmpty() },
            xtreamHost = obj.optString("xtreamHost").takeIf { it.isNotEmpty() },
            xtreamUser = obj.optString("xtreamUser").takeIf { it.isNotEmpty() },
            xtreamPass = obj.optString("xtreamPass").takeIf { it.isNotEmpty() },
            xmltvUrl = obj.optString("xmltvURL").takeIf { it.isNotEmpty() },
        )
    }
}

/// Persistence seam for [IPTVPlaylistStore] so its logic is unit-testable with an in-memory fake. Production
/// binds [SharedPreferencesIPTVPersistence]; a test binds a map. The six methods mirror the Apple UserDefaults
/// (playlists + removed) / Keychain (credential) split exactly.
interface IPTVPersistence {
    fun readPlaylistsJson(): String?
    fun writePlaylistsJson(json: String)
    fun readRemovedJson(): String?
    fun writeRemovedJson(json: String)
    fun readCredential(slug: String): String?

    /// Persist the credential JSON for [slug], or clear it when [json] is null.
    fun writeCredential(slug: String, json: String?)
}

/// Production [IPTVPersistence]: the non-secret metadata (playlists list + removal tombstones) in a plain
/// SharedPreferences file, the credentials in the encrypted [SecureTokenStore], mirroring the Apple
/// UserDefaults / Keychain split and the [com.vortx.android.mediaserver.MediaServerRepository] storage split.
class SharedPreferencesIPTVPersistence(context: Context) : IPTVPersistence {
    private val meta = context.applicationContext.getSharedPreferences(META_PREFS, Context.MODE_PRIVATE)
    private val creds = SecureTokenStore(context.applicationContext, CRED_PREFS)

    override fun readPlaylistsJson(): String? = meta.getString(KEY_PLAYLISTS, null)
    override fun writePlaylistsJson(json: String) {
        meta.edit().putString(KEY_PLAYLISTS, json).apply()
    }

    override fun readRemovedJson(): String? = meta.getString(KEY_REMOVED, null)
    override fun writeRemovedJson(json: String) {
        meta.edit().putString(KEY_REMOVED, json).apply()
    }

    override fun readCredential(slug: String): String? = creds.string(credKey(slug))
    override fun writeCredential(slug: String, json: String?) = creds.set(credKey(slug), json)

    private fun credKey(slug: String): String = KEY_CRED_PREFIX + slug

    private companion object {
        const val META_PREFS = "vortx_iptv_meta"
        const val CRED_PREFS = "vortx_iptv_creds"

        /// Apple @AppStorage / UserDefaults key `vortx.iptv.playlists` (IPTVPlaylistStore.swift:52). The SAME
        /// string so a future cross-platform sync wave can dual-wire the value.
        const val KEY_PLAYLISTS = "vortx.iptv.playlists"

        /// Apple UserDefaults key `vortx.iptv.removed` (the removal-tombstone map, IPTVPlaylistStore.swift:53).
        const val KEY_REMOVED = "vortx.iptv.removed"

        /// Apple Keychain account prefix `vortx.iptv.cred.<slug>` (IPTVPlaylistStore.swift:54).
        const val KEY_CRED_PREFIX = "vortx.iptv.cred."
    }
}

/// The process-wide singleton over one live [IPTVPlaylistStore], mirroring the Apple `IPTVPlaylistStore.shared`.
/// The settings screen mutates it and (later) the sync lane reads it, so both see one truth. [init] is
/// idempotent and safe to call from every entry point (the same shape [MediaServerRepository.init] uses).
object IPTVPlaylists {
    @Volatile private var store: IPTVPlaylistStore? = null

    fun init(context: Context) {
        if (store != null) return
        synchronized(this) {
            if (store == null) store = IPTVPlaylistStore(SharedPreferencesIPTVPersistence(context))
        }
    }

    private fun require(): IPTVPlaylistStore =
        store ?: error("IPTVPlaylists.init(context) must be called before use")

    fun playlists(): List<IPTVPlaylist> = require().playlists()
    fun add(playlist: IPTVPlaylist, credentials: IPTVCredentials) = require().add(playlist, credentials)
    fun remove(slug: String) = require().remove(slug)
    fun credentials(slug: String): IPTVCredentials? = require().credentials(slug)
    fun contains(transportUrl: String): Boolean = require().contains(transportUrl)
    fun reload() = require().reload()
    fun syncBlob(): String? = require().syncBlob()
    fun applySyncBlob(json: String) = require().applySyncBlob(json)
}
