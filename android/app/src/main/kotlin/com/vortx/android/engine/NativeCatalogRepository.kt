package com.vortx.android.engine

import com.vortx.android.data.*
import com.vortx.android.model.*
import java.net.URI
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Actual UI repository for the explicit native compile gate. Never constructs the legacy engine.
 * The authenticated host provides the session; absence/unavailable/migration required is an error.
 * Auth, player resolution and automatic legacy import remain explicit unsupported capabilities.
 */
internal class NativeCatalogRepository(private val sessionProvider: () -> VortxNativeSession) : CatalogRepository, AuthRepository {
    private data class CatalogSpec(val addon: VortxResourceAddon, val catalog: JSONObject) {
        val type: String get() = catalog.getString("type")
        val id: String get() = catalog.getString("id")
        val title: String get() = catalog.optString("name", id)
        val key: String get() = "${addon.transportUrl}|$type|$id"
        val extras: List<JSONObject> get() = catalog.optJSONArray("extra").objects()
        fun accepts(name: String) = extras.any { it.getString("name") == name }
        fun request(extra: List<Pair<String, String>> = emptyList()) = VortxResourceRequest(VortxResourceRequest.Resource.CATALOG, type, id, extra)
        fun wire(extra: List<Pair<String, String>> = emptyList()) = JSONObject().put("addon", addon.id).put("request", request(extra).json()).toString()
    }
    private data class DiscoverPage(val owner: VortxNativeOwner, val spec: CatalogSpec, val extra: List<Pair<String, String>>,
                                    val items: List<MetaItem>, val count: Int)
    private data class Playing(val token: PlaybackSessionToken, val owner: VortxNativeOwner, val context: PlaybackContext)
    private var discoverPage: DiscoverPage? = null
    private val detailCache = mutableMapOf<Pair<MediaType, String>, Pair<VortxNativeOwner, MetaDetail>>()
    private var playing: Playing? = null
    private val playbackSequence = AtomicLong()
    override val authState: StateFlow<AuthState> = MutableStateFlow(AuthState.SignedOut)

    private suspend fun <T> attempt(action: suspend () -> T): Result<T> = withContext(Dispatchers.IO) {
        try { Result.success(action()) } catch (error: CancellationException) { throw error }
        catch (error: Exception) { Result.failure(error) }
        catch (_: LinkageError) { Result.failure(IllegalStateException("Native artifact is missing or incompatible")) }
    }
    private fun unsupported(capability: String): Nothing = throw UnsupportedOperationException("Native $capability is not enabled in this build")
    private fun session() = sessionProvider()
    private fun action(type: String) = JSONObject().put("type", type)
    private fun library(read: VortxNativeRead) = read.state.getJSONObject("libraries").getJSONObject(read.owner.profileID)
    private fun profile(read: VortxNativeRead) = read.state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(read.owner.profileID)
    private fun addonOwner(read: VortxNativeRead): String = if (profile(read).getString("addons") == "share_primary") read.owner.scope.ownerProfileID else read.owner.profileID
    private fun addonDescriptors(read: VortxNativeRead): List<JSONObject> {
        val bucket = read.state.getJSONObject("nativeSync").getJSONObject("addons").optJSONObject(addonOwner(read)) ?: return emptyList()
        val records = bucket.getJSONObject("records")
        val live = records.keys().asSequence().filter { id -> records.getJSONObject(id).let {
            it.optJSONObject("value") != null && it.getLong("addedAt") > it.getLong("removedAt")
        } }.toList()
        val spine = bucket.getJSONObject("order").getJSONArray("ids").strings().filter { it in live }
        val rest = live.filterNot { it in spine }.sortedWith(compareBy<String> { records.getJSONObject(it).getLong("addedAt") }.thenBy { it })
        return (spine + rest).map { records.getJSONObject(it).getJSONObject("value") }
    }
    private fun registry(read: VortxNativeRead): List<VortxResourceAddon> {
        val parental = profile(read).getJSONObject("parental")
        check(!parental.getBoolean("kids") && parental.opt("maturityCeiling").let { it == null || it == JSONObject.NULL }) {
            "Native parental resource filtering is not enabled"
        }
        val disabled = profile(read).getJSONObject("settings").getJSONArray("disabledAddons").strings().toSet()
        return addonDescriptors(read).filterNot { it.getString("transportUrl") in disabled }.map {
            // Transport is the stable membership identity; duplicate manifest IDs are valid configurations.
            VortxResourceAddon(it.getString("transportUrl"), it.getString("transportUrl"), it.getJSONObject("manifest").toString())
        }
    }
    private fun catalogs(read: VortxNativeRead) = registry(read).flatMap { addon ->
        JSONObject(requireNotNull(addon.manifestJson)).getJSONArray("catalogs").objects().map { CatalogSpec(addon, it) }
    }
    private fun canLoad(spec: CatalogSpec, extras: Set<String>) = spec.extras.none { it.optBoolean("isRequired") && it.getString("name") !in extras }
    private fun owner(value: VortxNativeOwner) = ContinueWatchingOwner(value.profileID, value.scope.digest, value.scope.accountID, true, value.revision)
    override fun continueWatchingOwner() = owner(session().read().owner)

    private fun savedItems(read: VortxNativeRead): List<MetaItem> = library(read).getJSONArray("items").objects().filter {
        it.getString("kind") == "standard"
    }.map { MetaItem(it.getString("id"), MediaType.fromId(it.getString("type")), it.getString("name"), poster = it.optStringOrNull("poster")) }
    private fun cw(read: VortxNativeRead): List<MetaItem> {
        val lib = library(read)
        val saved = savedItems(read)
        val contexts = lib.optJSONObject("watchContexts") ?: JSONObject()
        return lib.optJSONArray("cwBoard").objects().map { item ->
            val id = item.getString("id")
            val matches = saved.filter { it.id == id }
            check(matches.size <= 1) { "Ambiguous native watch media identity" }
            val context = contexts.keys().asSequence().map { contexts.getJSONObject(it) }.filter { it.getString("metaId") == id }
                .maxByOrNull { it.optLong("updatedAt") }
            val type = matches.singleOrNull()?.type ?: if (context?.optStringOrNull("videoId")?.let { it != id } == true) MediaType.SERIES else MediaType.MOVIE
            val unit = context?.optStringOrNull("videoId") ?: id
            val resume = lib.optJSONObject("resume")?.optJSONObject(unit)
            MetaItem(id, type, item.getString("name"), poster = matches.singleOrNull()?.poster,
                progress = item.getInt("progress") / 1000f, resumeSeconds = resume?.getLong("offsetSecs")?.toDouble())
        }
    }
    override suspend fun continueWatchingSnapshot(expectedOwner: ContinueWatchingOwner) = attempt {
        val session = session(); val read = session.read()
        check(owner(read.owner) == expectedOwner) { "Native owner changed" }
        session.owned(read.owner) { ContinueWatchingSnapshot(expectedOwner, cw(read)) }
    }
    override suspend fun home(): Result<List<Catalog>> = attempt {
        val session = session(); val read = session.read()
        val specs = catalogs(read).filter { canLoad(it, emptySet()) }
        val pages = session.load("board", read.owner, specs.map { it.request() to listOf(it.addon) })
        requireAnySettled(pages)
        val rows = EngineState.parseCatalogs(VortxResourceProjection.board(pages, registry(read)), specs.associate { it.key to it.title })
            .map { it.copy(hasNextPage = false) }
        session.publish("board", read.owner, pages) { listOf(Catalog("continue", "Continue Watching", cw(session.read()))) + rows }
    }
    override fun homeUpdates(): Flow<HomeUpdate> = flow {
        val session = session()
        session.updates.collectLatest { sequence ->
            val read = session.read()
            val rows = home().getOrThrow()
            session.owned(read.owner) { check(sessionProvider() === session) }
            emit(HomeUpdate(rows, read.owner.revision, sequence, read.owner.profileID, true, owner(read.owner)))
        }
    }
    override fun ctxUpdates(): Flow<Unit> = flow { session().updates.collect { session(); emit(Unit) } }
    override suspend fun loadHomeRowNextPage(catalog: Catalog) = attempt<Unit> { unsupported("Home pagination") }
    override suspend fun loadMoreHomeRows() = attempt { session(); Unit } // all available catalogs already loaded
    override suspend fun ensureLiveCatalogsLoaded() = home().map { true }

    override suspend fun discover(requestJson: String?): Result<DiscoverResult> = attempt {
        val session = session(); val read = session.read(); val specs = catalogs(read)
        if (specs.isEmpty()) {
            val empty = session.load("discover", read.owner, emptyList())
            return@attempt session.publish("discover", read.owner, empty) { DiscoverResult() }
        }
        val wire = requestJson?.let(::JSONObject)
        val spec = if (wire == null) specs.firstOrNull { canLoad(it, emptySet()) } ?: unsupported("required catalog selection")
            else specs.single { it.addon.id == wire.getString("addon") && it.type == wire.getJSONObject("request").getString("type") && it.id == wire.getJSONObject("request").getString("id") }
        val extras = wire?.getJSONObject("request")?.getJSONArray("extra")?.let { array -> (0 until array.length()).map {
            array.getJSONArray(it).let { pair -> pair.getString(0) to pair.getString(1) }
        } } ?: emptyList()
        require(extras.all { spec.accepts(it.first) && it.first != "skip" && it.first != "search" } && extras.map { it.first }.distinct().size == extras.size)
        check(canLoad(spec, extras.map { it.first }.toSet())) { "Catalog requires a selection" }
        val page = session.load("discover", read.owner, listOf(spec.request(extras) to listOf(spec.addon))).single()
        requireSettled(page)
        val items = EngineState.parseCatalogs(VortxResourceProjection.board(listOf(page), listOf(spec.addon))).flatMap { it.items }
        session.publish("discover", read.owner, listOf(page)) {
            synchronized(this) { discoverPage = DiscoverPage(read.owner, spec, extras, items, items.size) }
            DiscoverResult(items, discoverFilters(specs, spec, extras, items.isNotEmpty()))
        }
    }
    override suspend fun discoverNextPage(): Result<DiscoverResult> = attempt {
        val session = session(); val read = session.read()
        val previous = synchronized(this) { requireNotNull(discoverPage) }
        check(previous.owner == read.owner) { "Native owner changed" }
        check(previous.spec.accepts("skip")) { "Catalog does not support pagination" }
        val request = previous.spec.request(previous.extra + ("skip" to previous.count.toString()))
        val page = session.load("discover", read.owner, listOf(request to listOf(previous.spec.addon))).single()
        requireSettled(page)
        val next = EngineState.parseCatalogs(VortxResourceProjection.board(listOf(page), listOf(previous.spec.addon))).flatMap { it.items }
        val items = (previous.items + next).distinctBy { it.type to it.id }
        session.publish("discover", read.owner, listOf(page)) {
            synchronized(this) { check(discoverPage === previous); discoverPage = previous.copy(items = items, count = previous.count + next.size) }
            DiscoverResult(items, discoverFilters(catalogs(read), previous.spec, previous.extra, next.isNotEmpty()))
        }
    }
    private fun discoverFilters(specs: List<CatalogSpec>, selected: CatalogSpec, extra: List<Pair<String, String>>, more: Boolean): DiscoverFilters {
        val visible = specs.filter { canLoad(it, emptySet()) || it === selected }
        val genres = selected.extras.find { it.getString("name") == "genre" }?.optJSONArray("options")?.strings().orEmpty()
        return DiscoverFilters(
            types = visible.distinctBy { it.type }.map { DiscoverTypeOption(it.type, it.type == selected.type, it.wire()) },
            catalogs = visible.filter { it.type == selected.type }.map { DiscoverCatalogOption(it.title, it.key == selected.key, it.wire()) },
            genres = genres.map { genre -> DiscoverGenreOption(genre, extra.contains("genre" to genre), selected.wire(listOf("genre" to genre))) },
            hasNextPage = selected.accepts("skip") && more)
    }
    override suspend fun search(query: String): Result<List<MetaItem>> = attempt {
        val session = session(); val read = session.read(); val text = query.trim()
        if (text.length < 2) {
            val empty = session.load("search", read.owner, emptyList())
            return@attempt session.publish("search", read.owner, empty) { emptyList() }
        }
        val specs = catalogs(read).filter { it.accepts("search") && canLoad(it, setOf("search")) }
        val pages = session.load("search", read.owner, specs.map { it.request(listOf("search" to text)) to listOf(it.addon) })
        requireAnySettled(pages)
        session.publish("search", read.owner, pages) { EngineState.parseCatalogs(VortxResourceProjection.board(pages, registry(read))).flatMap { it.items }.distinctBy { it.type to it.id } }
    }
    override fun searchUpdates(query: String): Flow<Pair<List<MetaItem>, Boolean>> = flow {
        if (query.trim().length >= 2) emit(emptyList<MetaItem>() to true)
        // Even an empty query must revoke the preceding native consumer slot.
        emit(search(query).getOrThrow() to false)
    }

    override suspend fun meta(type: MediaType, id: String): Result<MetaDetail> = attempt {
        val session = session(); val read = session.read(); val addons = registry(read)
        val page = session.load("meta", read.owner, listOf(VortxResourceRequest(VortxResourceRequest.Resource.META, type.id, id) to addons)).single()
        requireSettled(page)
        val detail = requireNotNull(EngineState.parseMetaDetail(VortxResourceProjection.metaDetails(page, null, null, addons))) { "Native metadata unavailable" }
        check(detail.id == id && detail.type == type) { "Native metadata identity mismatch" }
        session.publish("meta", read.owner, listOf(page)) {
            val decorated = decorate(detail, session.read())
            synchronized(this) { detailCache[type to id] = read.owner to detail }
            decorated
        }
    }
    override suspend fun peekMeta(type: MediaType, id: String): MetaDetail? {
        val session = session(); val read = session.read()
        val cached = synchronized(this) { detailCache[type to id] } ?: return null
        return session.owned(read.owner) { if (cached.first == read.owner) decorate(cached.second, read) else null }
    }
    override suspend fun streams(type: MediaType, id: String, episodeId: String?, rememberedQuality: String?, wantedAddon: String?, forceRefresh: Boolean): Result<List<StreamGroup>> = attempt {
        val session = session(); val read = session.read(); val addons = registry(read)
        val stream = VortxResourceRequest(VortxResourceRequest.Resource.STREAM, type.id, episodeId ?: id)
        val pages = session.load("streams", read.owner, listOf(VortxResourceRequest(VortxResourceRequest.Resource.META, type.id, id) to addons, stream to addons))
        val groups = EngineState.parseStreamGroups(VortxResourceProjection.metaDetails(pages[0], pages[1], stream, addons), episodeId ?: id)
        if (groups.none { it.streams.isNotEmpty() }) requireSettled(pages[1])
        session.publish("streams", read.owner, pages) { groups }
    }
    suspend fun subtitles(type: MediaType, videoID: String, extra: List<Pair<String, String>> = emptyList()): Result<String> = attempt {
        val session = session(); val read = session.read(); val addons = registry(read)
        val page = session.load("subtitles", read.owner, listOf(VortxResourceRequest(VortxResourceRequest.Resource.SUBTITLES, type.id, videoID, extra) to addons)).single()
        requireSettled(page)
        session.publish("subtitles", read.owner, listOf(page)) { VortxResourceProjection.subtitles(page, addons) }
    }
    private fun requireSettled(page: VortxResourceSnapshot) {
        // Empty registry is a legitimate empty account; failed requested providers are never empty success.
        check(page.groups.isEmpty() || page.groups.any { it.status == "ready" }) { "Native resources unavailable" }
    }
    private fun requireAnySettled(pages: List<VortxResourceSnapshot>) {
        val groups = pages.flatMap { it.groups }
        check(groups.isEmpty() || groups.any { it.status == "ready" }) { "Native resources unavailable" }
    }
    private fun decorate(detail: MetaDetail, read: VortxNativeRead): MetaDetail {
        val lib = library(read); val saved = savedItems(read).any { it.id == detail.id && it.type == detail.type }
        val watched = lib.getJSONObject("watched").optJSONObject(detail.id)?.getJSONArray("videoIds")?.strings()?.toSet().orEmpty()
        val contexts = lib.optJSONObject("watchContexts") ?: JSONObject()
        val context = contexts.keys().asSequence().map { contexts.getJSONObject(it) }.filter { it.getString("metaId") == detail.id }.maxByOrNull { it.getLong("updatedAt") }
        val unit = context?.optStringOrNull("videoId") ?: detail.id
        val resume = lib.getJSONObject("resume").optJSONObject(unit)
        return detail.copy(watchedVideoIds = watched, libraryItem = LibraryItemInfo(detail.id, !saved, !saved,
            context?.optStringOrNull("videoId"), (resume?.getLong("offsetSecs") ?: 0) * 1000, (resume?.getLong("durationSecs") ?: 0) * 1000,
            if (detail.id in watched) 1 else 0))
    }

    override suspend fun library(requestJson: String?): Result<LibraryResult> = attempt {
        val session = session(); val read = session.read()
        val request = requestJson?.let(::JSONObject) ?: JSONObject().put("type", "all").put("sort", "recent")
        val type = request.getString("type"); val sort = request.getString("sort")
        require(sort in setOf("recent", "name"))
        val all = savedItems(read); var items = all.filter { type == "all" || it.type.id == type }
        if (sort == "name") items = items.sortedBy { it.name.lowercase() }
        fun wire(t: String = type, s: String = sort) = JSONObject().put("type", t).put("sort", s).toString()
        session.owned(read.owner) { LibraryResult(items, LibraryFilters(
            types = (listOf("all") + all.map { it.type.id }.distinct()).map { LibraryTypeOption(it, it == type, wire(t = it)) },
            sorts = listOf("recent", "name").map { LibrarySortOption(it, it == sort, wire(s = it)) })) }
    }
    override suspend fun libraryPortableItems(now: String): Result<List<LibraryPortability.Item>> = attempt {
        val session = session(); val read = session.read()
        session.owned(read.owner) { savedItems(read).map { item ->
            val detail = decorate(MetaDetail(item.id, item.type, item.name), read)
            val progress = requireNotNull(detail.libraryItem)
            LibraryPortability.Item(item.id, item.type.id, item.name, item.poster, progress.videoId,
                progress.timeOffsetMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), progress.durationMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), now, detail.watchedVideoIds.toList())
        } }
    }
    private fun addAction(item: MetaItem, read: VortxNativeRead) = action("add_library_item").put("profileId", read.owner.profileID)
        .put("item", JSONObject().put("kind", "standard").put("id", item.id).put("type", item.type.id).put("name", item.name).put("poster", item.poster))
    override suspend fun addToLibrary(item: MetaItem) = attempt { val session = session(); val read = session.read(); session.dispatch(listOf(addAction(item, read)), read.owner); Unit }
    override suspend fun removeFromLibrary(id: String) = attempt {
        val session = session(); val read = session.read(); val item = savedItems(read).filter { it.id == id }.single()
        session.dispatch(listOf(action("remove_library_item").put("profileId", read.owner.profileID).put("key", "${item.type.id}:$id")), read.owner); Unit
    }
    override suspend fun addToLibrary(type: MediaType, id: String, name: String, poster: String?): Result<MetaDetail> = attempt {
        addToLibrary(MetaItem(id, type, name, poster)).getOrThrow(); peekMeta(type, id) ?: meta(type, id).getOrThrow()
    }
    override suspend fun removeFromLibrary(type: MediaType, id: String): Result<MetaDetail> = attempt {
        val session = session(); val read = session.read()
        session.dispatch(listOf(action("remove_library_item").put("profileId", read.owner.profileID).put("key", "${type.id}:$id")), read.owner)
        peekMeta(type, id) ?: meta(type, id).getOrThrow()
    }
    private fun requireWatchIdentity(read: VortxNativeRead, type: MediaType, id: String) {
        require(type == MediaType.MOVIE || type == MediaType.SERIES) { "Native progress supports movies and series only" }
        check(savedItems(read).none { it.id == id && it.type != type }) { "Ambiguous native watch media identity" }
    }
    override suspend fun removeFromContinueWatching(target: ContinueWatchingDismissal) = attempt {
        val session = session(); val read = session.read(); check(owner(read.owner) == target.owner)
        requireWatchIdentity(read, target.type, target.id)
        session.dispatch(listOf(action("remove_from_continue_watching").put("metaId", target.id)), read.owner); Unit
    }
    override suspend fun setCatalogWatched(item: MetaItem, isWatched: Boolean) = attempt {
        if (item.type == MediaType.SERIES) unsupported("whole-series watched mutation")
        val session = session(); val read = session.read(); requireWatchIdentity(read, item.type, item.id)
        session.dispatch(listOf(action(if (isWatched) "mark_watched" else "reset_watched").put("metaId", item.id)), read.owner); Unit
    }
    override suspend fun setWatched(type: MediaType, id: String, isWatched: Boolean): Result<MetaDetail> = attempt {
        if (type == MediaType.SERIES) unsupported("whole-series watched mutation")
        setCatalogWatched(MetaItem(id, type, ""), isWatched).getOrThrow(); peekMeta(type, id) ?: meta(type, id).getOrThrow()
    }
    override suspend fun setVideoWatched(type: MediaType, id: String, videoId: String, season: Int?, episode: Int?, isWatched: Boolean): Result<MetaDetail> = attempt {
        val session = session(); val read = session.read(); requireWatchIdentity(read, type, id)
        session.dispatch(listOf(action(if (isWatched) "mark_watched" else "reset_watched").put("metaId", id).put("videoId", videoId)), read.owner)
        peekMeta(type, id) ?: meta(type, id).getOrThrow()
    }
    override suspend fun setSeasonWatched(type: MediaType, id: String, season: Int, isWatched: Boolean): Result<MetaDetail> = attempt { unsupported("season watched mutation") }

    override suspend fun installedAddons() = attempt {
        val session = session(); val read = session.read()
        val disabled = profile(read).getJSONObject("settings").getJSONArray("disabledAddons").strings()
        val ctx = JSONObject().put("profile", JSONObject().put("addons", JSONArray(addonDescriptors(read))))
        session.owned(read.owner) { EngineState.parseInstalledAddons(ctx.toString()).map { it.copy(isDisabled = it.transportUrl in disabled) } }
    }
    override fun normalizedAddonUrl(raw: String): String? = runCatching {
        val uri = URI(raw.trim()); require(uri.scheme in setOf("https", "http") && !uri.host.isNullOrEmpty() && uri.userInfo == null && uri.fragment == null && uri.query == null)
        val path = uri.rawPath.trimEnd('/').let { if (it.endsWith("/manifest.json")) it else "$it/manifest.json" }
        URI("${uri.scheme.lowercase()}://${uri.rawAuthority.lowercase()}$path").toASCIIString()
    }.getOrNull()
    override suspend fun installAddon(url: String) = attempt {
        val session = session(); val read = session.read(); val normalized = requireNotNull(normalizedAddonUrl(url))
        val addon = VortxResourceAddon(normalized, normalized)
        val response = session.load("install", read.owner, listOf(VortxResourceRequest(VortxResourceRequest.Resource.MANIFEST, "", "") to listOf(addon))).single()
        requireSettled(response)
        val manifest = response.groups.single().items(VortxResourceRequest.Resource.MANIFEST).single()
        session.publish("install", read.owner, listOf(response)) {
            session.dispatch(listOf(action("install_addon").put("profileId", addonOwner(read)).put("addon", JSONObject().put("transportUrl", normalized)
                .put("manifest", manifest).put("flags", JSONObject().put("official", false).put("protected", false)))), read.owner)
        }; Unit
    }
    override suspend fun removeAddon(addon: InstalledAddon) = attempt {
        val session = session(); val read = session.read()
        session.dispatch(listOf(action("remove_addon").put("profileId", addonOwner(read)).put("transportUrl", addon.transportUrl)), read.owner); Unit
    }
    override suspend fun changeAddonUrl(oldAddon: InstalledAddon, newUrl: String) = attempt<Unit> { unsupported("add-on URL migration") }
    override suspend fun setAddonDisabled(transportUrl: String, disabled: Boolean) = attempt {
        val session = session(); val read = session.read(); val values = profile(read).getJSONObject("settings").getJSONArray("disabledAddons").strings().toMutableSet()
        if (disabled) values.add(transportUrl) else values.remove(transportUrl)
        session.dispatch(listOf(action("patch_profile").put("id", read.owner.profileID).put("edits", JSONArray().put(JSONObject().put("field", "disabledAddons").put("value", JSONArray(values.toList()))))), read.owner); Unit
    }
    override suspend fun applyAddonOrder(transportUrls: List<String>) = attempt {
        val session = session(); val read = session.read()
        session.dispatch(listOf(action("reorder_addons").put("profileId", addonOwner(read)).put("transportUrls", JSONArray(transportUrls))), read.owner); Unit
    }
    suspend fun profiles(): Result<String> = attempt { session().read().state.getJSONObject("roster").toString() }
    fun watchStatsSnapshot(): NativeWatchStatsSnapshot {
        val session = session(); val read = session.read()
        return session.owned(read.owner) {
            val genres = synchronized(this) { detailCache.values.filter { it.first == read.owner }.associate { it.second.id to it.second.genres } }
            NativeWatchStatsSnapshot(read.owner, NativeWatchStatsProjection.records(library(read)), genres)
        }
    }
    fun <T> withWatchStatsSnapshot(snapshot: NativeWatchStatsSnapshot, publish: () -> T): T = session().owned(snapshot.owner, publish)
    suspend fun addProfile(id: String, name: String) = attempt { session().dispatch(listOf(action("add_profile").put("id", id).put("name", name))); Unit }
    suspend fun switchProfile(id: String) = attempt {
        val session = session(); val read = session.read(); val target = read.state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(id)
        if (target.optStringOrNull("pin") != null) unsupported("PIN verification")
        session.dispatch(listOf(action("switch_profile").put("id", id)), read.owner); Unit
    }
    suspend fun deleteProfile(id: String) = attempt { session().dispatch(listOf(action("delete_profile").put("id", id))); Unit }
    suspend fun renameProfile(id: String, name: String) = attempt {
        session().dispatch(listOf(action("patch_profile").put("id", id).put("edits", JSONArray().put(JSONObject().put("field", "name").put("value", name))))); Unit
    }
    suspend fun mergeNativeSync(document: String) = attempt { session().dispatch(listOf(action("merge_native_sync").put("document", JSONObject(document)))); Unit }

    override suspend fun beginPlaybackSession(context: PlaybackContext?, ownerToken: ContinueWatchingOwner?) = attempt {
        val session = session(); val read = session.read(); val captured = context ?: unsupported("streaming player lifecycle")
        check(ownerToken == owner(read.owner) && captured.owner.profileId == read.owner.profileID && captured.owner.usesEngineHistory)
        require(captured.type in setOf("movie", "series"))
        requireWatchIdentity(read, MediaType.fromId(captured.type), captured.contentId)
        require(captured.contentId.isNotBlank() && captured.videoId.isNotBlank())
        session.owned(read.owner) { synchronized(this) {
            PlaybackSessionToken(playbackSequence.incrementAndGet()).also { playing = Playing(it, read.owner, captured) }
        } }
    }
    private fun progress(sessionToken: PlaybackSessionToken, positionMs: Long, durationMs: Long, end: Boolean) {
        val session = session(); val current = synchronized(this) { playing } ?: return
        if (current.token != sessionToken) return
        require(positionMs >= 0 && durationMs >= 0)
        session.owned(current.owner) {
            synchronized(this) {
                if (playing !== current) return@owned
                session.dispatch(listOf(action("report_progress").put("metaId", current.context.contentId).put("videoId", current.context.videoId)
                    .put("name", current.context.title).put("positionMs", positionMs).put("durationMs", durationMs)), current.owner)
                if (end) playing = null
            }
        }
    }
    override suspend fun reportProgress(session: PlaybackSessionToken, positionMs: Long, durationMs: Long) = attempt { progress(session, positionMs, durationMs, false) }
    override suspend fun endPlaybackSession(session: PlaybackSessionToken, positionMs: Long, durationMs: Long) = attempt { progress(session, positionMs, durationMs, true) }
    override suspend fun resolve(source: StreamSource, episode: Episode?): Result<Playable> = attempt { unsupported("player resolution") }
    override suspend fun resolveDirectLink(url: String, title: String): Result<Playable> = attempt { unsupported("direct-link player resolution") }
    override suspend fun resolveMagnet(infoHash: String, title: String, fileIdx: Int?): Result<Playable> = attempt { unsupported("magnet player resolution") }
    override suspend fun signIn(email: String, password: String) = attempt<Unit> { unsupported("Stremio authentication") }
    override suspend fun signOut() { session().close() }
}

private fun JSONArray?.objects(): List<JSONObject> = this?.let { array -> (0 until array.length()).map(array::getJSONObject) }.orEmpty()
private fun JSONArray.strings(): List<String> = (0 until length()).map(::getString)
private fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key) || !has(key)) null else getString(key)
