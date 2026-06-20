package com.stremiox.android.engine

import android.content.Context
import com.stremiox.android.data.CatalogRepository
import com.stremiox.android.model.Catalog
import com.stremiox.android.model.MediaType
import com.stremiox.android.model.MetaDetail
import com.stremiox.android.model.MetaItem
import com.stremiox.android.model.Playable
import com.stremiox.android.model.StreamGroup
import com.stremiox.android.model.StreamSource
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import kotlin.time.Duration.Companion.seconds

/// The real engine implementation of the UI seam. Drop-in replacement for `PreviewCatalogRepository`:
/// it satisfies the SAME [CatalogRepository] (alias `StremioRepository`) contract the Compose screens
/// were built against, so wiring it in is a one-line change at the injection site (the ViewModelFactory)
/// with zero UI churn.
///
/// How it bridges the request/response gap: stremio-core is event-driven, not request/response. Each
/// repository call (a) dispatches the matching Load action, (b) suspends until the engine emits a
/// `NewState` event naming the field it drives, then (c) pulls + parses that field's JSON. A timeout
/// guards against a field that never re-emits (e.g. the engine had it cached and ActionLoad was a
/// no-op), in which case we read whatever state is currently present.
///
/// Threading: [StremioXCore.EventListener.onEvent] fires on a native worker thread; we forward the
/// changed field names into a [MutableSharedFlow] that suspend functions await. Parsing runs on the
/// caller's coroutine.
class EngineStremioRepository(
    context: Context,
    /// How long to wait for a field's NewState before falling back to the current state. The engine is
    /// local except for add-on HTTP, so a few seconds covers a cold add-on fan-out.
    private val loadTimeoutSeconds: Long = 12,
) : CatalogRepository {

    private val appContext = context.applicationContext

    /// Field names that changed in the most recent engine event. extraBufferCapacity keeps fast
    /// back-to-back events from being dropped while a collector is between emissions.
    private val changedFields = MutableSharedFlow<Set<String>>(extraBufferCapacity = 16)

    @Volatile
    private var started = false

    init {
        start()
    }

    /// Initialize the engine once. Idempotent; safe to call from multiple repositories (the native
    /// side is also idempotent). Storage goes to the durable filesDir, the HTTP cache to cacheDir.
    @Synchronized
    private fun start() {
        if (started) return
        val storageDir = appContext.filesDir.absolutePath
        val cacheDir = appContext.cacheDir.absolutePath
        started = StremioXCore.init(storageDir, cacheDir) { json ->
            onEngineEvent(json)
        }
    }

    /// Decode a `RuntimeEvent` and, if it is a NewState, publish the changed field names. NewState's
    /// args are the field names that changed, e.g. `{"name":"NewState","args":["board","ctx"]}`.
    private fun onEngineEvent(json: ByteArray) {
        val event = runCatching { JSONObject(String(json, Charsets.UTF_8)) }.getOrNull() ?: return
        if (event.optString("name") != "NewState") return
        val args = event.optJSONArray("args") ?: return
        val fields = buildSet {
            for (i in 0 until args.length()) {
                val field = args.optString(i)
                if (field.isNotEmpty()) add(field)
            }
        }
        if (fields.isNotEmpty()) changedFields.tryEmit(fields)
    }

    /// Dispatch [actionJson], then await a NewState naming [field] (up to [loadTimeoutSeconds]), then
    /// return the field's current JSON. If no event arrives in time, returns the current state anyway
    /// (covers the cached no-op-load case). Returns [field]'s JSON, never null ("null" on error).
    private suspend fun loadField(field: String, actionJson: String): String {
        val awaited = withTimeoutOrNull(loadTimeoutSeconds.seconds) {
            // Subscribe first conceptually: dispatch then await. A buffered SharedFlow plus the small
            // network latency of add-on calls means the emission lands after our await begins.
            StremioXCore.dispatch(actionJson)
            changedFields.first { field in it }
        }
        // Whether the event arrived or we timed out, pull the latest state for the field.
        if (awaited == null) {
            // No event: the engine likely had it cached (ActionLoad was a no-op). Current state is best.
        }
        return StremioXCore.getState("\"$field\"")
    }

    override suspend fun home(): Result<List<Catalog>> = runCatching {
        StremioXCore.dispatch(EngineActions.loadBoard())
        val state = loadField(EngineActions.FIELD_BOARD, EngineActions.loadBoardRange(DEFAULT_BOARD_ROWS))
        EngineState.parseCatalogs(state)
    }

    override suspend fun discover(type: MediaType): Result<List<Catalog>> = runCatching {
        val state = loadField(EngineActions.FIELD_DISCOVER, EngineActions.loadDiscover())
        // Discover is one filtered rail in the engine; surface it as a single-row catalog list so the
        // UI's row-based Discover screen renders without special-casing.
        EngineState.parseCatalogs(state).ifEmpty {
            // CatalogWithFilters serializes differently from CatalogsWithExtra (a single rail, not a
            // list of rails); a future iteration adds a dedicated parser. For now the typed request is
            // dispatched and the UI degrades to empty rather than crashing.
            emptyList()
        }
    }

    override suspend fun library(): Result<List<MetaItem>> = runCatching {
        val state = loadField(EngineActions.FIELD_LIBRARY, EngineActions.loadLibrary())
        EngineState.parseLibrary(state)
    }

    override suspend fun search(query: String): Result<List<MetaItem>> = runCatching {
        if (query.isBlank()) return@runCatching emptyList()
        StremioXCore.dispatch(EngineActions.searchLoad(query))
        val state = loadField(EngineActions.FIELD_SEARCH, EngineActions.searchRange(DEFAULT_SEARCH_ROWS))
        // search is a CatalogsWithExtra (rails); flatten the rails to a flat result list for the UI.
        EngineState.parseCatalogs(state).flatMap { it.items }
    }

    override suspend fun meta(type: MediaType, id: String): Result<MetaDetail> = runCatching {
        val state = loadField(EngineActions.FIELD_META_DETAILS, EngineActions.loadMeta(type.id, id))
        EngineState.parseMetaDetail(state)
            ?: throw IllegalStateException("meta_details not ready for $id")
    }

    override suspend fun streams(type: MediaType, id: String): Result<List<StreamGroup>> = runCatching {
        // Meta + a guessed stream were already requested by meta(); re-pull meta_details for its
        // stream groups. If meta() was not called first, this Load brings both in.
        val state = loadField(EngineActions.FIELD_META_DETAILS, EngineActions.loadMeta(type.id, id))
        EngineState.parseStreamGroups(state)
    }

    override suspend fun resolve(source: StreamSource): Result<Playable> = runCatching {
        // STUB pending the streaming-server bridge. A direct stream id encodes its URL (see
        // EngineState.parseStream: id = handle#name#desc, handle is url/externalUrl/infoHash). Direct
        // URLs are playable as-is; torrents need the in-process streaming server (nodejs-mobile on
        // Android, not yet wired) to turn an infoHash into a local HLS URL. Until that lands, hand back
        // the direct URL when present and surface a clear error for torrents so the player layer can
        // show a real message instead of failing opaquely.
        val handle = source.id.substringBefore('#')
        if (!source.isTorrent && (handle.startsWith("http://") || handle.startsWith("https://"))) {
            Playable(url = handle, title = source.title, viaStreamingServer = false)
        } else {
            throw UnsupportedOperationException(
                "Torrent/debrid resolution needs the streaming-server bridge, not yet wired on Android.",
            )
        }
    }

    private companion object {
        // Match CoreBridge's initial board fetch and search range so behavior tracks the reference app.
        const val DEFAULT_BOARD_ROWS = 12
        const val DEFAULT_SEARCH_ROWS = 30
    }
}
