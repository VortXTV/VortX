package com.vortx.android.engine

import android.content.Context
import com.vortx.android.data.CatalogRepository
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridResolver
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import android.util.Log
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
/// Threading: [StremioCoreNative.EventListener.onEvent] fires on a native worker thread; we forward the
/// changed field names into a [MutableSharedFlow] that suspend functions await. Parsing runs on the
/// caller's coroutine.
class EngineStremioRepository(
    context: Context,
    /// How long to wait for a field's NewState before falling back to the current state. The engine is
    /// local except for add-on HTTP, so a few seconds covers a cold add-on fan-out.
    private val loadTimeoutSeconds: Long = 12,
) : CatalogRepository {

    private val appContext = context.applicationContext

    /// Native in-client debrid resolver: turns a raw-torrent infoHash into a DIRECT, playable HTTPS URL
    /// through the user's own debrid account (keys in EncryptedSharedPreferences). Built lazily so no
    /// key store is opened until a torrent is actually resolved; with no key configured it is a no-op
    /// and torrents keep today's behavior (a clear error the player layer surfaces).
    private val debridResolver by lazy { DebridResolver(DebridKeys(appContext)) }

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
    ///
    /// Fail-soft: if the native library failed to load or init throws (e.g. a missing/incompatible
    /// `libstremiox_core.so`), we log and leave [started] false. Every dispatch/getState below is then
    /// a no-op that yields the engine's `"null"` sentinel, so the parsers return empty state and the UI
    /// renders an empty (not crashed) screen. The boundary must never take down the whole app.
    @Synchronized
    private fun start() {
        if (started) return
        val storageDir = appContext.filesDir.absolutePath
        val cacheDir = appContext.cacheDir.absolutePath
        started = runCatching {
            StremioCoreNative.init(storageDir, cacheDir) { json -> onEngineEvent(json) }
        }.getOrElse { error ->
            Log.e(TAG, "stremio-core init failed; UI will render empty until the engine is available", error)
            false
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
            StremioCoreNative.dispatch(actionJson)
            changedFields.first { field in it }
        }
        // Whether the event arrived or we timed out, pull the latest state for the field.
        if (awaited == null) {
            // No event: the engine likely had it cached (ActionLoad was a no-op). Current state is best.
        }
        return StremioCoreNative.getState("\"$field\"")
    }

    override suspend fun home(): Result<List<Catalog>> = runCatching {
        StremioCoreNative.dispatch(EngineActions.loadBoard())
        val state = loadField(EngineActions.FIELD_BOARD, EngineActions.loadBoardRange(DEFAULT_BOARD_ROWS))
        val boardRows = EngineState.parseCatalogs(state)
        // Prepend Continue Watching, the leading Home rail on iOS/tvOS. It is DERIVED state the engine
        // hydrated from the library at construction (it emits no NewState of its own, mirroring Apple
        // CoreBridge.seedInitialState), so we read the field straight rather than dispatching a load.
        // The board load above has already pumped the event loop, so the field is populated by now.
        // Fail-soft: an empty CW list simply yields no row, never an error, so Home still renders the
        // add-on rails on a fresh (never-watched) account.
        val continueWatching = runCatching {
            EngineState.parseContinueWatching(StremioCoreNative.getState(EngineActions.continueWatchingPreviewField()))
        }.getOrDefault(emptyList())
        if (continueWatching.isEmpty()) {
            boardRows
        } else {
            // id = "continue" is the contract HomeScreen keys its editorial eyebrow off of.
            listOf(Catalog(id = "continue", title = "Continue Watching", items = continueWatching)) + boardRows
        }
    }

    override suspend fun discover(type: MediaType): Result<List<Catalog>> = runCatching {
        val state = loadField(EngineActions.FIELD_DISCOVER, EngineActions.loadDiscover())
        // Discover is one selectable rail in the engine (a CatalogWithFilters: the selected catalog's
        // flat pages, not the board's list-of-rails). parseCatalogWithFilters decodes that single rail
        // into a one-row catalog list so the UI's row-based Discover screen renders without special-
        // casing. Fail-soft: any miss (engine unavailable, still-loading, empty) yields an empty list.
        EngineState.parseCatalogWithFilters(state)
    }

    override suspend fun library(): Result<List<MetaItem>> = runCatching {
        val state = loadField(EngineActions.FIELD_LIBRARY, EngineActions.loadLibrary())
        EngineState.parseLibrary(state)
    }

    override suspend fun search(query: String): Result<List<MetaItem>> = runCatching {
        if (query.isBlank()) return@runCatching emptyList()
        StremioCoreNative.dispatch(EngineActions.searchLoad(query))
        val state = loadField(EngineActions.FIELD_SEARCH, EngineActions.searchRange(DEFAULT_SEARCH_ROWS))
        // search is a CatalogsWithExtra (rails); flatten the rails to a flat result list for the UI.
        EngineState.parseCatalogs(state).flatMap { it.items }
    }

    override suspend fun meta(type: MediaType, id: String): Result<MetaDetail> = runCatching {
        val state = loadField(EngineActions.FIELD_META_DETAILS, EngineActions.loadMeta(type.id, id))
        EngineState.parseMetaDetail(state)
            ?: throw IllegalStateException("meta_details not ready for $id")
    }

    override suspend fun streams(type: MediaType, id: String, episodeId: String?): Result<List<StreamGroup>> = runCatching {
        // Meta + a guessed stream were already requested by meta(); re-pull meta_details for its
        // stream groups. If meta() was not called first, this Load brings both in.
        //
        // For a series with a chosen [episodeId], pass a streamPath so the engine fetches THAT episode's
        // streams (the engine stream resource type is the meta type, its id is the episode's video id);
        // otherwise (movie, or no episode chosen yet) leave the streamPath null and take the guessed set.
        val action = if (episodeId != null) {
            EngineActions.loadMeta(type.id, id, streamType = type.id, streamId = episodeId)
        } else {
            EngineActions.loadMeta(type.id, id)
        }
        val state = loadField(EngineActions.FIELD_META_DETAILS, action)
        EngineState.parseStreamGroups(state)
    }

    override suspend fun resolve(source: StreamSource): Result<Playable> = runCatching {
        // A stream id encodes its handle (see EngineState.parseStream: id = handle#name#desc, handle is
        // url/externalUrl/infoHash). Direct URLs are playable as-is. A raw torrent (handle = infoHash)
        // resolves through the user's own debrid account when a key is configured (native in-client
        // debrid, the Android port of the Apple DebridResolver); without a key it still needs the
        // in-process streaming server (nodejs-mobile, not yet wired), so it surfaces a clear error the
        // player layer can show instead of failing opaquely.
        val handle = source.id.substringBefore('#')
        if (!source.isTorrent && (handle.startsWith("http://") || handle.startsWith("https://"))) {
            Playable(url = handle, title = source.title, viaStreamingServer = false)
        } else if (source.isTorrent) {
            // Raw torrent: the handle IS the infoHash (see EngineState.parseStream: for a torrent
            // url == null, so the id-handle is the infoHash). If the user has a debrid key configured,
            // resolve it to a DIRECT, cached-instant HTTPS link through their own account (the Android
            // port of the Apple DebridResolver). The resolved URL is a plain direct stream, NOT a
            // torrent, so it plays without the streaming-server bridge (viaStreamingServer = false).
            //
            // Fail-soft: DebridResolver.resolve returns null on ANY failure (no key, not actually
            // cached, no playable file, provider/network error). With no key it never opens the key
            // store. On null we surface the SAME clear error as before so the player layer shows a real
            // message rather than failing opaquely, and torrents keep today's behavior when no debrid
            // is configured.
            val resolved = debridResolver.resolve(infoHash = handle)
            if (resolved != null) {
                Playable(url = resolved, title = source.title, viaStreamingServer = false, isTorrent = false)
            } else {
                throw UnsupportedOperationException(
                    "Torrent playback needs a debrid key or the streaming-server bridge (not yet wired on Android).",
                )
            }
        } else {
            throw UnsupportedOperationException(
                "This source type is not playable on Android yet.",
            )
        }
    }

    private companion object {
        // Match CoreBridge's initial board fetch and search range so behavior tracks the reference app.
        const val DEFAULT_BOARD_ROWS = 12
        const val DEFAULT_SEARCH_ROWS = 30
        const val TAG = "StremioXEngine"
    }
}
