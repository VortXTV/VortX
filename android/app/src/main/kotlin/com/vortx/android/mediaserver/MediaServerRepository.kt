package com.vortx.android.mediaserver

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.integrations.CredentialStoreAccess
import com.vortx.android.integrations.SecureTokenStore
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/// The single facade the app talks to for personal media servers (Plex / Jellyfin / Emby). It is the Android
/// fusion of the Apple `MediaServerStore` (the connected-servers record + Keychain tokens) and
/// `MediaServerCoordinator` (build providers, fan a lookup out across servers), plus the `MediaServerSource`
/// hit -> source-group mapping, kept in ONE process-wide singleton so the settings screen (which mutates the
/// list) and [com.vortx.android.ui.viewmodel.DetailViewModel] (which reads direct-play sources) share exactly
/// one live truth. Mirrors the Apple singletons `MediaServerStore.shared` / `MediaServerCoordinator.shared`.
///
/// STORAGE (the Apple UserDefaults / Keychain split): the non-secret record metadata (display name, kind,
/// ordered connection URLs, user id, machine id) lives in a plain [SharedPreferences]; the per-server access
/// TOKEN and the Plex account token are credentials and live ONLY in the encrypted [SecureTokenStore]. Tokens
/// therefore never enter a settings backup and never leave the device except straight to the user's own
/// server / plex.tv.
///
/// DORMANT BY DEFAULT: with no server recorded, [hasServers] is false, [find] returns `[]` synchronously
/// before any provider work, and nothing here touches the network. The store is the single gate the detail
/// source contributor checks (`hasServers == false` -> zero media-server network anywhere in the app).
object MediaServerRepository {

    private const val META_PREFS = "vortx_mediaserver_meta"
    private const val TOKEN_PREFS = "vortx_mediaserver_tokens"
    private const val RECORDS_KEY = "records"
    private const val DEVICE_ID_KEY = "deviceId"
    private const val PLEX_CLIENT_KEY = "plexClientId"
    private const val PLEX_ACCOUNT_TOKEN_KEY = "vortx.mediaserver.plexAccount.token"
    private const val PENDING_REMOVALS_KEY = "pendingRemovals"
    private const val PENDING_ADDS_KEY = "pendingAdds"

    @Volatile private var metaPrefs: SharedPreferences? = null
    @Volatile private var metadataState: ConfirmedMediaServerMetadata? = null
    @Volatile private var tokenStore: CredentialStoreAccess? = null
    @Volatile private var records: List<MediaServerRecord> = emptyList()

    private data class ServerProvider(val id: UUID, val provider: MediaServerProvider)
    private data class ProviderState(
        val generation: Long,
        val providers: List<ServerProvider>,
        val activeIds: Set<UUID>,
    )

    internal data class CatalogSnapshot(
        val generation: Long,
        val configs: List<MediaServerConfig>,
    )

    @Volatile
    private var providerState = ProviderState(
        generation = 0L,
        providers = emptyList(),
        activeIds = emptySet(),
    )

    @Volatile
    private var catalogState = CatalogSnapshot(generation = 0L, configs = emptyList())
    private val _configurationBoundary = MutableStateFlow(0L)
    internal val configurationBoundary: StateFlow<Long> = _configurationBoundary.asStateFlow()

    internal fun catalogSnapshot(): CatalogSnapshot = catalogState

    /// Idempotent init: build the plain metadata prefs + encrypted token store, load persisted records, and
    /// warm the providers so a server connected in a previous run is queryable after a restart WITHOUT the
    /// user opening settings. Safe to call from every entry point (the Application, the settings screen).
    fun init(context: Context) {
        synchronized(this) {
            if (metaPrefs == null) {
                val prefs =
                    context.applicationContext.getSharedPreferences(META_PREFS, Context.MODE_PRIVATE)
                metaPrefs = prefs
                metadataState = ConfirmedMediaServerMetadata(
                    readPersisted = { readMetadataSnapshot(prefs) },
                    writePersisted = { snapshot -> writeMetadataSnapshot(prefs, snapshot) },
                )
            }
            if (tokenStore == null) tokenStore = SecureTokenStore(context.applicationContext, TOKEN_PREFS)
            val snapshot = confirmedMetadata()
            if (snapshot == null) {
                records = emptyList()
                rebuildProviders()
                return@synchronized
            }
            records = snapshot.records
            resumePendingAdds()
            resumePendingRemovals()
            rebuildProviders()
        }
    }

    // MARK: - Public state

    /// True when at least one server is connected. The dormancy gate: the detail source contributor + the
    /// catalog rails check this and make zero media-server calls when it is false.
    val hasServers: Boolean get() = records.isNotEmpty()

    /// A snapshot of the connected servers, newest first, for the settings screen.
    fun servers(): List<MediaServerRecord> = records

    /// A stable per-install id used as the Jellyfin/Emby `DeviceId` and (separately) the Plex client id.
    /// Persisted so a Plex token (anchored to the client id) survives relaunches.
    val deviceId: String get() = stableId(DEVICE_ID_KEY)
    val plexClientId: String get() = stableId(PLEX_CLIENT_KEY)

    private fun stableId(key: String): String {
        val prefs = metaPrefs
        val existing = prefs?.getString(key, null)
        if (!existing.isNullOrEmpty()) return existing
        val generated = UUID.randomUUID().toString()
        prefs?.edit()?.putString(key, generated)?.apply()
        return generated
    }

    // MARK: - Mutations (connect / disconnect)

    /// Record a freshly-connected server: stash its token (+ the Plex account token) in the encrypted store,
    /// prepend the metadata, persist, and rebuild the providers. Idempotent by id.
    fun add(
        record: MediaServerRecord,
        token: String,
        plexAccountToken: String? = null,
    ): MediaServerAddResult =
        synchronized(this) {
            val store = tokenStore ?: return@synchronized MediaServerAddResult.NOT_CONNECTED
            val current = confirmedMetadata()
                ?: return@synchronized MediaServerAddResult.NOT_CONNECTED
            if (current.pendingAdds.any { it.serverId == record.id }) {
                return@synchronized MediaServerAddResult.RECOVERY_PENDING
            }

            val tokenKey = tokenKey(record.id)
            val backupKey = addBackupKey(record.id)
            val preparation = prepareMediaServerAddCredentials(
                store = store,
                tokenKey = tokenKey,
                backupKey = backupKey,
                token = token,
                plexAccountTokenKey = PLEX_ACCOUNT_TOKEN_KEY,
                plexAccountToken = plexAccountToken,
            )
            val values = when (preparation) {
                is MediaServerAddCredentialPreparation.Ready -> preparation.values
                MediaServerAddCredentialPreparation.Unavailable ->
                    return@synchronized MediaServerAddResult.NOT_CONNECTED
                MediaServerAddCredentialPreparation.RecoveryPending ->
                    return@synchronized MediaServerAddResult.RECOVERY_PENDING
            }

            val rollback = MediaServerAddJournal(
                serverId = record.id,
                disposition = MediaServerAddDisposition.ROLLBACK,
            )
            val rollbackSnapshot = current.copy(
                pendingAdds = listOf(rollback) + current.pendingAdds,
            )
            if (!persistRepositoryState(rollbackSnapshot)) {
                return@synchronized MediaServerAddResult.NOT_CONNECTED
            }

            if (!store.set(values)) {
                return@synchronized if (finishAddJournal(rollback)) {
                    MediaServerAddResult.NOT_CONNECTED
                } else {
                    MediaServerAddResult.RECOVERY_PENDING
                }
            }

            val committed = rollback.copy(disposition = MediaServerAddDisposition.COMMITTED)
            val nextRecords = listOf(record) + records.filter { it.id != record.id }
            val committedSnapshot = rollbackSnapshot.copy(
                records = nextRecords,
                pendingRemovals = rollbackSnapshot.pendingRemovals - record.id,
                pendingAdds = rollbackSnapshot.pendingAdds.map {
                    if (it.serverId == record.id) committed else it
                },
            )
            if (!persistRepositoryState(committedSnapshot)) {
                resolveMediaServerAddCredentials(
                    store = store,
                    tokenKey = tokenKey,
                    backupKey = backupKey,
                    plexAccountTokenKey = PLEX_ACCOUNT_TOKEN_KEY,
                    disposition = MediaServerAddDisposition.ROLLBACK,
                )
                return@synchronized MediaServerAddResult.RECOVERY_PENDING
            }

            records = nextRecords
            rebuildProviders()
            finishAddJournal(committed)
            MediaServerAddResult.CONNECTED
        }

    /// Forget a server: drop its token and metadata, persist, rebuild the providers.
    fun remove(id: UUID): MediaServerRemovalResult = synchronized(this) {
        val store = tokenStore ?: return@synchronized MediaServerRemovalResult.UNCHANGED
        val current = confirmedMetadata()
            ?: return@synchronized MediaServerRemovalResult.UNCHANGED
        val nextRecords = records.filter { it.id != id }
        val pending = current.pendingRemovals + id
        completeMediaServerRemoval(
            publishRemoval = {
                if (!persistRepositoryState(
                        current.copy(
                            records = nextRecords,
                            pendingRemovals = pending,
                        ),
                    )
                ) {
                    false
                } else {
                    records = nextRecords
                    rebuildProviders()
                    true
                }
            },
            clearCredential = { store.clear(tokenKey(id)) },
            finishCleanup = {
                val latest = confirmedMetadata() ?: return@completeMediaServerRemoval false
                persistRepositoryState(latest.copy(pendingRemovals = pending - id))
            },
        )
    }

    private fun resumePendingAdds() {
        val store = tokenStore ?: return
        val pending = confirmedMetadata()?.pendingAdds ?: return
        resumeMediaServerAddJournals(
            journals = pending,
            resolveCredentials = { journal ->
                resolveMediaServerAddCredentials(
                    store = store,
                    tokenKey = tokenKey(journal.serverId),
                    backupKey = addBackupKey(journal.serverId),
                    plexAccountTokenKey = PLEX_ACCOUNT_TOKEN_KEY,
                    disposition = journal.disposition,
                )
            },
            publishRemaining = { remaining ->
                val latest = confirmedMetadata() ?: return@resumeMediaServerAddJournals false
                persistRepositoryState(latest.copy(pendingAdds = remaining))
            },
        )
    }

    private fun finishAddJournal(journal: MediaServerAddJournal): Boolean {
        val store = tokenStore ?: return false
        if (!resolveMediaServerAddCredentials(
                store = store,
                tokenKey = tokenKey(journal.serverId),
                backupKey = addBackupKey(journal.serverId),
                plexAccountTokenKey = PLEX_ACCOUNT_TOKEN_KEY,
                disposition = journal.disposition,
            )
        ) {
            return false
        }
        val latest = confirmedMetadata() ?: return false
        return persistRepositoryState(
            latest.copy(
                pendingAdds = latest.pendingAdds.filter { it.serverId != journal.serverId },
            ),
        )
    }

    private fun resumePendingRemovals() {
        val store = tokenStore ?: return
        val pending = confirmedMetadata()?.pendingRemovals ?: return
        resumeMediaServerRemovals(
            pendingIds = pending,
            activeIds = records.mapTo(linkedSetOf()) { it.id },
            clearCredential = { id -> store.clear(tokenKey(id)) },
            publishPending = { ids ->
                val latest = confirmedMetadata() ?: return@resumeMediaServerRemovals false
                persistRepositoryState(latest.copy(pendingRemovals = ids))
            },
        )
    }

    /// Mark a server as needing re-auth (a provider 401/403). Surfaced as a settings badge; never blocks the
    /// other servers. No-op if already flagged or unknown.
    fun markNeedsReauth(id: UUID) = synchronized(this) {
        // Called from concurrent provider fan-out coroutines (off the main thread), so serialize the
        // copy-on-write against a second server failing at the same instant.
        val idx = records.indexOfFirst { it.id == id }
        if (idx < 0 || records[idx].needsReauth) return@synchronized
        val next = records.toMutableList().also { it[idx] = it[idx].copy(needsReauth = true) }
        val current = confirmedMetadata() ?: return@synchronized
        if (persistRepositoryState(current.copy(records = next))) {
            records = next
        }
    }

    // MARK: - Lookup (coordinator)

    /// Query every connected server CONCURRENTLY for a title and collect the direct-play hits. Tries the
    /// detail id first per provider, then the title+year fallback on a clean no-match. Returns `[]` with no
    /// providers (the dormancy path). Each provider fails soft: a thrown error from one server is dropped
    /// (an AuthFailed additionally badges that server needs-reauth), so one bad server never sinks the rest.
    /// Mirrors the Apple `MediaServerCoordinator.find`.
    suspend fun find(detailId: String?, season: Int?, episode: Int?, title: String?, year: Int?): List<MediaServerHit> {
        val snapshot = providerState
        if (snapshot.providers.isEmpty()) return emptyList()
        // Off the main thread: library-sized `/Items` and `/allLeaves` responses are parsed here (the Apple
        // flowOn discipline: never decode a library-sized response on the main thread). Network itself
        // already hops to Dispatchers.IO inside IntegrationsHttp.
        return withContext(Dispatchers.Default) {
            val hits = coroutineScope {
                snapshot.providers.map { sp ->
                    async {
                        try {
                            var hit = if (!detailId.isNullOrEmpty()) {
                                sp.provider.findByImdb(detailId, season, episode)
                            } else {
                                null
                            }
                            if (hit == null && !title.isNullOrEmpty()) {
                                hit = sp.provider.findByTitle(title, year, season, episode)
                            }
                            hit
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: MediaServerProviderException.AuthFailed) {
                            markNeedsReauth(sp.id)
                            null
                        } catch (e: Exception) {
                            null // fail soft: a flaky/unreachable server never breaks the others
                        }
                    }
                }.awaitAll().filterNotNull()
            }
            val current = providerState
            fenceMediaServerHits(
                startGeneration = snapshot.generation,
                currentGeneration = current.generation,
                activeIds = current.activeIds,
                hits = hits,
            )
        }
    }

    /// Resolve the current title on the connected servers and map the hits to per-server direct-play source
    /// GROUPS ready to merge into the detail source list (one group per server, labelled with the server's
    /// display name so each row is badged by server). Dormant + fail-soft: `[]` with no server connected.
    suspend fun directPlayGroups(detailId: String?, season: Int?, episode: Int?, title: String?, year: Int?): List<StreamGroup> {
        if (!hasServers) return emptyList()
        return buildGroups(find(detailId, season, episode, title, year))
    }

    // MARK: - Hit -> source mapping (mirrors Apple MediaServerSource.buildGroups / synthetic)

    /// One [StreamGroup] per server. Each [StreamSource] carries the DIRECT stream URL as its id handle
    /// (`<url>#<name>#<desc>`), so the engine's existing resolve() plays it straight through (the URL is
    /// self-authenticating; no extra headers). [StreamSource.isMediaServer] tags it for the ranker's top tier.
    fun buildGroups(hits: List<MediaServerHit>): List<StreamGroup> {
        if (hits.isEmpty()) return emptyList()
        val order = mutableListOf<UUID>()
        val byServer = linkedMapOf<UUID, Pair<String, MutableList<StreamSource>>>()
        for (hit in hits) {
            val source = synthetic(hit)
            val entry = byServer.getOrPut(hit.serverId) {
                order.add(hit.serverId)
                (hit.serverName.ifEmpty { "My Server" }) to mutableListOf()
            }
            entry.second.add(source)
        }
        return order.mapNotNull { id ->
            val (name, streams) = byServer[id] ?: return@mapNotNull null
            if (streams.isEmpty()) null else StreamGroup(addon = name, streams = streams)
        }
    }

    private fun synthetic(hit: MediaServerHit): StreamSource {
        val descParts = buildList {
            add("Direct Play")
            hit.container?.takeIf { it.isNotEmpty() }?.let { add(it) }
            hit.sizeBytes?.let { add(byteSize(it)) }
        }
        // The file name carries remux/HDR/codec tags the ranker parses; the resolution feeds its quality
        // label. The URL is the id handle so resolve() extracts it verbatim.
        val title = hit.fileName?.takeIf { it.isNotEmpty() } ?: hit.name
        val quality = hit.resolution?.let { "${it}p" }
        return StreamSource(
            id = "${hit.streamUrl}#${hit.serverName}#${title}",
            addon = hit.serverName.ifEmpty { "My Server" },
            title = title,
            description = descParts.joinToString(" · "),
            quality = quality,
            isTorrent = false,
            isMediaServer = true,
            // Apple's synthetic media-server stream carries the direct link in CoreStream.url, and the
            // ranker's isCached shape test (`url != nil && infoHash == nil`) treats it instant (+8000
            // within the media-server tier). Carry it here too so the Android ranker scores the same.
            url = hit.streamUrl,
        )
    }

    private fun byteSize(bytes: Long): String {
        if (bytes <= 0) return ""
        // Locale.US so the decimal separator is always '.', matching StreamRanking's size regex (a comma
        // decimal in some locales would make the ranker + the size label miss the value).
        val gb = bytes / 1_073_741_824.0
        if (gb >= 1.0) return String.format(java.util.Locale.US, "%.1f GB", gb)
        val mb = bytes / 1_048_576.0
        return String.format(java.util.Locale.US, "%.0f MB", mb)
    }

    // MARK: - Providers (coordinator build)

    private fun rebuildProviders() {
        val store = tokenStore
        val next = records.mapNotNull { r ->
            val token = store?.confirmedString(tokenKey(r.id)).orEmpty()
            if (token.isEmpty()) return@mapNotNull null
            val base = r.urls.firstOrNull() ?: return@mapNotNull null
            val config = MediaServerConfig(
                kind = r.kind,
                baseUrl = base,
                apiKey = token,
                userId = r.userId,
                id = r.id,
                displayName = r.name,
                urls = r.urls,
            )
            val provider: MediaServerProvider = when (r.kind) {
                MediaServerKind.JELLYFIN, MediaServerKind.EMBY -> JellyfinProvider(config)
                MediaServerKind.PLEX -> PlexProvider(config, plexClientId)
            }
            config to ServerProvider(r.id, provider)
        }
        val generation = providerState.generation + 1L
        providerState = ProviderState(
            generation = generation,
            providers = next.map { it.second },
            activeIds = next.mapTo(linkedSetOf()) { it.second.id },
        )
        // Catalog callers need the same exact credential/config generation as playback lookup. Publish the
        // immutable snapshot before the boundary tick so collectors can never observe a new generation with
        // the old account's configs. Tokens remain process-memory only and never enter logs or plain prefs.
        catalogState = CatalogSnapshot(generation, next.map { it.first })
        _configurationBoundary.value = generation
    }

    private fun tokenKey(id: UUID): String = "vortx.mediaserver.$id.token"
    private fun addBackupKey(id: UUID): String = "vortx.mediaserver.$id.addRollback.previous"

    // MARK: - Persistence

    private fun encodeRecords(source: List<MediaServerRecord>): String {
        val arr = JSONArray()
        for (r in source) {
            val o = JSONObject()
                .put("id", r.id.toString())
                .put("name", r.name)
                .put("kind", r.kind.wire)
                .put("urls", JSONArray(r.urls))
                .put("userId", r.userId)
                .put("addedAt", r.addedAtMillis)
                .put("needsReauth", r.needsReauth)
            r.machineId?.let { o.put("machineId", it) }
            arr.put(o)
        }
        return arr.toString()
    }

    private fun confirmedMetadata(): MediaServerMetadataSnapshot? =
        (metadataState?.read() as? MediaServerMetadataRead.Available)?.snapshot

    private fun persistRepositoryState(next: MediaServerMetadataSnapshot): Boolean =
        metadataState?.publish(next) ?: false

    private fun writeMetadataSnapshot(
        prefs: SharedPreferences,
        snapshot: MediaServerMetadataSnapshot,
    ): Boolean =
        runCatching {
            prefs.edit()
                .putString(RECORDS_KEY, encodeRecords(snapshot.records))
                .putStringSet(
                    PENDING_REMOVALS_KEY,
                    snapshot.pendingRemovals.mapTo(linkedSetOf()) { it.toString() },
                )
                .putString(PENDING_ADDS_KEY, encodePendingAdds(snapshot.pendingAdds))
                .commit()
        }.getOrDefault(false)

    private fun readMetadataSnapshot(prefs: SharedPreferences): MediaServerMetadataRead =
        try {
            val records = prefs.getString(RECORDS_KEY, null)
                ?.let(::decodeRecords)
                ?: if (prefs.contains(RECORDS_KEY)) {
                    return MediaServerMetadataRead.Unavailable
                } else {
                    emptyList()
                }
            val pendingRemovals = linkedSetOf<UUID>()
            for (value in prefs.getStringSet(PENDING_REMOVALS_KEY, emptySet()).orEmpty()) {
                val id = runCatching { UUID.fromString(value) }.getOrNull()
                    ?: return MediaServerMetadataRead.Unavailable
                pendingRemovals += id
            }
            val pendingAdds = prefs.getString(PENDING_ADDS_KEY, null)
                ?.let(::decodePendingAdds)
                ?: if (prefs.contains(PENDING_ADDS_KEY)) {
                    return MediaServerMetadataRead.Unavailable
                } else {
                    emptyList()
                }
            MediaServerMetadataRead.Available(
                MediaServerMetadataSnapshot(
                    records = records,
                    pendingRemovals = pendingRemovals,
                    pendingAdds = pendingAdds,
                ),
            )
        } catch (_: Exception) {
            MediaServerMetadataRead.Unavailable
        }

    private fun decodeRecords(raw: String): List<MediaServerRecord>? {
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return null
        val decoded = ArrayList<MediaServerRecord>(array.length())
        for (index in 0 until array.length()) {
            decoded += array.optJSONObject(index)?.let(::parseRecord) ?: return null
        }
        return decoded.sortedByDescending { it.addedAtMillis }
    }

    private fun encodePendingAdds(pending: List<MediaServerAddJournal>): String {
        val array = JSONArray()
        pending.forEach { journal ->
            array.put(
                JSONObject()
                    .put("serverId", journal.serverId.toString())
                    .put("disposition", journal.disposition.wire),
            )
        }
        return array.toString()
    }

    private fun decodePendingAdds(raw: String): List<MediaServerAddJournal>? {
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return null
        val decoded = ArrayList<MediaServerAddJournal>(array.length())
        val ids = hashSetOf<UUID>()
        for (index in 0 until array.length()) {
            val obj = array.optJSONObject(index) ?: return null
            val id = runCatching { UUID.fromString(obj.optString("serverId")) }.getOrNull()
                ?: return null
            val disposition = MediaServerAddDisposition.fromWire(obj.optString("disposition"))
                ?: return null
            if (!ids.add(id)) return null
            decoded += MediaServerAddJournal(id, disposition)
        }
        return decoded
    }

    private fun parseRecord(o: JSONObject): MediaServerRecord? {
        val id = runCatching { UUID.fromString(o.optString("id")) }.getOrNull() ?: return null
        val kind = MediaServerKind.fromWire(o.optString("kind")) ?: return null
        val urlsArr = o.optJSONArray("urls") ?: JSONArray()
        val urls = (0 until urlsArr.length()).mapNotNull { urlsArr.optString(it).takeIf { s -> s.isNotEmpty() } }
        if (urls.isEmpty()) return null
        return MediaServerRecord(
            id = id,
            name = o.optString("name").takeIf { it.isNotEmpty() } ?: kind.label,
            kind = kind,
            urls = urls,
            userId = o.optString("userId"),
            machineId = o.optString("machineId").takeIf { it.isNotEmpty() },
            addedAtMillis = o.optLong("addedAt", System.currentTimeMillis()),
            needsReauth = o.optBoolean("needsReauth", false),
        )
    }
}

internal fun fenceMediaServerHits(
    startGeneration: Long,
    currentGeneration: Long,
    activeIds: Set<UUID>,
    hits: List<MediaServerHit>,
): List<MediaServerHit> {
    if (startGeneration != currentGeneration) return emptyList()
    return hits.filter { it.serverId in activeIds }
}

internal fun resumeMediaServerRemovals(
    pendingIds: Set<UUID>,
    activeIds: Set<UUID>,
    clearCredential: (UUID) -> Boolean,
    publishPending: (Set<UUID>) -> Boolean,
): Set<UUID> {
    var remaining = pendingIds
    for (id in pendingIds) {
        if (id in activeIds || !clearCredential(id)) continue
        val next = remaining - id
        if (publishPending(next)) remaining = next
    }
    return remaining
}

enum class MediaServerRemovalResult {
    REMOVED,
    UNCHANGED,
    CLEANUP_PENDING,
}

internal fun completeMediaServerRemoval(
    publishRemoval: () -> Boolean,
    clearCredential: () -> Boolean,
    finishCleanup: () -> Boolean,
): MediaServerRemovalResult {
    if (!publishRemoval()) return MediaServerRemovalResult.UNCHANGED
    if (!clearCredential()) return MediaServerRemovalResult.CLEANUP_PENDING
    if (!finishCleanup()) return MediaServerRemovalResult.CLEANUP_PENDING
    return MediaServerRemovalResult.REMOVED
}
