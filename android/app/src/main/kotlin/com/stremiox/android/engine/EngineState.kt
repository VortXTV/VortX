package com.stremiox.android.engine

import com.stremiox.android.model.AuthState
import com.stremiox.android.model.Catalog
import com.stremiox.android.model.DiscoverCatalogOption
import com.stremiox.android.model.DiscoverFilters
import com.stremiox.android.model.DiscoverGenreOption
import com.stremiox.android.model.DiscoverTypeOption
import com.stremiox.android.model.Episode
import com.stremiox.android.model.InstalledAddon
import com.stremiox.android.model.LibraryFilters
import com.stremiox.android.model.LibraryItemInfo
import com.stremiox.android.model.LibrarySortOption
import com.stremiox.android.model.LibraryTypeOption
import com.stremiox.android.model.MediaType
import com.stremiox.android.model.MetaDetail
import com.stremiox.android.model.MetaItem
import com.stremiox.android.model.StreamGroup
import com.stremiox.android.model.StreamSource
import org.json.JSONArray
import org.json.JSONObject

/// Decoders that turn the engine's JSON state (as returned by [StremioXCore.getState]) into the
/// Android domain models the Compose UI renders. The shapes mirror the Apple `CoreModels` Codable
/// structs exactly (same serde output): `_id`, `posterShape`, snake_case nested keys, and the
/// `Loadable` wrapper `{ "type": "Ready", "content": ... }`.
///
/// All parsing is defensive: malformed or missing fields degrade to empty/null rather than throwing,
/// because engine state can be mid-load (a `Loading` Loadable) when a field is pulled.
internal object EngineState {

    /// Parse the `board`/`search` field (a `CatalogsWithExtra`) into UI [Catalog] rows. Each catalog
    /// is `{ request, content: Loadable<[meta]> }`; the engine nests them as `catalogs: [[page]]`
    /// (outer = catalog, inner = pages). We flatten pages and title each row from [titleMap] (the
    /// installed add-ons' real manifest + catalog names, see [parseAddonCatalogTitles]) when a match
    /// exists, falling back to the bare request path otherwise (a still-loading/unofficial catalog).
    fun parseCatalogs(json: String, titleMap: Map<String, String> = emptyMap()): List<Catalog> {
        val root = json.toJsonObjectOrNull() ?: return emptyList()
        val catalogs = root.optJSONArray("catalogs") ?: return emptyList()
        val rows = mutableListOf<Catalog>()
        for (catalogIdx in 0 until catalogs.length()) {
            val pages = catalogs.optJSONArray(catalogIdx) ?: continue
            val items = mutableListOf<MetaItem>()
            var title: String? = null
            var rowId: String? = null
            for (pageIdx in 0 until pages.length()) {
                val page = pages.optJSONObject(pageIdx) ?: continue
                if (title == null) {
                    val request = page.optJSONObject("request")
                    rowId = catalogRowId(request, catalogIdx)
                    title = titleMap[rowId] ?: catalogTitle(request)
                }
                val content = page.readyArray("content") ?: continue
                for (metaIdx in 0 until content.length()) {
                    content.optJSONObject(metaIdx)?.let { items += parseMetaPreview(it) }
                }
            }
            if (items.isNotEmpty()) {
                rows += Catalog(id = rowId ?: "row-$catalogIdx", title = title ?: "Catalog", items = items)
            }
        }
        return rows
    }

    /// Parse the `discover` field (a `CatalogWithFilters`) into UI [Catalog] rows. Unlike `board` (a
    /// `CatalogsWithExtra` whose `catalogs` is nested `[[page]]`), Discover is a SINGLE selectable rail:
    /// the engine serializes the currently selected catalog's pages as a FLAT `catalog: [page]` array
    /// (each `{ request, content: Loadable<[meta]> }`, mirroring Apple `CoreDiscover.catalog`), plus a
    /// `selectable` block of the type/catalog/extra options the UI can pivot on.
    ///
    /// We flatten the selected catalog's pages into one [Catalog] row, titled from the selected catalog
    /// option's name when present (else the request path, matching the board titling). The row id is the
    /// selected catalog's stable id so the UI can key it. Fail-soft: a missing/`Loading`/empty catalog
    /// yields no row (empty list), never a throw, so Discover degrades to empty rather than crashing.
    fun parseCatalogWithFilters(json: String, titleMap: Map<String, String> = emptyMap()): List<Catalog> {
        val root = json.toJsonObjectOrNull() ?: return emptyList()
        val pages = root.optJSONArray("catalog") ?: return emptyList()
        val selected = selectedCatalog(root.optJSONObject("selectable"))
        val items = mutableListOf<MetaItem>()
        // GROUP 2a fix (device-verified crash: "Discover Load more"): "Load more" appends the NEXT
        // page's `catalog` entry onto this same flattened array (see [EngineActions.loadDiscoverNextPage]
        // / [EngineStremioRepository.discoverNextPage]'s doc comment -- the engine returns every page
        // loaded so far, not just the new one). Some add-ons legitimately repeat an item across a page
        // boundary (a short catalog padded to the requested page size, or two pages racing on the same
        // underlying skip), which handed [PosterGrid]'s `LazyVerticalGrid` a DUPLICATE `key = { it.id }`
        // -- Compose's lazy list/grid throws `IllegalArgumentException: Key ... was already used` the
        // instant a repeated key is laid out, crashing the app on the very next scroll/recomposition
        // after "Load more" appended the offending page. Dedupe by id HERE, at the single place every
        // page gets flattened into one list, so no caller (Discover today, any future consumer) can ever
        // see a repeated id regardless of which page the duplicate came from.
        val seenIds = mutableSetOf<String>()
        var title: String? = null
        var rowId: String? = selected?.second
        for (pageIdx in 0 until pages.length()) {
            val page = pages.optJSONObject(pageIdx) ?: continue
            if (title == null) {
                val request = page.optJSONObject("request")
                rowId = rowId ?: catalogRowId(request, pageIdx)
                // titleMap is keyed by catalogRowId's "base|type|id" format, NOT selectableCatalogId's
                // "catalog|id|type" -- look it up separately from the UI-facing [rowId] so a selected
                // Discover catalog still resolves its real manifest title.
                title = titleMap[catalogRowId(request, pageIdx)] ?: selected?.first ?: catalogTitle(request)
            }
            val content = page.readyArray("content") ?: continue
            for (metaIdx in 0 until content.length()) {
                val meta = content.optJSONObject(metaIdx)?.let { parseMetaPreview(it) } ?: continue
                if (seenIds.add(meta.id)) items += meta
            }
        }
        if (items.isEmpty()) return emptyList()
        return listOf(Catalog(id = rowId ?: "discover", title = title ?: "Discover", items = items))
    }

    /// The selected entry of `selectable.catalogs` (the engine marks exactly one `selected: true`),
    /// returned as `(label, id)` for the Discover row. Each catalog option mirrors Apple
    /// `CoreSelectableCatalog`: `{ catalog, selected, request }`. Null when no option is selected (e.g. a
    /// still-loading selectable), so the caller falls back to the page's own request for the title.
    private fun selectedCatalog(selectable: JSONObject?): Pair<String, String>? {
        val catalogs = selectable?.optJSONArray("catalogs") ?: return null
        for (i in 0 until catalogs.length()) {
            val entry = catalogs.optJSONObject(i) ?: continue
            if (!entry.optBoolean("selected", false)) continue
            val label = entry.optStringOrNull("catalog") ?: catalogTitle(entry.optJSONObject("request"))
            val id = selectableCatalogId(entry)
            return label to id
        }
        return null
    }

    /// Stable id for a selectable catalog, matching Apple `CoreSelectableCatalog.id`
    /// (`"catalog|path.id|path.type"`), so the Discover row keys consistently across selections.
    private fun selectableCatalogId(entry: JSONObject): String {
        val path = entry.optJSONObject("request")?.optJSONObject("path")
        return listOf(
            entry.optString("catalog"),
            path?.optString("id").orEmpty(),
            path?.optString("type").orEmpty(),
        ).filter { it.isNotBlank() }.joinToString("|").ifBlank { "discover" }
    }

    /// Parse the `continue_watching_preview` field (`{ items: [CoreCWItem] }`) into UI [MetaItem]s for
    /// the leading Home rail. Each item mirrors Apple `CoreCWItem`: `_id`, `type`, `name`, `poster`,
    /// a `state` progress block, and `removed`/`temp` library-bookkeeping flags. We drop `removed`
    /// entries (they linger in the bucket but are not "in Continue Watching"), matching the reference
    /// apps, and keep engine order (already sorted most-recent-first by the core).
    fun parseContinueWatching(json: String): List<MetaItem> {
        val root = json.toJsonObjectOrNull() ?: return emptyList()
        val items = root.optJSONArray("items") ?: return emptyList()
        val out = mutableListOf<MetaItem>()
        for (i in 0 until items.length()) {
            val obj = items.optJSONObject(i) ?: continue
            if (obj.optBoolean("removed", false)) continue
            out += MetaItem(
                id = obj.optString("_id").ifEmpty { obj.optString("id") },
                type = MediaType.fromId(obj.optString("type", "movie")),
                name = obj.optString("name"),
                poster = obj.optStringOrNull("poster"),
                progress = cwProgress(obj.optJSONObject("state")),
            )
        }
        return out
    }

    /// Watched fraction (0..1) from a library item's `state` block (`timeOffset`/`duration`, both in
    /// milliseconds -- the same math as Apple `LibraryItem.progress`), or null when unknown/zero so
    /// the PosterCard progress track only draws for genuinely in-progress items.
    private fun cwProgress(state: JSONObject?): Float? {
        if (state == null) return null
        val timeOffset = state.optDouble("timeOffset", 0.0)
        val duration = state.optDouble("duration", 0.0)
        if (duration <= 0.0 || timeOffset <= 0.0) return null
        return (timeOffset / duration).toFloat().coerceIn(0f, 1f)
    }

    /// Parse the `ctx` field's `profile.addons` into a `"<base>|<type>|<id>"` -> `"<add-on> · <catalog>"`
    /// title map, the real (non-placeholder) rail names [parseCatalogs]/[parseCatalogWithFilters] key
    /// against. Mirrors Apple `CoreBridge.catalogTitleMap`: every installed add-on's manifest carries
    /// its own display name plus a name per declared catalog, and the key format matches
    /// [catalogRowId] exactly so a board/discover row looks itself up by the same id it's rendered
    /// under. Falls back silently to an empty map (never throws) so a still-loading/malformed ctx just
    /// means rows keep their bare-path fallback title.
    fun parseAddonCatalogTitles(ctxJson: String): Map<String, String> {
        val root = ctxJson.toJsonObjectOrNull() ?: return emptyMap()
        val addons = root.optJSONObject("profile")?.optJSONArray("addons") ?: return emptyMap()
        val map = mutableMapOf<String, String>()
        for (i in 0 until addons.length()) {
            val addon = addons.optJSONObject(i) ?: continue
            val transportUrl = addon.optStringOrNull("transportUrl") ?: continue
            val manifest = addon.optJSONObject("manifest") ?: continue
            val addonName = manifest.optStringOrNull("name") ?: continue
            val catalogs = manifest.optJSONArray("catalogs") ?: continue
            for (c in 0 until catalogs.length()) {
                val catalog = catalogs.optJSONObject(c) ?: continue
                val type = catalog.optString("type")
                val id = catalog.optString("id")
                val catalogName = catalog.optStringOrNull("name") ?: id
                val key = listOf(transportUrl, type, id).filter { it.isNotBlank() }.joinToString("|")
                if (key.isNotBlank()) map[key] = "$addonName · $catalogName"
            }
        }
        return map
    }

    /// Parse the `ctx` field into the signed-in/out [AuthState] the account screen and Settings
    /// display. `ctx.profile.auth` serializes as an object (`{ key, user }`) when signed in, absent
    /// (or JSON null) when signed out -- the same test Apple `CoreBridge.isLoggedIn` uses. Because the
    /// engine hydrates `profile` from its own persisted storage at construction (mirrors
    /// `stremio-core-web::initialize_runtime`), this reflects a RESTORED sign-in immediately after
    /// [StremioXCore.init] returns, with no extra action needed.
    fun parseAuthState(ctxJson: String): AuthState {
        val profile = ctxJson.toJsonObjectOrNull()?.optJSONObject("profile") ?: return AuthState.SignedOut
        val user = profile.optJSONObject("auth")?.optJSONObject("user") ?: return AuthState.SignedOut
        return AuthState.SignedIn(
            email = user.optStringOrNull("email"),
            uid = user.optStringOrNull("_id"),
        )
    }

    /// Parse a `RuntimeEvent` for a sign-in failure: `{"name":"CoreEvent","args":{"event":"Error",
    /// "args":{"error":{..., "message": "..."},"source":{"event":"UserAuthenticated",...}}}}`. Every
    /// `CtxError` variant (API/Env/Other) serializes with a `message` field (see stremio-core's
    /// `impl Serialize for OtherError`/`APIError`), so reading it uniformly covers all three. Returns
    /// null for any other event (including a successful `UserAuthenticated`, which is just the ctx
    /// NewState the repository already awaits) or malformed JSON, so callers can `?:` past a miss.
    fun parseAuthErrorMessage(json: String): String? {
        val event = json.toJsonObjectOrNull() ?: return null
        if (event.optString("name") != "CoreEvent") return null
        val coreEvent = event.optJSONObject("args") ?: return null
        if (coreEvent.optString("event") != "Error") return null
        val args = coreEvent.optJSONObject("args") ?: return null
        val source = args.optJSONObject("source")
        if (source?.optString("event") != "UserAuthenticated") return null
        return args.optJSONObject("error")?.optStringOrNull("message")
    }

    /// Parse a `LibraryWithFilters` (`catalog: [libraryItem]`) into UI [MetaItem]s.
    fun parseLibrary(json: String): List<MetaItem> {
        val root = json.toJsonObjectOrNull() ?: return emptyList()
        val catalog = root.optJSONArray("catalog") ?: return emptyList()
        val items = mutableListOf<MetaItem>()
        for (i in 0 until catalog.length()) {
            catalog.optJSONObject(i)?.let { items += parseLibraryItem(it) }
        }
        return items
    }

    /// Parse the `meta_details` field into a UI [MetaDetail] plus its grouped [StreamGroup]s. The meta
    /// lives in `metaItems: [{ request, content: Loadable<metaItem> }]` (first Ready wins); streams
    /// live in `streams: [{ request, content: Loadable<[stream]> }]` grouped by the source add-on.
    fun parseMetaDetail(json: String): MetaDetail? {
        val root = json.toJsonObjectOrNull() ?: return null
        val metaItems = root.optJSONArray("metaItems") ?: return null
        var meta: JSONObject? = null
        for (i in 0 until metaItems.length()) {
            val ready = metaItems.optJSONObject(i)?.readyObject("content")
            if (ready != null) {
                meta = ready
                break
            }
        }
        val metaObj = meta ?: return null
        val type = MediaType.fromId(metaObj.optString("type", "movie"))
        return MetaDetail(
            id = metaObj.optString("id"),
            type = type,
            name = metaObj.optString("name"),
            poster = metaObj.optStringOrNull("poster"),
            background = metaObj.optStringOrNull("background"),
            logo = metaObj.optStringOrNull("logo"),
            description = metaObj.optStringOrNull("description"),
            releaseInfo = metaObj.optStringOrNull("releaseInfo"),
            runtime = metaObj.optStringOrNull("runtime"),
            imdbRating = metaObj.optStringOrNull("imdbRating"),
            genres = parseGenres(metaObj),
            cast = parseCredits(metaObj, "cast", "actors", "actor"),
            directors = parseCredits(metaObj, "director", "directors"),
            writers = parseCredits(metaObj, "writer", "writers"),
            videos = parseVideos(metaObj),
            libraryItem = parseLibraryItemInfo(root.optJSONObject("libraryItem")),
            watchedVideoIds = parseWatchedVideoIds(root),
        )
    }

    /// Parse `meta_details.libraryItem` (the engine's saved library entry for the OPEN title, a
    /// `LibraryItem` -- see `core/src/model.rs`'s `TvosModel::meta_details_json`) into
    /// [LibraryItemInfo]. Null when the title has never been added/watched (the field is absent, not
    /// an empty object) -- the caller reads that as "not in library, no resume position".
    private fun parseLibraryItemInfo(obj: JSONObject?): LibraryItemInfo? {
        if (obj == null) return null
        val state = obj.optJSONObject("state")
        return LibraryItemInfo(
            id = obj.optStringOrNull("_id"),
            removed = obj.optBoolean("removed", false),
            temp = obj.optBoolean("temp", false),
            // LibraryItemState.video_id keeps its Rust snake_case name in JSON (an explicit
            // `#[serde(rename = "video_id")]` overrides the struct's camelCase default) -- every
            // other field below follows the normal camelCase rule. See stremio-core's
            // `types::library::library_item::LibraryItemState`.
            videoId = state?.optStringOrNull("video_id"),
            timeOffsetMs = state?.optLong("timeOffset", 0L) ?: 0L,
            durationMs = state?.optLong("duration", 0L) ?: 0L,
            timesWatched = state?.optInt("timesWatched", 0) ?: 0,
        )
    }

    /// Parse `meta_details.watchedVideoIds` -- the per-episode watched set `TvosModel::meta_details_json`
    /// computes from the engine's WatchedBitField and injects into the JSON (the bitfield itself is
    /// `#[serde(skip_serializing)]`, unreadable directly). Absent (an unloaded/movie meta_details) parses
    /// to an empty set, never a throw.
    private fun parseWatchedVideoIds(root: JSONObject): Set<String> {
        val array = root.optJSONArray("watchedVideoIds") ?: return emptySet()
        val out = mutableSetOf<String>()
        for (i in 0 until array.length()) {
            val id = array.optString(i)
            if (id.isNotBlank()) out += id
        }
        return out
    }

    /// Parse the stream source groups from `meta_details.streams`. One [StreamGroup] per source add-on
    /// (named by the request base host), best-effort, in engine order.
    fun parseStreamGroups(json: String): List<StreamGroup> {
        val root = json.toJsonObjectOrNull() ?: return emptyList()
        val streams = root.optJSONArray("streams") ?: return emptyList()
        val groups = mutableListOf<StreamGroup>()
        for (i in 0 until streams.length()) {
            val entry = streams.optJSONObject(i) ?: continue
            val addon = addonName(entry.optJSONObject("request"))
            val content = entry.readyArray("content") ?: continue
            val sources = mutableListOf<StreamSource>()
            for (s in 0 until content.length()) {
                content.optJSONObject(s)?.let { sources += parseStream(it, addon) }
            }
            if (sources.isNotEmpty()) groups += StreamGroup(addon = addon, streams = sources)
        }
        return groups
    }

    // ---- S04: Discover / Library selectable filters, installed add-ons ----

    /// True once every page of the `discover`/`search`-shaped field's `catalog`/`catalogs` array has
    /// settled (Ready or an engine error -- anything but still `Loading`). Unlike
    /// [parseCatalogWithFilters]'s callers (which historically used "has any items" as their readiness
    /// gate, an acceptable fail-soft tradeoff from S03), this also recognizes a GENUINELY empty result
    /// (a genre filter with zero matches) as settled, so [EngineStremioRepository.discover] does not
    /// have to ride the full load timeout for a catalog that already answered "nothing here".
    fun discoverCatalogSettled(json: String): Boolean {
        val root = json.toJsonObjectOrNull() ?: return false
        val pages = root.optJSONArray("catalog") ?: return false
        if (pages.length() == 0) return false
        for (i in 0 until pages.length()) {
            val content = pages.optJSONObject(i)?.optJSONObject("content") ?: return false
            if (content.optString("type") == "Loading") return false
        }
        return true
    }

    /// Parse the `discover` field's `selectable` block into the type/catalog/genre chip rows the
    /// Discover screen renders. Each option carries the engine's own `request` verbatim (see
    /// [com.stremiox.android.model.DiscoverTypeOption]'s doc) so tapping it re-dispatches EXACTLY what
    /// the engine gave us, mirroring Apple `DiscoverView.typeChips`/`catalogChips`/`genreChips`. Missing/
    /// malformed input degrades to empty lists (never throws): a still-loading discover model has no
    /// selectable yet.
    fun parseDiscoverFilters(json: String): DiscoverFilters {
        val selectable = json.toJsonObjectOrNull()?.optJSONObject("selectable") ?: return DiscoverFilters()
        val types = mutableListOf<DiscoverTypeOption>()
        selectable.optJSONArray("types")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val request = o.optJSONObject("request") ?: continue
                types += DiscoverTypeOption(
                    label = o.optString("type").replaceFirstChar { it.uppercaseChar() }.ifBlank { "All" },
                    selected = o.optBoolean("selected", false),
                    requestJson = request.toString(),
                )
            }
        }
        val catalogs = mutableListOf<DiscoverCatalogOption>()
        selectable.optJSONArray("catalogs")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val request = o.optJSONObject("request") ?: continue
                catalogs += DiscoverCatalogOption(
                    label = o.optStringOrNull("catalog") ?: catalogTitle(request),
                    selected = o.optBoolean("selected", false),
                    requestJson = request.toString(),
                )
            }
        }
        // Genre is one particular "extra" (an add-on-declared filter dimension); mirrors Apple
        // `DiscoverView.genreChips`, which surfaces only the extra literally named "genre" and ignores
        // any other extras the add-on might declare (skip/search are driven elsewhere).
        val genres = mutableListOf<DiscoverGenreOption>()
        selectable.optJSONArray("extra")?.let { arr ->
            for (i in 0 until arr.length()) {
                val extra = arr.optJSONObject(i) ?: continue
                if (!extra.optString("name").equals("genre", ignoreCase = true)) continue
                val options = extra.optJSONArray("options") ?: continue
                for (o in 0 until options.length()) {
                    val option = options.optJSONObject(o) ?: continue
                    val request = option.optJSONObject("request") ?: continue
                    genres += DiscoverGenreOption(
                        label = option.optStringOrNull("value") ?: "Genre",
                        selected = option.optBoolean("selected", false),
                        requestJson = request.toString(),
                    )
                }
            }
        }
        val hasNextPage = selectable.has("nextPage") && !selectable.isNull("nextPage")
        return DiscoverFilters(types = types, catalogs = catalogs, genres = genres, hasNextPage = hasNextPage)
    }

    /// Parse the `library` field's `selectable` block into the type/sort chip rows the Library screen
    /// renders, mirroring Apple's (hypothetical touch) Library filter chips built from the same
    /// `LibraryWithFilters::Selectable`. Fail-soft to empty lists, same contract as
    /// [parseDiscoverFilters].
    fun parseLibraryFilters(json: String): LibraryFilters {
        val selectable = json.toJsonObjectOrNull()?.optJSONObject("selectable") ?: return LibraryFilters()
        val types = mutableListOf<LibraryTypeOption>()
        selectable.optJSONArray("types")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val request = o.optJSONObject("request") ?: continue
                val typeLabel = o.optStringOrNull("type")?.replaceFirstChar { it.uppercaseChar() } ?: "All"
                types += LibraryTypeOption(label = typeLabel, selected = o.optBoolean("selected", false), requestJson = request.toString())
            }
        }
        val sorts = mutableListOf<LibrarySortOption>()
        selectable.optJSONArray("sorts")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val request = o.optJSONObject("request") ?: continue
                sorts += LibrarySortOption(
                    label = librarySortLabel(o.optString("sort")),
                    selected = o.optBoolean("selected", false),
                    requestJson = request.toString(),
                )
            }
        }
        return LibraryFilters(types = types, sorts = sorts)
    }

    /// Human label for the engine's `Sort` enum (`#[serde(rename_all = "lowercase")]`, see
    /// stremio-core `library_with_filters.rs`).
    private fun librarySortLabel(sort: String): String = when (sort) {
        "lastwatched" -> "Recent"
        "name" -> "A–Z"
        "namereverse" -> "Z–A"
        "timeswatched" -> "Most watched"
        "watched" -> "Watched"
        "notwatched" -> "Unwatched"
        else -> sort.replaceFirstChar { it.uppercaseChar() }
    }

    /// Parse `ctx.profile.addons` (an array of `Descriptor`) into [InstalledAddon]s for the Add-ons
    /// screen, mirroring Apple `CoreDescriptor`. [InstalledAddon.rawDescriptorJson] keeps the exact
    /// engine entry so [EngineActions.uninstallAddon] can echo it back verbatim.
    fun parseInstalledAddons(ctxJson: String): List<InstalledAddon> {
        val addons = ctxJson.toJsonObjectOrNull()?.optJSONObject("profile")?.optJSONArray("addons") ?: return emptyList()
        val out = mutableListOf<InstalledAddon>()
        for (i in 0 until addons.length()) {
            val addon = addons.optJSONObject(i) ?: continue
            val transportUrl = addon.optStringOrNull("transportUrl") ?: continue
            val manifest = addon.optJSONObject("manifest") ?: continue
            val flags = addon.optJSONObject("flags")
            out += InstalledAddon(
                transportUrl = transportUrl,
                name = manifest.optStringOrNull("name") ?: transportUrl,
                logo = manifest.optStringOrNull("logo"),
                description = manifest.optStringOrNull("description"),
                isOfficial = flags?.optBoolean("official", false) ?: false,
                isProtected = flags?.optBoolean("protected", false) ?: false,
                providesStreams = addonProvidesStreams(manifest),
                rawDescriptorJson = addon.toString(),
            )
        }
        return out
    }

    /// True when the manifest declares a `stream` resource. `resources` entries can be either a bare
    /// resource-name string or an object with a `name` field (both are valid Stremio manifest shapes),
    /// mirrors Apple `CoreDescriptor.providesStreams`.
    private fun addonProvidesStreams(manifest: JSONObject): Boolean {
        val resources = manifest.optJSONArray("resources") ?: return false
        for (i in 0 until resources.length()) {
            val name = when (val entry = resources.opt(i)) {
                is String -> entry
                is JSONObject -> entry.optStringOrNull("name")
                else -> null
            }
            if (name == "stream") return true
        }
        return false
    }

    // ---- element parsers ----

    private fun parseMetaPreview(obj: JSONObject): MetaItem = MetaItem(
        id = obj.optString("_id").ifEmpty { obj.optString("id") },
        type = MediaType.fromId(obj.optString("type", "movie")),
        name = obj.optString("name"),
        poster = obj.optStringOrNull("poster"),
        year = obj.optStringOrNull("releaseInfo"),
        description = obj.optStringOrNull("description"),
    )

    private fun parseLibraryItem(obj: JSONObject): MetaItem = MetaItem(
        id = obj.optString("_id").ifEmpty { obj.optString("id") },
        type = MediaType.fromId(obj.optString("type", "movie")),
        name = obj.optString("name"),
        poster = obj.optStringOrNull("poster"),
    )

    private fun parseVideos(meta: JSONObject): List<Episode> {
        val videos = meta.optJSONArray("videos") ?: return emptyList()
        val out = mutableListOf<Episode>()
        for (i in 0 until videos.length()) {
            val v = videos.optJSONObject(i) ?: continue
            out += Episode(
                id = v.optString("id"),
                title = v.optStringOrNull("title") ?: "Episode ${v.optInt("episode", i + 1)}",
                season = v.optInt("season", 0),
                episode = v.optInt("episode", 0),
                overview = v.optStringOrNull("overview"),
                thumbnail = v.optStringOrNull("thumbnail"),
                released = v.optStringOrNull("released"),
            )
        }
        return out
    }

    /// Genres come from `links` entries categorized as genre (the engine stops emitting a top-level
    /// `genres` array for previews; `links` is the durable source, matching CoreMetaItem.genres).
    private fun parseGenres(meta: JSONObject): List<String> {
        val links = meta.optJSONArray("links") ?: return emptyList()
        val genres = mutableListOf<String>()
        for (i in 0 until links.length()) {
            val link = links.optJSONObject(i) ?: continue
            val category = link.optString("category").lowercase()
            if (category == "genre" || category == "genres") {
                link.optStringOrNull("name")?.let { genres += it }
            }
        }
        return genres
    }

    /// Credits (cast/director/writer) come from the same `links` array as [parseGenres] -- each named
    /// person is one categorized link, the engine's own convention (mirrors Apple `CoreMetaItem.cast`/
    /// `.directors`/`.writers`). [categories] accepts singular and plural spellings since add-ons
    /// differ; no extra network call (TMDB headshot enrichment is a later, separate addition -- see
    /// this session's report).
    private fun parseCredits(meta: JSONObject, vararg categories: String): List<String> {
        val links = meta.optJSONArray("links") ?: return emptyList()
        val wanted = categories.toSet()
        val out = mutableListOf<String>()
        for (i in 0 until links.length()) {
            val link = links.optJSONObject(i) ?: continue
            if (link.optString("category").lowercase() in wanted) {
                link.optStringOrNull("name")?.let { out += it }
            }
        }
        return out
    }

    private fun parseStream(obj: JSONObject, addon: String): StreamSource {
        val url = obj.optStringOrNull("url")
        val infoHash = obj.optStringOrNull("infoHash")
        val externalUrl = obj.optStringOrNull("externalUrl")
        val isTorrent = url == null && infoHash != null
        // Stable id matching CoreStream.id: (url|externalUrl|infoHash) + "#" + name + description.
        val handle = url ?: externalUrl ?: infoHash ?: "?"
        val name = obj.optStringOrNull("name")
        val description = obj.optStringOrNull("description")
        return StreamSource(
            id = handle + "#" + (name ?: "") + (description ?: ""),
            addon = addon,
            title = name ?: description ?: addon,
            description = description,
            quality = null,
            isTorrent = isTorrent,
        )
    }

    // ---- request -> human label helpers ----

    private fun catalogTitle(request: JSONObject?): String {
        val path = request?.optJSONObject("path") ?: return "Catalog"
        val id = path.optString("id").replaceFirstChar { it.uppercaseChar() }
        val type = path.optString("type").replaceFirstChar { it.uppercaseChar() }
        return listOf(id, type).filter { it.isNotBlank() }.joinToString(" ").ifBlank { "Catalog" }
    }

    private fun catalogRowId(request: JSONObject?, fallbackIndex: Int): String {
        val path = request?.optJSONObject("path") ?: return "row-$fallbackIndex"
        val base = request.optString("base")
        return listOf(base, path.optString("type"), path.optString("id"))
            .filter { it.isNotBlank() }
            .joinToString("|")
            .ifBlank { "row-$fallbackIndex" }
    }

    private fun addonName(request: JSONObject?): String {
        val base = request?.optString("base").orEmpty()
        // The base is the add-on's transport URL; show its host as a stable, human-ish label until a
        // manifest-name lookup is wired (CoreBridge resolves the manifest name; the preview shows host).
        return runCatching { java.net.URI(base).host ?: base }.getOrDefault(base).ifBlank { "Source" }
    }

    // ---- JSON helpers ----

    private fun String.toJsonObjectOrNull(): JSONObject? =
        runCatching { JSONObject(this) }.getOrNull()

    /// Unwrap a `Loadable<[T]>` JSON value at [key] (`{ "type": "Ready", "content": [...] }`),
    /// returning the inner array only when Ready.
    private fun JSONObject.readyArray(key: String): JSONArray? {
        val loadable = optJSONObject(key) ?: return null
        if (loadable.optString("type") != "Ready") return null
        return loadable.optJSONArray("content")
    }

    /// Unwrap a `Loadable<T>` JSON object at [key], returning the inner object only when Ready.
    private fun JSONObject.readyObject(key: String): JSONObject? {
        val loadable = optJSONObject(key) ?: return null
        if (loadable.optString("type") != "Ready") return null
        return loadable.optJSONObject("content")
    }

    /// Like `optString` but returns null (not "") for missing or JSON-null values, so optional UI
    /// fields stay genuinely absent.
    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }
}
