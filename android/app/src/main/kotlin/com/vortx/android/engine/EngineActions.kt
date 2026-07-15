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
    const val FIELD_PLAYER = "player"

    /// Load the Home board (every catalog of every installed add-on). Mirrors CoreBridge.loadBoard.
    ///
    /// stremio-core's `ActionLoad::CatalogsWithExtra` carries a REQUIRED `Selected { type, extra }`
    /// struct (unlike `ActionLoad::CatalogWithFilters`, which wraps an `Option<..>` and tolerates
    /// `args: null` for "use the default"). Sending `args: null` here fails to deserialize the whole
    /// action envelope -- serde rejects it before dispatch ever sees a field/action pair, so the
    /// engine silently drops it: no NewState, no error, nothing. That was the entire bug: the board
    /// Load was never reaching a handler. Mirror Apple's `["type": NSNull(), "extra": []]` exactly.
    fun loadBoard(): String =
        envelope(
            FIELD_BOARD,
            action(
                "Load",
                JSONObject().put("model", "CatalogsWithExtra").put(
                    "args",
                    JSONObject().put("type", JSONObject.NULL).put("extra", JSONArray()),
                ),
            ),
        )

    /// Load the first [rows] rows of the board (the engine paginates rows via LoadRange).
    fun loadBoardRange(rows: Int): String =
        envelope(
            FIELD_BOARD,
            action(
                "CatalogsWithExtra",
                JSONObject().put("action", "LoadRange").put("args", JSONObject().put("start", 0).put("end", rows)),
            ),
        )

    /// Load Discover's default catalog (the engine picks the first selectable type). Mirrors Apple
    /// `CoreBridge.loadDiscover`: `args.request` is null so the engine falls back to its own default
    /// selection rather than a client-guessed one.
    fun loadDiscover(): String =
        envelope(FIELD_DISCOVER, action("Load", JSONObject().put("model", "CatalogWithFilters").put("args", JSONObject.NULL)))

    // ---- S04: Discover type/catalog/genre pivots + pagination ----

    /// Pivot Discover to a specific type/catalog/genre selection. [requestJson] MUST be the exact
    /// `request` object the engine handed back on a `DiscoverTypeOption`/`DiscoverCatalogOption`/
    /// `DiscoverGenreOption` (see [EngineState.parseDiscoverFilters]) — mirrors Apple
    /// `CoreBridge.selectDiscover(_ request: CoreRequest)`, which re-dispatches the chip's own request
    /// verbatim rather than reconstructing one client-side. THIS is the fix for the "type chips are
    /// inert" bug: [loadDiscover] never carried a type/catalog at all, so tapping a chip never actually
    /// changed the dispatched request.
    fun loadDiscoverSelect(requestJson: String): String =
        envelope(
            FIELD_DISCOVER,
            action(
                "Load",
                JSONObject().put("model", "CatalogWithFilters").put("args", JSONObject().put("request", JSONObject(requestJson))),
            ),
        )

    /// Load the next page of the current Discover catalog (infinite scroll / "Load more"). Mirrors
    /// Apple `CoreBridge.loadDiscoverNextPage`: a no-op at the engine level when there is no next page.
    fun loadDiscoverNextPage(): String =
        envelope(FIELD_DISCOVER, action("CatalogWithFilters", JSONObject().put("action", "LoadNextPage")))

    /// Load the user's Library (NotRemoved filter). `LibraryWithFilters`'s `Selected` (like the board's)
    /// is a REQUIRED struct (`{ request: { type, sort, page } }`), not an `Option`; mirrors Apple's
    /// `loadLibrary` exactly rather than the `args: null` shorthand that only ActionLoad variants
    /// wrapping an `Option<..>` (e.g. CatalogWithFilters/discover) tolerate.
    fun loadLibrary(): String =
        envelope(
            FIELD_LIBRARY,
            action(
                "Load",
                JSONObject().put("model", "LibraryWithFilters").put(
                    "args",
                    JSONObject().put(
                        "request",
                        JSONObject().put("type", JSONObject.NULL).put("sort", "lastwatched").put("page", 1),
                    ),
                ),
            ),
        )

    // ---- S04: Library type/sort pivots + ctx library mutations ----

    /// Pivot the Library to a specific type/sort selection. [requestJson] MUST be the exact `request`
    /// object the engine handed back on a `LibraryTypeOption`/`LibrarySortOption` (see
    /// [EngineState.parseLibraryFilters]) — mirrors Apple `CoreBridge.selectLibrary(_
    /// request: CoreLibraryRequest)`.
    fun loadLibrarySelect(requestJson: String): String =
        envelope(
            FIELD_LIBRARY,
            action(
                "Load",
                JSONObject().put("model", "LibraryWithFilters").put("args", JSONObject().put("request", JSONObject(requestJson))),
            ),
        )

    /// Save a title to the Library (`ActionCtx::AddToLibrary(MetaItemPreview)`). Only `id`/`type`/`name`
    /// are required by the engine's `MetaItemPreview` deserializer (every other field defaults) — see
    /// stremio-core's own doctest for the identical minimal-fields shape. Broadcasts (field = null): it
    /// touches `ctx.library`, and `library`/`continue_watching_preview` re-derive from it.
    fun addToLibrary(id: String, type: String, name: String, poster: String?): String {
        val preview = JSONObject().put("id", id).put("type", type).put("name", name)
        if (poster != null) preview.put("poster", poster)
        return ctxEnvelope(action("AddToLibrary", preview))
    }

    /// Remove a title from the Library (`ActionCtx::RemoveFromLibrary(String)` — a bare id, not an
    /// object). Broadcasts for the same reason as [addToLibrary].
    fun removeFromLibrary(id: String): String = ctxEnvelope(action("RemoveFromLibrary", id))

    // ---- S04: add-on management (ctx.profile.addons) ----

    /// Install (or, for an already-installed `transportUrl`, update-in-place — the engine's
    /// `InstallAddon` reducer upserts by `transportUrl`, see stremio-core `update_profile.rs`) an
    /// add-on from its already-fetched manifest. [manifestJson] is the raw `manifest.json` body; the
    /// caller (repository layer) is responsible for fetching + validating it first (mirrors Apple
    /// `CoreBridge.installAddon`, which fetches client-side because the engine has no HTTP-fetch action
    /// for a bare URL). `flags.official`/`flags.protected` are always false for a user-installed add-on.
    fun installAddon(transportUrl: String, manifestJson: JSONObject): String {
        val descriptor = JSONObject()
            .put("transportUrl", transportUrl)
            .put("manifest", manifestJson)
            .put("flags", JSONObject().put("official", false).put("protected", false))
        return ctxEnvelope(action("InstallAddon", descriptor))
    }

    /// Uninstall an add-on. `UninstallAddon` takes a full `Descriptor`, so [rawDescriptorJson] MUST be
    /// the exact entry the engine returned in `ctx.profile.addons` (see
    /// [EngineState.parseInstalledAddons]'s `rawDescriptorJson`), not a reconstruction -- mirrors Apple
    /// `CoreBridge.uninstallAddon`, which sends back its own cached raw descriptor for the same reason.
    fun uninstallAddon(rawDescriptorJson: String): String = ctxEnvelope(action("UninstallAddon", JSONObject(rawDescriptorJson)))

    /// Search across installed add-ons. Two-step like CoreBridge.search: Load the CatalogsWithExtra
    /// model with a `search` extra, then LoadRange to materialize results. `Selected.type` has no
    /// serde default (see [loadBoard]), so it must be sent explicitly even though it's `Option<String>`.
    fun searchLoad(query: String): String {
        val extra = JSONArray().put(JSONArray().put("search").put(query))
        val args = JSONObject().put("type", JSONObject.NULL).put("extra", extra)
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

    /// The state field-selector for `ctx`, ready for [StremioCoreNative.getState]. `ctx` needs no Load
    /// action either: the engine hydrates `profile` (incl. a persisted sign-in) at construction, and
    /// every `ActionCtx` mutation below re-emits it via the whole-model dispatch path.
    fun ctxField(): String = "\"$FIELD_CTX\""

    /// The state field-selector for `board`, for direct snapshot reads (the continuous Home stream
    /// re-reads the board on every relevant NewState rather than one-shot loading it).
    fun boardField(): String = "\"$FIELD_BOARD\""

    /// The state field-selector for `discover`, for a direct snapshot read (e.g. re-pulling filters
    /// without re-dispatching a Load).
    fun discoverField(): String = "\"$FIELD_DISCOVER\""

    /// The state field-selector for `library`, for a direct snapshot read.
    fun libraryField(): String = "\"$FIELD_LIBRARY\""

    /// Email/password sign-in, mirroring Apple `CoreBridge`'s `Authenticate`/`LoginWithToken` dispatch
    /// (here the `Login` variant of the engine's `AuthRequest`, the same request the account API
    /// login form makes on every Stremio client). Broadcasts to the whole model (field = null, like
    /// `dispatchCtx` on Apple): a successful login changes `ctx` (and, once addons/library pull in,
    /// several other fields), so no single field name is the right target.
    fun authenticateLogin(email: String, password: String): String =
        ctxEnvelope(
            action(
                "Authenticate",
                JSONObject()
                    .put("type", "Login")
                    .put("email", email)
                    .put("password", password)
                    .put("facebook", false),
            ),
        )

    /// Sign out. Destroys the engine's server-side session (mirrors Apple's plain `Logout`, used only
    /// for an explicit user sign-out, never for a profile switch) and clears `ctx.profile.auth`.
    fun logout(): String = ctxEnvelope(action("Logout", null))

    // ---- S05: Detail watched-state + library mutations ----
    //
    // Mirrors Apple `CoreBridge`'s `dispatchMetaDetails`/`dispatchCtx` exactly (verified against the
    // vendored stremio-core crate's `ActionMetaDetails`/`ActionCtx` enums, `runtime/msg/action.rs`):
    // whole-title and per-video/season watched toggles are `Action::MetaDetails(ActionMetaDetails::…)`,
    // dispatched with field = "meta_details" (NOT a Ctx broadcast -- only library add/remove is). Every
    // stremio-core `dispatch` runs the model update SYNCHRONOUSLY (see [EngineStremioRepository]'s class
    // doc), and `MetaDetails::update` recomputes `library_item` from `ctx.library` on EVERY dispatched
    // message (not just its own field's actions), so a `meta_details` field re-read immediately after any
    // of these -- including the Ctx-scoped library ones below -- already reflects the mutation with no
    // event wait required.

    /// The state field-selector for `meta_details`, for direct snapshot reads after a mutation below.
    fun metaDetailsField(): String = "\"$FIELD_META_DETAILS\""

    /// Mark the whole title watched/unwatched: a movie's only watched flag, or (for a series) the
    /// engine's own "every video" aggregate. Mirrors Apple `CoreBridge.markWatched`'s `true` branch;
    /// the false (unwatch-every-video) branch is [markVideoAsWatched] called per video by the caller,
    /// since `MarkAsWatched(false)` alone does not clear the per-video ticks (same engine quirk Apple's
    /// comment documents).
    fun markAsWatched(isWatched: Boolean): String =
        envelope(FIELD_META_DETAILS, action("MetaDetails", action("MarkAsWatched", isWatched)))

    /// Mark one episode watched/unwatched. `Video` only strictly needs `id`; season/episode are included
    /// when known (harmless extras, and match what Apple sends) but are not required by the engine's
    /// `Video` struct.
    fun markVideoAsWatched(videoId: String, season: Int?, episode: Int?, isWatched: Boolean): String {
        val video = JSONObject().put("id", videoId)
        if (season != null) video.put("season", season)
        if (episode != null) video.put("episode", episode)
        val args = JSONArray().put(video).put(isWatched)
        return envelope(FIELD_META_DETAILS, action("MetaDetails", action("MarkVideoAsWatched", args)))
    }

    /// Mark every video of one season watched/unwatched.
    fun markSeasonAsWatched(season: Int, isWatched: Boolean): String {
        val args = JSONArray().put(season).put(isWatched)
        return envelope(FIELD_META_DETAILS, action("MetaDetails", action("MarkSeasonAsWatched", args)))
    }

    // ---- Live playback progress (engine Player) ----
    //
    // Mirrors Apple `CoreBridge`'s Player lifecycle (`loadEnginePlayer` / `reportProgress` /
    // `unloadEnginePlayer`, app/SourcesShared/CoreBridge.swift): Load the `player` model with the picked
    // stream + its requests so the engine attributes progress to the right library item, then dispatch
    // `TimeChanged` ticks (positions in ms) so `continue_watching_preview` updates live, then `Unload` on
    // close so a stale Player can't absorb the next title's ticks. All dispatched with field = "player".

    /// Load the engine `player` model for the picked stream. [selected] is the engine's `Player` selected
    /// struct (`{ stream, streamRequest, metaRequest, subtitlesPath }`), assembled by the repository from
    /// the resident `meta_details` (see [EngineStremioRepository.beginPlaybackSession]). The library item
    /// keys on the META, not the specific stream, so any Ready stream + this title's requests attributes
    /// correctly, matching Apple `loadEnginePlayer`'s fallback path.
    fun loadPlayer(selected: JSONObject): String =
        envelope(FIELD_PLAYER, action("Load", JSONObject().put("model", "Player").put("args", selected)))

    /// Report the playback position to the engine Player (both values in MS), so Continue Watching
    /// reflects it live. Mirrors Apple `reportProgress`'s `Player -> TimeChanged` dispatch.
    fun playerTimeChanged(timeMs: Long, durationMs: Long, device: String): String {
        val payload = JSONObject().put("time", timeMs).put("duration", durationMs).put("device", device)
        return envelope(FIELD_PLAYER, action("Player", action("TimeChanged", payload)))
    }

    /// Tear down the engine Player. Mirrors Apple `unloadEnginePlayer`.
    fun unloadPlayer(): String = envelope(FIELD_PLAYER, action("Unload", null))

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

    /// `{ "field": null, "action": { "action": "Ctx", "args": <ctxAction> } }` -- an `Action::Ctx(...)`
    /// dispatched with a null field, i.e. broadcast to the WHOLE model rather than one field. Mirrors
    /// Apple `CoreBridge.dispatchCtx`, which does the same for every `ActionCtx` (auth, library
    /// mutations, add-on install/remove): those actions can touch more than one model field, so there
    /// is no single field name to scope them to.
    private fun ctxEnvelope(ctxAction: JSONObject): String =
        JSONObject().put("field", JSONObject.NULL).put("action", action("Ctx", ctxAction)).toString()
}
