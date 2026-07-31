package com.vortx.android.iptv

import android.content.Context
import com.vortx.android.integrations.SecureTokenStore
import com.vortx.android.security.ConditionalCredentialWrite
import com.vortx.android.security.PersistentCredentialAvailability
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
internal class IPTVPlaylistStore(private val persistence: IPTVPersistence) {

    /// Serializes every compound metadata / cleanup-journal read-modify-write in this process. Store methods
    /// never suspend, so callers release this lock before the coordinator performs add-on or Worker network work.
    private val lock = Any()

    private inline fun <T> withLock(block: () -> T): T = synchronized(lock, block)

    /// The installed playlists, newest first, held in memory and re-persisted whole on every mutation (the
    /// same whole-array rewrite Apple's `persistList()` does).
    private var loaded: List<IPTVPlaylist> = load()

    /// The installed playlists, newest first. A snapshot for the settings screen.
    fun playlists(): List<IPTVPlaylist> = withLock { loaded }

    /// Re-read the persisted playlists (the Apple `reloadFromDefaults`). A read must never write, so this does
    /// not persist and does not nudge sync; it exists so a future account-settings pull or backup restore that
    /// writes the underlying store directly is picked up instead of being flushed over by a stale in-memory
    /// array.
    fun reload() = withLock {
        loaded = load()
    }

    // MARK: Mutations

    /// Record a freshly-registered playlist: stash its credentials in the encrypted store and prepend its
    /// metadata. Idempotent by slug (a re-add of the same slug replaces the existing entry). Mirrors Apple
    /// `add(_:credentials:)`.
    fun add(playlist: IPTVPlaylist, credentials: IPTVCredentials): Boolean = withLock {
        val previousCredential = persistence.readCredential(playlist.id)
        if (previousCredential == IPTVCredentialRead.Unavailable) return false
        if (!persistence.writeCredential(playlist.id, encodeCredentials(credentials))) return false
        val nextLoaded = listOf(playlist) + loaded.filter { it.id != playlist.id }
        val nextRemoved = loadRemoved().toMutableMap().apply { remove(playlist.id) }
        if (!persistState(nextLoaded, nextRemoved)) {
            restoreCredential(playlist.id, previousCredential)
            return false
        }
        loaded = nextLoaded
        return true
    }

    /// Forget a playlist locally: atomically hide its metadata and stamp a removal tombstone, then confirm the
    /// credential clear. A caller stages the durable external-cleanup journal first, so a failed clear resumes
    /// without ever exposing a visible playlist whose credential was already destroyed.
    fun remove(slug: String): Boolean = withLock {
        if (persistence.readCredential(slug) == IPTVCredentialRead.Unavailable) return false
        val nextLoaded = loaded.filter { it.id != slug }
        val nextRemoved = loadRemoved().toMutableMap().apply {
            this[slug] = System.currentTimeMillis().toDouble()
        }
        if (!persistState(nextLoaded, nextRemoved)) return false
        loaded = nextLoaded
        return persistence.writeCredential(slug, null)
    }

    /// The stored credentials for a slug, or null when absent. Mirrors Apple `credentials(for:)`.
    fun credentials(slug: String): IPTVCredentials? = withLock {
        (persistence.readCredential(slug) as? IPTVCredentialRead.Present)?.value?.let(::decodeCredentials)
    }

    /// True when a playlist with this transport URL is already recorded (so the UI can avoid duplicates).
    /// Mirrors Apple `contains(transportUrl:)`.
    fun contains(transportUrl: String): Boolean = withLock {
        loaded.any { it.transportUrl == transportUrl }
    }

    fun registrationSlot(slug: String): IPTVRegistrationSlot = withLock {
        if (loaded.any { it.id == slug }) return IPTVRegistrationSlot.CONFLICT
        when (persistence.readCredential(slug)) {
            is IPTVCredentialRead.Present -> return IPTVRegistrationSlot.CONFLICT
            IPTVCredentialRead.Unavailable -> return IPTVRegistrationSlot.UNAVAILABLE
            IPTVCredentialRead.Absent -> Unit
        }
        val pending = pendingCleanupState()
        if (pending is IPTVPendingCleanupRead.Available && pending.cleanups.any { it.slug == slug }) {
            return IPTVRegistrationSlot.CONFLICT
        }
        return IPTVRegistrationSlot.AVAILABLE
    }

    // MARK: Sync blob (the account-encrypted channel)

    /// The JSON string mirrored on the account channel under `vortx.iptv`, or null when there is nothing to
    /// sync (no playlists AND no tombstones). The credentials ride the doc as an opaque `cred` string, exactly
    /// as the Apple store carries them, so a reinstalled device's restored playlists can live again. Mirrors
    /// the Apple `syncBlob()`. Wired to the sync lane in a later wave; the shape is fixed now so both
    /// platforms converge.
    fun syncBlob(): String? = withLock {
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
            (persistence.readCredential(p.id) as? IPTVCredentialRead.Present)
                ?.value
                ?.takeIf { it.isNotEmpty() }
                ?.let { obj.put("cred", it) }
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
    fun applySyncBlob(json: String): Boolean = withLock {
        val root = runCatching { JSONObject(json) }.getOrNull() ?: return false
        val remote = root.optJSONArray("playlists") ?: JSONArray()
        val remoteRemoved = root.optJSONObject("removed") ?: JSONObject()

        val localRemoved = loadRemoved().toMutableMap()
        val bySlug = LinkedHashMap<String, IPTVPlaylist>()
        for (p in loaded) bySlug[p.id] = p
        var changed = false
        var removedChanged = false
        var allCredentialsConfirmed = true
        val credentialRollbacks = linkedMapOf<String, IPTVCredentialRead>()

        // Apply a newer remote tombstone only after any older local credential is confirmed cleared. A failed
        // clear keeps both the visible record and its previous tombstone state so the next sync can retry.
        for (slug in remoteRemoved.keys()) {
            val stamp = remoteRemoved.optDouble(slug, 0.0)
            if (stamp <= (localRemoved[slug] ?: 0.0)) continue
            val localRecord = bySlug[slug]
            if (localRecord == null || stamp > localRecord.createdAtMillis.toDouble()) {
                when (val previous = persistence.readCredential(slug)) {
                    is IPTVCredentialRead.Present -> {
                        if (!persistence.writeCredential(slug, null)) {
                            allCredentialsConfirmed = false
                            continue
                        }
                        credentialRollbacks.putIfAbsent(slug, previous)
                    }
                    IPTVCredentialRead.Absent -> Unit
                    IPTVCredentialRead.Unavailable -> {
                        allCredentialsConfirmed = false
                        continue
                    }
                }
                if (bySlug.remove(slug) != null) changed = true
            }
            localRemoved[slug] = stamp
            removedChanged = true
        }

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
                continue
            }
            val existing = bySlug[slug]
            if (existing != null && existing.createdAtMillis > createdAt) continue
            // Credentials: adopt into the encrypted store only when the local slot is empty (store
            // authoritative). This is the leg that makes a reinstalled device's restored playlists live again.
            when (persistence.readCredential(slug)) {
                is IPTVCredentialRead.Present -> Unit
                IPTVCredentialRead.Absent -> {
                    val remoteCredential = obj.optString("cred").takeIf { it.isNotEmpty() }
                    val adoption = remoteCredential?.let {
                        persistence.writeCredentialIfConfirmedAbsent(slug, it)
                    }
                    when (adoption) {
                        ConditionalCredentialWrite.WRITTEN ->
                            credentialRollbacks.putIfAbsent(slug, IPTVCredentialRead.Absent)
                        ConditionalCredentialWrite.ALREADY_PRESENT -> Unit
                        ConditionalCredentialWrite.UNAVAILABLE,
                        ConditionalCredentialWrite.REJECTED,
                        null -> {
                            allCredentialsConfirmed = false
                            continue
                        }
                    }
                }
                IPTVCredentialRead.Unavailable -> {
                    allCredentialsConfirmed = false
                    continue
                }
            }
            if (localRemoved.remove(slug) != null) {
                removedChanged = true
            }
            val record = IPTVPlaylist(id = slug, name = name, kind = kind, transportUrl = transportUrl, createdAtMillis = createdAt)
            if (bySlug[slug] != record) {
                bySlug[slug] = record
                changed = true
            }
        }

        if (removedChanged || changed) {
            val nextLoaded = bySlug.values.sortedByDescending { it.createdAtMillis }
            if (!persistState(nextLoaded, localRemoved)) {
                credentialRollbacks.forEach(::restoreCredential)
                return false
            }
            loaded = nextLoaded
        }
        return allCredentialsConfirmed
    }

    // MARK: Durable external-cleanup journal

    fun pendingCleanupState(): IPTVPendingCleanupRead = withLock {
        val raw = when (val metadata = readMetadata()) {
            is IPTVMetadataRead.Available -> metadata.snapshot.pendingCleanupJson
            IPTVMetadataRead.Unavailable -> return IPTVPendingCleanupRead.UnavailableOrCorrupt
        }
            ?: return IPTVPendingCleanupRead.Absent
        val array = runCatching { JSONArray(raw) }.getOrNull()
            ?: return IPTVPendingCleanupRead.UnavailableOrCorrupt
        val cleanups = ArrayList<IPTVPendingCleanup>(array.length())
        val slugs = hashSetOf<String>()
        for (index in 0 until array.length()) {
            val cleanup = array.optJSONObject(index)?.let(::parsePendingCleanup)
                ?: return IPTVPendingCleanupRead.UnavailableOrCorrupt
            if (!slugs.add(cleanup.slug)) return IPTVPendingCleanupRead.UnavailableOrCorrupt
            cleanups += cleanup
        }
        return IPTVPendingCleanupRead.Available(cleanups)
    }

    /**
     * Durably stage cleanup before any add-on install or local removal. The transport URL is the Worker-created
     * manifest URL, which is an opaque nonsecret locator; playlist credentials never enter this journal.
     */
    fun beginCleanup(cleanup: IPTVPendingCleanup): Boolean = withLock {
        val current = when (val state = pendingCleanupState()) {
            is IPTVPendingCleanupRead.Available -> state.cleanups
            IPTVPendingCleanupRead.Absent -> emptyList()
            IPTVPendingCleanupRead.UnavailableOrCorrupt -> return false
        }
        if (current.any { it.slug == cleanup.slug }) return false
        return writePendingCleanups(listOf(cleanup) + current)
    }

    fun markCleanupCommitted(slug: String): Boolean =
        withLock { updateCleanup(slug) { it.copy(disposition = IPTVCleanupDisposition.COMMITTED) } }

    fun markCleanupLocalRemoved(slug: String): Boolean =
        withLock { updateCleanup(slug) { it.copy(localRemoved = true) } }

    fun markCleanupAddonRemoved(slug: String): Boolean =
        withLock { updateCleanup(slug) { it.copy(addonRemoved = true) } }

    fun markCleanupWorkerRevoked(slug: String): Boolean =
        withLock { updateCleanup(slug) { it.copy(workerRevoked = true) } }

    fun finishCleanup(slug: String): Boolean = withLock {
        when (val state = pendingCleanupState()) {
            is IPTVPendingCleanupRead.Available ->
                writePendingCleanups(state.cleanups.filter { it.slug != slug })
            IPTVPendingCleanupRead.Absent -> true
            IPTVPendingCleanupRead.UnavailableOrCorrupt -> false
        }
    }

    private fun updateCleanup(
        slug: String,
        transform: (IPTVPendingCleanup) -> IPTVPendingCleanup,
    ): Boolean {
        val current = when (val state = pendingCleanupState()) {
            is IPTVPendingCleanupRead.Available -> state.cleanups
            IPTVPendingCleanupRead.Absent,
            IPTVPendingCleanupRead.UnavailableOrCorrupt -> return false
        }
        if (current.none { it.slug == slug }) return false
        return writePendingCleanups(current.map { if (it.slug == slug) transform(it) else it })
    }

    private fun writePendingCleanups(cleanups: List<IPTVPendingCleanup>): Boolean {
        if (cleanups.isEmpty()) return persistence.writePendingCleanupJson(null)
        val array = JSONArray()
        cleanups.forEach { cleanup ->
            array.put(
                JSONObject()
                    .put("slug", cleanup.slug)
                    .put("transportUrl", cleanup.transportUrl)
                    .put("origin", cleanup.origin.wire)
                    .put("disposition", cleanup.disposition.wire)
                    .put("localRemoved", cleanup.localRemoved)
                    .put("addonRemoved", cleanup.addonRemoved)
                    .put("workerRevoked", cleanup.workerRevoked),
            )
        }
        return persistence.writePendingCleanupJson(array.toString())
    }

    private fun parsePendingCleanup(obj: JSONObject): IPTVPendingCleanup? {
        val slug = obj.optString("slug").takeIf { it.isNotEmpty() } ?: return null
        val transportUrl = obj.optString("transportUrl").takeIf { it.isNotEmpty() } ?: return null
        val origin = IPTVCleanupOrigin.fromWire(obj.optString("origin")) ?: return null
        val disposition = IPTVCleanupDisposition.fromWire(obj.optString("disposition")) ?: return null
        return IPTVPendingCleanup(
            slug = slug,
            transportUrl = transportUrl,
            origin = origin,
            disposition = disposition,
            localRemoved = obj.optBoolean("localRemoved", false),
            addonRemoved = obj.optBoolean("addonRemoved", false),
            workerRevoked = obj.optBoolean("workerRevoked", false),
        )
    }

    // MARK: Persistence (metadata)

    private fun load(): List<IPTVPlaylist> {
        val raw = (readMetadata() as? IPTVMetadataRead.Available)
            ?.snapshot
            ?.playlistsJson
            ?: return emptyList()
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

    private fun encodePlaylists(playlists: List<IPTVPlaylist>): String {
        val array = JSONArray()
        for (p in playlists) {
            array.put(
                JSONObject()
                    .put("id", p.id)
                    .put("name", p.name)
                    .put("kind", p.kind.wire)
                    .put("transportUrl", p.transportUrl)
                    .put("createdAt", p.createdAtMillis),
            )
        }
        return array.toString()
    }

    // MARK: Removal tombstones (last-writer-wins across devices)

    /// Required by the union-merge in [applySyncBlob]: without a tombstone, a peer still holding a playlist the
    /// user removed here would re-add it on the next pull (a resurrection). Mirrors Apple's removal map: slug
    /// -> removal stamp (epoch millis, stored as a JSON number).
    private fun loadRemoved(): Map<String, Double> {
        val raw = (readMetadata() as? IPTVMetadataRead.Available)
            ?.snapshot
            ?.removedJson
            ?: return emptyMap()
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return emptyMap()
        val map = HashMap<String, Double>()
        for (slug in obj.keys()) map[slug] = obj.optDouble(slug, 0.0)
        return map
    }

    private fun readMetadata(): IPTVMetadataRead =
        runCatching(persistence::readMetadata).getOrDefault(IPTVMetadataRead.Unavailable)

    private fun encodeRemoved(map: Map<String, Double>): String {
        val obj = JSONObject()
        for ((slug, stamp) in map) obj.put(slug, stamp)
        return obj.toString()
    }

    private fun persistState(playlists: List<IPTVPlaylist>, removed: Map<String, Double>): Boolean =
        persistence.writeMetadata(
            playlistsJson = encodePlaylists(playlists),
            removedJson = encodeRemoved(removed),
        )

    private fun restoreCredential(slug: String, previous: IPTVCredentialRead) {
        when (previous) {
            is IPTVCredentialRead.Present -> persistence.writeCredential(slug, previous.value)
            IPTVCredentialRead.Absent -> persistence.writeCredential(slug, null)
            IPTVCredentialRead.Unavailable -> Unit
        }
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
/// binds [SharedPreferencesIPTVPersistence]; a test binds a map. The methods mirror the Apple UserDefaults
/// (playlists + removed) / Keychain (credential) split exactly.
internal interface IPTVPersistence {
    fun readMetadata(): IPTVMetadataRead
    fun writeMetadata(playlistsJson: String, removedJson: String): Boolean
    fun readCredential(slug: String): IPTVCredentialRead

    /// Persist the credential JSON for [slug], or clear it when [json] is null.
    fun writeCredential(slug: String, json: String?): Boolean

    fun writeCredentialIfConfirmedAbsent(slug: String, json: String): ConditionalCredentialWrite
    fun writePendingCleanupJson(json: String?): Boolean
}

internal data class IPTVMetadataSnapshot(
    val playlistsJson: String?,
    val removedJson: String?,
    val pendingCleanupJson: String?,
)

internal sealed interface IPTVMetadataRead {
    data class Available(val snapshot: IPTVMetadataSnapshot) : IPTVMetadataRead
    data object Unavailable : IPTVMetadataRead
}

/**
 * Keeps the last process-confirmed playlist, tombstone, and cleanup-journal image authoritative. A rejected
 * SharedPreferences commit may already have mutated its process cache, so a false return or exception
 * permanently poisons later publishes in this process while reads retain the prior confirmed image.
 */
internal class ConfirmedIPTVMetadata(
    private val readPersisted: () -> IPTVMetadataRead,
    private val writePersisted: (IPTVMetadataSnapshot) -> Boolean,
) {
    private val lock = Any()
    private var confirmed: IPTVMetadataRead? = null
    private var poisoned = false

    fun read(): IPTVMetadataRead = synchronized(lock) {
        confirmed ?: runCatching(readPersisted)
            .getOrDefault(IPTVMetadataRead.Unavailable)
            .also { confirmed = it }
    }

    fun publish(next: IPTVMetadataSnapshot): Boolean = synchronized(lock) {
        val current = confirmed ?: runCatching(readPersisted)
            .getOrDefault(IPTVMetadataRead.Unavailable)
            .also { confirmed = it }
        if (poisoned || current !is IPTVMetadataRead.Available) return@synchronized false
        val committed = runCatching { writePersisted(next) }.getOrDefault(false)
        if (committed) {
            confirmed = IPTVMetadataRead.Available(next)
        } else {
            poisoned = true
        }
        committed
    }
}

/// Production [IPTVPersistence]: the non-secret metadata (playlists list + removal tombstones) in a plain
/// SharedPreferences file, the credentials in the encrypted [SecureTokenStore], mirroring the Apple
/// UserDefaults / Keychain split and the [com.vortx.android.mediaserver.MediaServerRepository] storage split.
internal class SharedPreferencesIPTVPersistence(context: Context) : IPTVPersistence {
    private val meta = context.applicationContext.getSharedPreferences(META_PREFS, Context.MODE_PRIVATE)
    private val creds = SecureTokenStore(context.applicationContext, CRED_PREFS)
    private val metadata = ConfirmedIPTVMetadata(
        readPersisted = {
            IPTVMetadataRead.Available(
                IPTVMetadataSnapshot(
                    playlistsJson = meta.getString(KEY_PLAYLISTS, null),
                    removedJson = meta.getString(KEY_REMOVED, null),
                    pendingCleanupJson = meta.getString(KEY_PENDING_CLEANUP, null),
                ),
            )
        },
        writePersisted = { snapshot ->
            val edit = meta.edit()
            if (snapshot.playlistsJson == null) {
                edit.remove(KEY_PLAYLISTS)
            } else {
                edit.putString(KEY_PLAYLISTS, snapshot.playlistsJson)
            }
            if (snapshot.removedJson == null) {
                edit.remove(KEY_REMOVED)
            } else {
                edit.putString(KEY_REMOVED, snapshot.removedJson)
            }
            if (snapshot.pendingCleanupJson == null) {
                edit.remove(KEY_PENDING_CLEANUP)
            } else {
                edit.putString(KEY_PENDING_CLEANUP, snapshot.pendingCleanupJson)
            }
            edit.commit()
        },
    )

    override fun readMetadata(): IPTVMetadataRead = metadata.read()

    override fun writeMetadata(playlistsJson: String, removedJson: String): Boolean {
        val current = (metadata.read() as? IPTVMetadataRead.Available)?.snapshot ?: return false
        return metadata.publish(
            current.copy(
                playlistsJson = playlistsJson,
                removedJson = removedJson,
            ),
        )
    }

    override fun readCredential(slug: String): IPTVCredentialRead {
        val key = credKey(slug)
        val snapshot = creds.confirmedSnapshot(key)
        if (snapshot.availability == PersistentCredentialAvailability.UNAVAILABLE) {
            return IPTVCredentialRead.Unavailable
        }
        return snapshot.values[key]?.let(IPTVCredentialRead::Present) ?: IPTVCredentialRead.Absent
    }

    override fun writeCredential(slug: String, json: String?): Boolean =
        creds.set(credKey(slug), json)
    override fun writeCredentialIfConfirmedAbsent(slug: String, json: String): ConditionalCredentialWrite =
        creds.setIfConfirmedAbsent(credKey(slug), json)

    override fun writePendingCleanupJson(json: String?): Boolean {
        val current = (metadata.read() as? IPTVMetadataRead.Available)?.snapshot ?: return false
        return metadata.publish(current.copy(pendingCleanupJson = json))
    }

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
        const val KEY_PENDING_CLEANUP = "vortx.iptv.pendingCleanup"
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

    internal fun cleanupStore(): IPTVPlaylistStore = require()

    fun playlists(): List<IPTVPlaylist> = require().playlists()
    fun add(playlist: IPTVPlaylist, credentials: IPTVCredentials) = require().add(playlist, credentials)
    fun remove(slug: String) = require().remove(slug)
    fun credentials(slug: String): IPTVCredentials? = require().credentials(slug)
    fun contains(transportUrl: String): Boolean = require().contains(transportUrl)
    fun reload() = require().reload()
    fun syncBlob(): String? = require().syncBlob()
    fun applySyncBlob(json: String) = require().applySyncBlob(json)
    internal fun pendingCleanupState(): IPTVPendingCleanupRead = require().pendingCleanupState()
    internal fun beginCleanup(cleanup: IPTVPendingCleanup): Boolean = require().beginCleanup(cleanup)
}

internal sealed interface IPTVCredentialRead {
    data class Present(val value: String) : IPTVCredentialRead
    data object Absent : IPTVCredentialRead
    data object Unavailable : IPTVCredentialRead
}

internal enum class IPTVRegistrationSlot {
    AVAILABLE,
    CONFLICT,
    UNAVAILABLE,
}

internal enum class IPTVCleanupOrigin(val wire: String) {
    ADD_ROLLBACK("addRollback"),
    REMOVE("remove");

    companion object {
        fun fromWire(wire: String): IPTVCleanupOrigin? = entries.firstOrNull { it.wire == wire }
    }
}

internal enum class IPTVCleanupDisposition(val wire: String) {
    ROLLBACK("rollback"),
    COMMITTED("committed");

    companion object {
        fun fromWire(wire: String): IPTVCleanupDisposition? = entries.firstOrNull { it.wire == wire }
    }
}

internal data class IPTVPendingCleanup(
    val slug: String,
    val transportUrl: String,
    val origin: IPTVCleanupOrigin,
    val disposition: IPTVCleanupDisposition = IPTVCleanupDisposition.ROLLBACK,
    val localRemoved: Boolean = false,
    val addonRemoved: Boolean = false,
    val workerRevoked: Boolean = false,
)

internal sealed interface IPTVPendingCleanupRead {
    data class Available(val cleanups: List<IPTVPendingCleanup>) : IPTVPendingCleanupRead
    data object Absent : IPTVPendingCleanupRead
    data object UnavailableOrCorrupt : IPTVPendingCleanupRead
}
