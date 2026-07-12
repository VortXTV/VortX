package com.vortx.android.engine

import org.json.JSONArray
import org.json.JSONObject

/// Builders for the engine's JSON action payloads. These mirror the exact shapes the Apple
/// `CoreBridge` dispatches (the engine contract is identical across platforms), so behavior matches
/// the reference apps. Every builder returns a `{ "field": <name>, "action": <Action> }` string ready
/// for [StremioCoreNative.dispatch].
///
/// Field names and action tags come straight from stremio-core's `RuntimeAction` / `Action` serde
/// enums (snake_case fields, PascalCase action tags). Building them with `org.json` (bundled in the
/// Android SDK, zero extra dependencies) guarantees valid escaping.
object EngineActions {

    const val FIELD_BOARD = "board"
    const val FIELD_SEARCH = "search"
    const val FIELD_DISCOVER = "discover"
    const val FIELD_LIBRARY = "library"
    const val FIELD_META_DETAILS = "meta_details"
    const val FIELD_CTX = "ctx"
    const val FIELD_CONTINUE_WATCHING_PREVIEW = "continue_watching_preview"

    /// Load the Home board (every catalog of every installed add-on). Mirrors CoreBridge.loadBoard.
    fun loadBoard(): String =
        envelope(FIELD_BOARD, action("Load", JSONObject().put("model", "CatalogsWithExtra").put("args", JSONObject.NULL)))

    /// Load the first [rows] rows of the board (the engine paginates rows via LoadRange).
    fun loadBoardRange(rows: Int): String =
        envelope(
            FIELD_BOARD,
            action(
                "CatalogsWithExtra",
                JSONObject().put("action", "LoadRange").put("args", JSONObject().put("start", 0).put("end", rows)),
            ),
        )

    /// Load Discover for a media type (movie/series/...). `args.request` is null to take the add-on
    /// default catalog for the type; the engine selects the first matching catalog.
    fun loadDiscover(): String =
        envelope(FIELD_DISCOVER, action("Load", JSONObject().put("model", "CatalogWithFilters").put("args", JSONObject.NULL)))

    /// Load the user's Library (NotRemoved filter).
    fun loadLibrary(): String =
        envelope(FIELD_LIBRARY, action("Load", JSONObject().put("model", "LibraryWithFilters").put("args", JSONObject.NULL)))

    /// Search across installed add-ons. Two-step like CoreBridge.search: Load the CatalogsWithExtra
    /// model with a `search` extra, then LoadRange to materialize results.
    fun searchLoad(query: String): String {
        val extra = JSONArray().put(JSONArray().put("search").put(query))
        val args = JSONObject().put("extra", extra)
        return envelope(FIELD_SEARCH, action("Load", JSONObject().put("model", "CatalogsWithExtra").put("args", args)))
    }

    fun searchRange(rows: Int): String =
        envelope(
            FIELD_SEARCH,
            action(
                "CatalogsWithExtra",
                JSONObject().put("action", "LoadRange").put("args", JSONObject().put("start", 0).put("end", rows)),
            ),
        )

    /// Load a title's meta + a guessed best stream. For a series episode, pass [streamType]/[streamId]
    /// (the episode's video id) so the engine fetches that episode's streams. Mirrors CoreBridge.loadMeta.
    fun loadMeta(type: String, id: String, streamType: String? = null, streamId: String? = null): String {
        val metaPath = JSONObject()
            .put("resource", "meta")
            .put("type", type)
            .put("id", id)
            .put("extra", JSONArray())
        val args = JSONObject()
            .put("metaPath", metaPath)
            .put("guessStream", true)
        if (streamType != null && streamId != null) {
            args.put(
                "streamPath",
                JSONObject().put("resource", "stream").put("type", streamType).put("id", streamId).put("extra", JSONArray()),
            )
        } else {
            args.put("streamPath", JSONObject.NULL)
        }
        return envelope(FIELD_META_DETAILS, action("Load", JSONObject().put("model", "MetaDetails").put("args", args)))
    }

    /// Unload meta details (clears the engine's MetaDetails model when leaving the detail screen).
    fun unloadMeta(): String = envelope(FIELD_META_DETAILS, action("Unload", null))

    /// The state field-selector for `continue_watching_preview`, ready for [StremioCoreNative.getState].
    /// Continue Watching is DERIVED state the engine populates from the hydrated library/ctx at
    /// construction; it emits no `NewState` of its own (mirrors Apple `CoreBridge.seedInitialState`,
    /// which reads the field directly rather than dispatching a load). So there is no "load CW" action:
    /// the repository reads this field straight, after the board load has already pumped the event loop.
    fun continueWatchingPreviewField(): String = "\"$FIELD_CONTINUE_WATCHING_PREVIEW\""

    // ---- low-level builders ----

    /// `{ "action": <tag>, "args": <args> }`. `args == null` omits the key (for arg-less actions).
    private fun action(tag: String, args: Any?): JSONObject {
        val obj = JSONObject().put("action", tag)
        if (args != null) obj.put("args", args)
        return obj
    }

    /// `{ "field": <field>, "action": <action> }` serialized to a string.
    private fun envelope(field: String, action: JSONObject): String =
        JSONObject().put("field", field).put("action", action).toString()
}
