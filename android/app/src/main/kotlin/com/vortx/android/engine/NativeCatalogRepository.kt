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
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.withContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import org.json.JSONArray
import org.json.JSONObject

/** Actual UI repository for the explicit native compile gate. Never constructs the legacy engine.
 * The authenticated host provides the session; absence/unavailable/migration required is an error.
 * VortX authentication and complete legacy bootstrap are admitted only by the captured account host.
 */
internal class NativeCatalogRepository(
    private val playbackResolver: NativePlaybackResolver = NativePlaybackResolver { source, _ ->
        requireNotNull(nativeDirectPlayable(source)) { "Native platform resolver unavailable" }
    },
    private val sessionChanges: Flow<Unit> = flowOf(Unit),
    private val signOutAccount: (suspend () -> Unit)? = null,
    private val captureReclaimAdmission: ((VortxNativeSession, VortxNativeOwner) -> ((() -> Boolean) -> Boolean)?)? = null,
    private val withReclaimLifecycle: ((() -> Boolean) -> Boolean) = { action -> action() },
    private val nzbSourceAggregator: NzbSourceAggregator? = null,
    private val sessionProvider: () -> VortxNativeSession,
) : CatalogRepository, AuthRepository {
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
    private data class HomePage(val owner: VortxNativeOwner, val spec: CatalogSpec, val catalog: Catalog, val count: Int)
    private val homePages = linkedMapOf<String, HomePage>()
    private val homePageChanges = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    private val detailCache = mutableMapOf<Pair<MediaType, String>, Pair<VortxNativeOwner, MetaDetail>>()
    private var admittedResources: Pair<VortxNativeOwner, Set<Pair<String, String>>>? = null
    private var playing: Playing? = null
    private data class DurableWatchProof(val owner: VortxNativeOwner, val token: PlaybackSessionToken, val watchedAt: Long,
                                        val admit: (() -> Boolean) -> Boolean)
    private val durableWatchReceipts = java.util.IdentityHashMap<DurableWatchedPlaybackReceipt, DurableWatchProof>()
    private data class SourceBinding(val owner: VortxNativeOwner, val context: PlaybackContext)
    private val sourceBindings = mutableMapOf<String, SourceBinding>()
    private val resolveSequence = AtomicLong()
    private val playbackSequence = AtomicLong()
    private val nativeAuth = MutableStateFlow<AuthState>(AuthState.SignedOut)
    override val authState: StateFlow<AuthState> = nativeAuth
    fun publishAuthentication(state: AuthState) { nativeAuth.value = state }
    private val unavailableOwner = ContinueWatchingOwner("native-unavailable", "native-unavailable", "native-unavailable", true, 0)

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
        val response = session().resolve(JSONObject().put("kind", "installed_addons").put("profileId", addonOwner(read)), read.owner)
        check(response.getString("kind") == "installed_addons" && response.getString("profileId") == addonOwner(read)) { "Native addon projection unavailable" }
        return response.getJSONArray("addons").objects()
    }
    private fun registry(read: VortxNativeRead): List<VortxResourceAddon> {
        val disabled = NativeAddonPreferences.disabled(read)
        val order = NativeAddonPreferences.order(read)
        val descriptors = addonDescriptors(read).let { values -> if (order == null) values else values.sortedBy {
            order.indexOf(AddonOrder.normalize(it.getString("transportUrl"))).let { index -> if (index < 0) Int.MAX_VALUE else index }
        } }
        return descriptors.filterNot { AddonOrder.normalize(it.getString("transportUrl")) in disabled }.map {
            // Transport is the stable membership identity; duplicate manifest IDs are valid configurations.
            VortxResourceAddon(it.getString("transportUrl"), it.getString("transportUrl"), it.getJSONObject("manifest").toString())
        }
    }
    private fun catalogs(read: VortxNativeRead) = registry(read).flatMap { addon ->
        JSONObject(requireNotNull(addon.manifestJson)).getJSONArray("catalogs").objects().map { CatalogSpec(addon, it) }
    }
    private fun canLoad(spec: CatalogSpec, extras: Set<String>) = spec.extras.none { it.optBoolean("isRequired") && it.getString("name") !in extras }
    private fun parental(read: VortxNativeRead): Boolean = profile(read).getJSONObject("parental").let {
        it.getBoolean("kids") || (!it.isNull("maturityCeiling") && it.has("maturityCeiling"))
    }
    private fun policyPage(page: VortxResourceSnapshot, read: VortxNativeRead, slot: String,
                           completed: List<VortxResourceSnapshot>): VortxResourceSnapshot {
        if (!parental(read)) return page
        // A completed load can be superseded while its caller parses. Policy evidence is itself
        // publication: fence the complete admission/revocation, including blocked/null outcomes.
        return session().publish(slot, read.owner, completed) {
        val kind = when (page.request.resource) {
            VortxResourceRequest.Resource.CATALOG -> "catalog"
            VortxResourceRequest.Resource.META -> "meta"
            else -> error("Parental metadata evidence required")
        }
        page.copy(groups = page.groups.map { group ->
            if (group.status != "ready") return@map group
            val raw = JSONObject(requireNotNull(group.contentJson))
            if (kind == "meta" && !raw.isNull("meta")) {
                val value = raw.getJSONObject("meta")
                require(value.getString("id") == page.request.id && value.getString("type") == page.request.type) { "Native metadata identity mismatch" }
            }
            if (kind == "catalog") {
                val identities = raw.getJSONArray("metas").objects().map { it.getString("type") to it.getString("id") }
                require(identities.distinct().size == identities.size) { "Ambiguous parental catalog identity" }
            }
            val response = if (kind == "meta" && raw.isNull("meta")) JSONObject().put("kind", kind).put("meta", JSONObject.NULL)
            else session().resolve(JSONObject().put("kind", kind).also {
                if (kind == "catalog") it.put("metas", raw.getJSONArray("metas"))
                else it.put("meta", raw.get("meta"))
            }, read.owner)
            check(response.getString("kind") == kind) { "Native parental projection unavailable" }
            val field = if (kind == "catalog") "metas" else "meta"
            // The policy DTO may omit provider extensions (notably embedded streams). Use it
            // only as an admission decision; retain the exact approved provider object.
            val allowed: Any = if (kind == "meta") {
                if (response.isNull("meta")) JSONObject.NULL else raw.get("meta")
            } else {
                val ids = response.getJSONArray("metas").objects().map { it.getString("type") to it.getString("id") }.toSet()
                JSONArray(raw.getJSONArray("metas").objects().filter { (it.getString("type") to it.getString("id")) in ids })
            }
            val admitted = when (allowed) {
                is JSONObject -> setOf(allowed.getString("type") to allowed.getString("id"))
                is JSONArray -> allowed.objects().map { it.getString("type") to it.getString("id") }.toSet()
                else -> emptySet()
            }
            val observed = if (kind == "meta") setOf(page.request.type to page.request.id) else
                raw.getJSONArray("metas").objects().map { it.getString("type") to it.getString("id") }.toSet()
            session().owned(read.owner) { synchronized(this) {
                val prior = admittedResources?.takeIf { it.first == read.owner }?.second.orEmpty()
                admittedResources = read.owner to (prior - observed + admitted).takeLastBounded(20_000)
                detailCache.entries.removeAll { (identity, entry) -> entry.first == read.owner &&
                    (identity.first.id to identity.second) in (observed - admitted) }
            } }
            group.copy(contentJson = JSONObject(raw.toString()).put(field, allowed).toString())
        })
        }
    }
    private fun <T> Set<T>.takeLastBounded(size: Int): Set<T> = if (this.size <= size) this else toList().takeLast(size).toSet()
    private fun board(pages: List<VortxResourceSnapshot>, addons: List<VortxResourceAddon>, read: VortxNativeRead, slot: String) =
        VortxResourceProjection.board(pages.map { policyPage(it, read, slot, pages) }, addons)
    private fun rawCount(page: VortxResourceSnapshot) = page.groups.sumOf { it.items(page.request.resource).size }
    private fun visibleLocal(items: List<MetaItem>, read: VortxNativeRead): List<MetaItem> {
        if (!parental(read) || items.isEmpty()) return items
        // Library/watch records deliberately do not invent a certification. Unknown is blocked by
        // the same kernel policy until authenticated provider metadata supplies evidence.
        val raw = JSONArray(items.map { JSONObject().put("id", it.id).put("type", it.type.id).put("name", it.name) })
        val allowed = session().resolve(JSONObject().put("kind", "catalog").put("metas", raw), read.owner)
        check(allowed.getString("kind") == "catalog")
        val cached = synchronized(this) { detailCache.values.filter { it.first == read.owner }.map { it.second.type.id to it.second.id }.toSet() +
            admittedResources?.takeIf { it.first == read.owner }?.second.orEmpty() }
        val identities = allowed.getJSONArray("metas").objects().map { it.getString("type") to it.getString("id") }.toSet() + cached
        return items.filter { (it.type.id to it.id) in identities }
    }
    private fun owner(value: VortxNativeOwner) = ContinueWatchingOwner(value.profileID, value.scope.digest, value.scope.accountID, true, value.revision)
    override fun continueWatchingOwner() = runCatching { owner(session().read().owner) }.getOrDefault(unavailableOwner)
    override fun admitClientHomeRows(rows: List<Catalog>, expectedOwner: ContinueWatchingOwner): Result<List<Catalog>> = runCatching {
        val session = session(); val read = session.read()
        check(owner(read.owner) == expectedOwner) { "Native client rail owner changed" }
        session.owned(read.owner) { rows.map { it.copy(items = visibleLocal(it.items, read)) } }
    }

    private fun savedItems(read: VortxNativeRead): List<MetaItem> = library(read).getJSONArray("items").objects().filter {
        it.getString("kind") == "standard"
    }.map { MetaItem(it.getString("id"), MediaType.fromId(it.getString("type")), it.getString("name"), poster = it.optStringOrNull("poster")) }
    private fun cw(read: VortxNativeRead): List<MetaItem> {
        val saved = savedItems(read)
        return visibleLocal(playback(read).getJSONArray("continueWatching").objects().map { item ->
            val id = item.getString("metaId")
            val matches = saved.filter { it.id == id }
            check(matches.size <= 1) { "Ambiguous native watch media identity" }
            val type = item.optStringOrNull("type")?.let(MediaType::fromId) ?: matches.singleOrNull()?.type
                ?: if (item.optStringOrNull("videoId")?.let { it != id } == true) MediaType.SERIES else MediaType.MOVIE
            val offset = item.getLong("offsetMs"); val duration = item.getLong("durationMs")
            MetaItem(id, type, item.getString("name"), poster = item.optStringOrNull("poster") ?: matches.singleOrNull()?.poster,
                progress = if (duration > 0) (offset.toFloat() / duration).coerceIn(0f, 1f) else 0f, resumeSeconds = offset / 1000.0)
        }, read)
    }
    private fun playback(read: VortxNativeRead): JSONObject = session().resolve(
        JSONObject().put("kind", "profile_playback").put("profileId", read.owner.profileID), read.owner).also {
        check(it.getString("kind") == "profile_playback" && it.getString("profileId") == read.owner.profileID) { "Native playback projection unavailable" }
    }
    override suspend fun continueWatchingSnapshot(expectedOwner: ContinueWatchingOwner) = attempt {
        val session = session(); val read = session.read()
        check(owner(read.owner) == expectedOwner) { "Native owner changed" }
        session.owned(read.owner) { ContinueWatchingSnapshot(expectedOwner, cw(read)) }
    }
    override suspend fun playbackHistorySnapshot(expectedOwner: ContinueWatchingOwner) = attempt {
        val session = session(); val read = session.read()
        check(owner(read.owner) == expectedOwner) { "Native history owner changed" }
        session.owned(read.owner) {
            val saved = savedItems(read)
            val projection = playback(read)
            // Kernel history is completed watches; active partial playback is a separate lane.
            // Both are viewing evidence, unlike saved library membership alone.
            val records = projection.getJSONArray("history").objects() + projection.getJSONArray("continueWatching").objects()
            val items = records.sortedByDescending { it.getLong("updatedAt") }.map { item ->
                val id = item.getString("metaId")
                val matches = saved.filter { it.id == id }
                check(matches.size <= 1) { "Ambiguous native history media identity" }
                val type = item.optStringOrNull("type")?.let(MediaType::fromId) ?: matches.singleOrNull()?.type
                    ?: if (item.optStringOrNull("videoId")?.let { it != id } == true) MediaType.SERIES else MediaType.MOVIE
                val offset = item.getLong("offsetMs"); val duration = item.getLong("durationMs")
                MetaItem(id, type, item.getString("name"), poster = item.optStringOrNull("poster") ?: matches.singleOrNull()?.poster,
                    watched = item.getBoolean("watched"), resumeSeconds = offset / 1000.0,
                    progress = if (duration > 0) (offset.toFloat() / duration).coerceIn(0f, 1f) else 0f)
            }.distinctBy { it.type to it.id }
            ContinueWatchingSnapshot(expectedOwner, visibleLocal(items, read))
        }
    }
    override suspend fun home(): Result<List<Catalog>> = attempt {
        val session = session(); val read = session.read()
        val specs = catalogs(read).filter { canLoad(it, emptySet()) }
        val pages = session.load("board", read.owner, specs.map { it.request() to listOf(it.addon) })
        requireAnySettled(pages)
        val rawCounts = specs.zip(pages).associate { (spec, page) -> spec.key to rawCount(page) }
        val parsedRows = EngineState.parseCatalogs(board(pages, registry(read), read, "board"), specs.associate { it.key to it.title }).associateBy { it.id }
        val rows = specs.mapNotNull { spec ->
            val more = spec.accepts("skip") && (rawCounts[spec.key] ?: 0) > 0
            // The presentation decoder omits empty rows; retain this cursor when policy filtered
            // the entire raw page, otherwise an allowed later page becomes unreachable.
            (parsedRows[spec.key] ?: if (more) Catalog(spec.key, spec.title, emptyList()) else null)?.copy(hasNextPage = more)
        }
        session.publish("board", read.owner, pages) {
            synchronized(this) {
                homePages.clear()
                rows.forEach { row -> specs.find { it.key == row.id }?.let { homePages[row.id] = HomePage(read.owner, it, row, rawCounts[row.id] ?: 0) } }
            }
            listOf(Catalog("continue", "Continue Watching", cw(session.read()))) + rows
        }
    }
    override fun homeUpdates(): Flow<HomeUpdate> = kotlinx.coroutines.flow.channelFlow {
        sessionChanges.collectLatest {
            val session = runCatching { session() }.getOrNull()
            if (session == null) {
                send(HomeUpdate(emptyList(), profileId = unavailableOwner.profileId, authoritative = true, owner = unavailableOwner))
                return@collectLatest
            }
            merge(session.updates.map { true }, homePageChanges.map { false }).collectLatest update@ { reload ->
                val read = runCatching { session.read() }.getOrNull() ?: return@update
                val result = if (reload) home() else runCatching { session.owned(read.owner) {
                    listOf(Catalog("continue", "Continue Watching", cw(read))) + synchronized(this) { homePages.values.filter { it.owner == read.owner }.map { it.catalog } }
                } }
                if (!runCatching { sessionProvider() === session && session.accepts(read.owner) }.getOrDefault(false)) return@update
                send(HomeUpdate(result.getOrThrow(), read.owner.revision, session.updates.value, read.owner.profileID, true, owner(read.owner)))
            }
        }
    }
    override fun ctxUpdates(): Flow<Unit> = kotlinx.coroutines.flow.channelFlow { sessionChanges.collectLatest {
        val session = runCatching { session() }.getOrNull() ?: return@collectLatest
        session.updates.collect {
            if (runCatching { check(sessionProvider() === session); session.read() }.isSuccess) send(Unit)
        }
    } }
    override suspend fun loadHomeRowNextPage(catalog: Catalog) = attempt {
        val session = session(); val read = session.read()
        val previous = synchronized(this) { requireNotNull(homePages[catalog.id]) }
        check(previous.owner == read.owner && previous.spec.accepts("skip")) { "Native catalog changed" }
        if (!previous.catalog.hasNextPage) return@attempt Unit
        val page = session.load("board:${catalog.id}", read.owner,
            listOf(previous.spec.request(listOf("skip" to previous.count.toString())) to listOf(previous.spec.addon))).single()
        requireSettled(page)
        val next = EngineState.parseCatalogs(board(listOf(page), listOf(previous.spec.addon), read, "board:${catalog.id}")).flatMap { it.items }
        session.publish("board:${catalog.id}", read.owner, listOf(page)) {
            synchronized(this) {
                check(homePages[catalog.id] === previous) { "Native catalog reload superseded page" }
                homePages[catalog.id] = previous.copy(catalog = previous.catalog.copy(
                    items = (previous.catalog.items + next).distinctBy { it.type to it.id }, hasNextPage = rawCount(page) > 0), count = previous.count + rawCount(page))
            }
            homePageChanges.tryEmit(Unit)
        }; Unit
    }
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
        val items = EngineState.parseCatalogs(board(listOf(page), listOf(spec.addon), read, "discover")).flatMap { it.items }
        session.publish("discover", read.owner, listOf(page)) {
            synchronized(this) { discoverPage = DiscoverPage(read.owner, spec, extras, items, rawCount(page)) }
            DiscoverResult(items, discoverFilters(specs, spec, extras, rawCount(page) > 0))
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
        val next = EngineState.parseCatalogs(board(listOf(page), listOf(previous.spec.addon), read, "discover")).flatMap { it.items }
        val items = (previous.items + next).distinctBy { it.type to it.id }
        session.publish("discover", read.owner, listOf(page)) {
            synchronized(this) { check(discoverPage === previous); discoverPage = previous.copy(items = items, count = previous.count + rawCount(page)) }
            DiscoverResult(items, discoverFilters(catalogs(read), previous.spec, previous.extra, rawCount(page) > 0))
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
        session.publish("search", read.owner, pages) { EngineState.parseCatalogs(board(pages, registry(read), read, "search")).flatMap { it.items }.distinctBy { it.type to it.id } }
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
        val detail = requireNotNull(EngineState.parseMetaDetail(VortxResourceProjection.metaDetails(policyPage(page, read, "meta", listOf(page)), null, null, addons))) { "Native metadata unavailable or blocked" }
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
        // Capture the direct-source owner/profile before native resource loading can suspend. Passing
        // this exact nullable scope later prevents a profile/account switch from retargeting the query.
        val indexerScope = nzbSourceAggregator?.captureNativeScope(read.owner)
        val stream = VortxResourceRequest(VortxResourceRequest.Resource.STREAM, type.id, episodeId ?: id)
        val pages = session.load("streams", read.owner, listOf(VortxResourceRequest(VortxResourceRequest.Resource.META, type.id, id) to addons, stream to addons))
        val metaPage = policyPage(pages[0], read, "streams", pages)
        if (parental(read)) check(metaPage.groups.any { it.items(VortxResourceRequest.Resource.META).isNotEmpty() }) { "Native metadata blocked or uncertified" }
        val detail = EngineState.parseMetaDetail(VortxResourceProjection.metaDetails(metaPage, null, null, addons))
        check(detail == null || (detail.id == id && detail.type == type)) { "Native metadata identity mismatch" }
        if (parental(read)) check(detail != null && if (type == MediaType.SERIES) {
            episodeId != null && detail.videos.any { it.id == episodeId }
        } else episodeId == null || episodeId == id) { "Stream identity is not in approved metadata" }
        val rawGroups = EngineState.parseStreamGroups(VortxResourceProjection.metaDetails(metaPage, pages[1], stream, addons), episodeId ?: id)
        val selectedEpisode = detail?.videos?.find { it.id == episodeId }
        val search = nativeNzbSearch(detail, type, id, episodeId)
        val direct = if (search != null && indexerScope != null) {
            try { nzbSourceAggregator!!.aggregate(search, indexerScope) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { NzbSourceAggregation.empty() } // An indexer failure never erases working addons.
        } else NzbSourceAggregation.empty()
        val coroutine = currentCoroutineContext()
        session.publish("streams", read.owner, pages) {
            coroutine.ensureActive()
            check(sessionProvider() === session) { "Native account changed" }
            val indexerGroups = if (nzbSourceAggregator?.isAdmitted(direct, coroutine.isActive) == true) direct.groups else emptyList()
            val combined = mergeNzbGroups(rawGroups, indexerGroups)
            val groups = if (parental(read)) combined.map { group -> group.copy(streams = group.streams.filter {
                StreamRanking.passesUserFilters(it, com.vortx.android.sources.SourcePrefsSnapshot.DEFAULT.copy(isKids = true))
            }) } else combined
            if (groups.none { it.streams.isNotEmpty() }) requireSettled(pages[1])
            synchronized(this) {
                if (detail != null) detailCache[type to id] = read.owner to detail
                sourceBindings.clear()
                groups.map { group -> group.copy(streams = group.streams.map { source ->
                    val token = java.util.UUID.randomUUID().toString()
                    sourceBindings[token] = SourceBinding(read.owner, PlaybackContext(
                        PlaybackContext.Owner(read.owner.profileID, true), id, episodeId ?: id, type.id,
                        selectedEpisode?.season, selectedEpisode?.episode, detail?.name ?: id, detail?.poster,
                        PlaybackContext.Provenance(source.addon, source.quality, false, null, null), nativeSessionRevision = read.owner.revision))
                    source.copy(nativePlaybackToken = token)
                }) }
            }
        }
    }
    suspend fun subtitles(type: MediaType, videoID: String, extra: List<Pair<String, String>> = emptyList()): Result<String> = attempt {
        val session = session(); val read = session.read(); val addons = registry(read)
        if (parental(read)) check(synchronized(this) { detailCache.values.any { (owner, meta) -> owner == read.owner && meta.type == type &&
            (meta.id == videoID || meta.videos.any { it.id == videoID }) } }) { "Approved native metadata required for subtitles" }
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
        val saved = savedItems(read).any { it.id == detail.id && it.type == detail.type }
        val playback = playback(read)
        val watched = playback.getJSONObject("watchedVideoIdsByTitle").optJSONArray(detail.id)?.strings()?.toSet().orEmpty()
        val resume = playback.getJSONArray("continueWatching").objects().find { it.getString("metaId") == detail.id }
        return detail.copy(watchedVideoIds = watched, libraryItem = LibraryItemInfo(detail.id, !saved, !saved,
            resume?.optStringOrNull("videoId"), resume?.getLong("offsetMs") ?: 0, resume?.getLong("durationMs") ?: 0,
            playback.getJSONObject("watchedTitles").optInt(detail.id, 0)))
    }

    override suspend fun library(requestJson: String?): Result<LibraryResult> = attempt {
        val session = session(); val read = session.read()
        val request = requestJson?.let(::JSONObject) ?: JSONObject().put("type", "all").put("sort", "recent")
        val type = request.getString("type"); val sort = request.getString("sort")
        require(sort in setOf("recent", "name"))
        val all = visibleLocal(savedItems(read), read); var items = all.filter { type == "all" || it.type.id == type }
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
        val session = session(); val read = session.read(); requireWatchIdentity(read, item.type, item.id)
        if (item.type == MediaType.SERIES) {
            mutateWatchInventory(session, read, item.type, item.id, isWatched) { it.videos.map(Episode::id) }
        } else dispatchWatched(session, read, MetaDetail(item.id, item.type, item.name, poster = item.poster), null, isWatched)
        Unit
    }
    override suspend fun setWatched(type: MediaType, id: String, isWatched: Boolean): Result<MetaDetail> = attempt {
        val session = session(); val read = session.read(); requireWatchIdentity(read, type, id)
        mutateWatchInventory(session, read, type, id, isWatched) { if (type == MediaType.SERIES) it.videos.map(Episode::id) else null }
    }
    override suspend fun setVideoWatched(type: MediaType, id: String, videoId: String, season: Int?, episode: Int?, isWatched: Boolean): Result<MetaDetail> = attempt {
        val session = session(); val read = session.read(); requireWatchIdentity(read, type, id)
        mutateWatchInventory(session, read, type, id, isWatched) { detail ->
            if (type == MediaType.MOVIE) {
                require(videoId == id && season == null && episode == null) { "Exact movie identity required" }; null
            } else {
                val selected = requireNotNull(detail.videos.singleOrNull { it.id == videoId }) { "Video is not in the returned inventory" }
                require((season == null || season == selected.season) && (episode == null || episode == selected.episode)) { "Episode identity mismatch" }
                listOf(selected.id)
            }
        }
    }
    override suspend fun setSeasonWatched(type: MediaType, id: String, season: Int, isWatched: Boolean): Result<MetaDetail> = attempt {
        require(type == MediaType.SERIES && season >= 0) { "A series season is required" }
        val session = session(); val read = session.read(); requireWatchIdentity(read, type, id)
        mutateWatchInventory(session, read, type, id, isWatched) { detail ->
            detail.videos.filter { it.season == season }.map(Episode::id).also { require(it.isNotEmpty()) { "Exact season inventory required" } }
        }
    }

    private suspend fun mutateWatchInventory(session: VortxNativeSession, read: VortxNativeRead, type: MediaType, id: String,
                                            watched: Boolean, select: (MetaDetail) -> List<String>?): MetaDetail {
        // An isolated consumer never cancels/replaces the screen's visible meta or stream load.
        val slot = "watch-mutation"; val addons = registry(read)
        val page = session.load(slot, read.owner, listOf(VortxResourceRequest(VortxResourceRequest.Resource.META, type.id, id) to addons)).single()
        requireSettled(page)
        val approved = policyPage(page, read, slot, listOf(page))
        val raw = requireNotNull(approved.groups.firstNotNullOfOrNull { it.items(VortxResourceRequest.Resource.META).firstOrNull() }) {
            "Authoritative watch metadata unavailable or blocked"
        }
        require(raw.getString("id") == id && raw.getString("type") == type.id) { "Watch metadata identity mismatch" }
        if (type == MediaType.SERIES) {
            val videos = raw.getJSONArray("videos").objects()
            require(videos.isNotEmpty() && videos.size <= 10_000 && videos.map { it.getString("id") }.distinct().size == videos.size) { "Complete unambiguous returned inventory required" }
            videos.forEach { video ->
                require(video.getString("id").isNotBlank() && video.getString("id") != id)
                for (key in listOf("season", "episode")) {
                    val value = video.get(key)
                    require(value is Number && java.math.BigDecimal(value.toString()).let { it.signum() >= 0 && it <= java.math.BigDecimal(Int.MAX_VALUE) && it.stripTrailingZeros().scale() <= 0 }) {
                        "Exact episode coordinates required"
                    }
                }
            }
        }
        val detail = requireNotNull(EngineState.parseMetaDetail(VortxResourceProjection.metaDetails(approved, null, null, addons)))
        val videos = select(detail)
        return session.publish(slot, read.owner, listOf(page)) {
            dispatchWatched(session, read, detail, videos, watched)
            decorate(detail, session.read())
        }
    }
    private fun dispatchWatched(session: VortxNativeSession, read: VortxNativeRead, detail: MetaDetail, videos: List<String>?, watched: Boolean) {
        require(videos == null || videos.isNotEmpty())
        val actions = (videos?.map { it as String? } ?: listOf(null)).map { video ->
            action(if (watched) "mark_watched" else "reset_watched").put("metaId", detail.id).put("videoId", video)
                .put("name", detail.name.takeIf { it.isNotBlank() }).put("metadata", JSONObject().put("type", detail.type.id).put("poster", detail.poster))
        }
        session.dispatch(actions, read.owner, verifyCandidate = { candidate ->
            val proof = JSONObject(candidate.resolve(JSONObject().put("kind", "profile_playback").put("profileId", read.owner.profileID).toString()))
            check(proof.getString("kind") == "profile_playback") { "Native watched receipt unavailable" }
            if (videos == null) check((proof.getJSONObject("watchedTitles").optInt(detail.id) > 0) == watched) { "Native watched receipt mismatch" }
            else {
                val marked = proof.getJSONObject("watchedVideoIdsByTitle").optJSONArray(detail.id)?.strings().orEmpty().toSet()
                check(videos.all { (it in marked) == watched }) { "Native episode batch receipt mismatch" }
            }
        })
    }

    override suspend fun installedAddons() = attempt {
        val session = session(); val read = session.read()
        val disabled = NativeAddonPreferences.disabled(read)
        val ctx = JSONObject().put("profile", JSONObject().put("addons", JSONArray(addonDescriptors(read))))
        session.owned(read.owner) { EngineState.parseInstalledAddons(ctx.toString()).map { it.copy(isDisabled = AddonOrder.normalize(it.transportUrl) in disabled) } }
    }
    override fun normalizedAddonUrl(raw: String): String? = runCatching {
        val uri = URI(raw.trim()); require(uri.scheme in setOf("https", "http") && !uri.host.isNullOrEmpty() && uri.userInfo == null && uri.fragment == null && uri.query == null)
        val path = uri.rawPath.trimEnd('/').let { if (it.endsWith("/manifest.json")) it else "$it/manifest.json" }
        URI("${uri.scheme.lowercase()}://${uri.rawAuthority.lowercase()}$path").toASCIIString()
    }.getOrNull()
    override suspend fun installAddon(url: String) = attempt {
        val session = session(); val read = session.read(); val normalized = requireNotNull(normalizedAddonUrl(url))
        check(addonOwner(read) == read.owner.profileID) { "Shared profiles customize visibility; install add-ons from the owner profile" }
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
        check(addonOwner(read) == read.owner.profileID) { "Shared profiles customize visibility; remove add-ons from the owner profile" }
        session.dispatch(listOf(action("remove_addon").put("profileId", addonOwner(read)).put("transportUrl", addon.transportUrl)), read.owner); Unit
    }
    override suspend fun changeAddonUrl(oldAddon: InstalledAddon, newUrl: String) = attempt {
        val session = session(); val read = session.read(); val bucket = addonOwner(read)
        check(bucket == read.owner.profileID) { "Shared profiles cannot replace account add-ons" }
        val before = addonDescriptors(read)
        val oldKey = AddonOrder.normalize(oldAddon.transportUrl)
        val current = requireNotNull(before.singleOrNull { AddonOrder.normalize(it.getString("transportUrl")) == oldKey }) { "Add-on no longer installed" }
        check(NativeHostPreferences.equal(current, JSONObject(oldAddon.rawDescriptorJson))) { "Add-on descriptor changed; reload installed add-ons" }
        val flags = current.getJSONObject("flags")
        check(!flags.getBoolean("protected") && !flags.getBoolean("official")) { "Protected or official add-ons cannot change endpoint" }
        val target = requireNotNull(normalizedAddonUrl(newUrl)) { "Unsupported add-on endpoint" }
        val targetKey = AddonOrder.normalize(target)
        require(targetKey == oldKey || before.none { AddonOrder.normalize(it.getString("transportUrl")) == targetKey }) { "Replacement endpoint is already installed" }
        val response = session.load("addon-replacement", read.owner,
            listOf(VortxResourceRequest(VortxResourceRequest.Resource.MANIFEST, "", "") to listOf(VortxResourceAddon(target, target)))).single()
        requireSettled(response)
        val manifest = response.groups.single().items(VortxResourceRequest.Resource.MANIFEST).single()
        require(listOf("id", "name", "version").all { manifest.get(it) is String && manifest.getString(it).isNotBlank() }) { "Invalid replacement manifest" }
        require(listOf("types", "resources", "catalogs").all { manifest.get(it) is JSONArray }) { "Incomplete replacement manifest" }
        require(!manifest.optJSONObject("behaviorHints").let { it?.optBoolean("configurationRequired", false) ?: false }) { "Replacement add-on requires configuration" }
        val replacement = JSONObject(current.toString()).put("transportUrl", target).put("manifest", manifest)
        val order = before.map { if (AddonOrder.normalize(it.getString("transportUrl")) == oldKey) target else it.getString("transportUrl") }
        val host = NativeAddonPreferences.replacingHost(read, bucket, oldKey, targetKey)
        val actions = mutableListOf<JSONObject>()
        // A same-member spelling change must remove the previous value before installing its new
        // descriptor, otherwise the membership register may retain the old spelling on equal clocks.
        if (targetKey == oldKey) actions += action("remove_addon").put("profileId", bucket).put("transportUrl", current.getString("transportUrl"))
        actions += action("install_addon").put("profileId", bucket).put("addon", replacement)
        if (targetKey != oldKey) actions += action("remove_addon").put("profileId", bucket).put("transportUrl", current.getString("transportUrl"))
        actions += action("reorder_addons").put("profileId", bucket).put("transportUrls", JSONArray(order))
        val profiles = read.state.getJSONObject("roster").getJSONObject("profiles")
        profiles.keys().forEach { id ->
            val profile = profiles.getJSONObject(id)
            if (!profile.getBoolean("deleted") && (id == bucket || profile.getString("addons") == "share_primary" && bucket == read.owner.scope.ownerProfileID)) {
                val disabled = profile.getJSONObject("settings").getJSONArray("disabledAddons").strings()
                if (disabled.any { AddonOrder.normalize(it) == oldKey }) actions += action("patch_profile").put("id", id).put("edits", JSONArray().put(
                    JSONObject().put("field", "disabledAddons").put("value", JSONArray(disabled.map { if (AddonOrder.normalize(it) == oldKey) targetKey else it }.distinct()))))
            }
        }
        session.publish("addon-replacement", read.owner, listOf(response)) {
            session.dispatch(actions, read.owner, host, verifyCandidate = { candidate ->
                val query = JSONObject(candidate.resolve(JSONObject().put("kind", "installed_addons").put("profileId", bucket).toString()))
                check(query.getString("kind") == "installed_addons") { "Native replacement receipt unavailable" }
                val installed = query.getJSONArray("addons").objects()
                check(installed.map { AddonOrder.normalize(it.getString("transportUrl")) } == order.map(AddonOrder::normalize)) { "Native replacement order mismatch" }
                val accepted = installed.single { AddonOrder.normalize(it.getString("transportUrl")) == targetKey }
                check(accepted.getString("transportUrl") == target && NativeHostPreferences.equal(accepted.getJSONObject("flags"), flags) &&
                    listOf("id", "name", "version").all { accepted.getJSONObject("manifest").getString(it) == manifest.getString(it) }) { "Native replacement descriptor mismatch" }
                before.filterNot { AddonOrder.normalize(it.getString("transportUrl")) == oldKey }.forEach { unchanged ->
                    check(installed.any { NativeHostPreferences.equal(it, unchanged) }) { "Unrelated add-on changed during replacement" }
                }
            })
        }; Unit
    }
    override suspend fun setAddonDisabled(transportUrl: String, disabled: Boolean) = attempt {
        val session = session(); val read = session.read(); val values = NativeAddonPreferences.disabled(read).toMutableSet()
        if (disabled) values.add(AddonOrder.normalize(transportUrl)) else values.remove(AddonOrder.normalize(transportUrl))
        val host = read.state.getJSONObject("hostProfilePreferences")
        val raw = host.optJSONObject(read.owner.profileID) ?: NativeProfileAccess.projection(read).profiles.single { it.id == read.owner.profileID }.encode()
        val prefs = raw.optJSONObject("addonPreferences") ?: JSONObject().also { raw.put("addonPreferences", it) }
        prefs.put("disabledAddonURLsOverride", JSONArray(values.toList()))
        raw.put("disabledAddons", JSONArray(values.toList()))
        host.put(read.owner.profileID, raw).put("modifiedSeconds", maxOf(System.currentTimeMillis() / 1000.0, host.optDouble("modifiedSeconds", 0.0) + 0.001))
        session.dispatch(listOf(action("patch_profile").put("id", read.owner.profileID).put("edits", JSONArray().put(JSONObject().put("field", "disabledAddons").put("value", JSONArray(values.toList()))))), read.owner, host); Unit
    }
    override suspend fun applyAddonOrder(transportUrls: List<String>) = attempt {
        val session = session(); val read = session.read()
        val shared = read.owner.profileID != addonOwner(read)
        val actions = if (shared) emptyList() else listOf(action("reorder_addons").put("profileId", addonOwner(read)).put("transportUrls", JSONArray(transportUrls)))
        session.dispatch(actions, read.owner, NativeAddonPreferences.reorderedHost(read, transportUrls, shared)); Unit
    }
    suspend fun profiles(): Result<String> = attempt { session().read().state.getJSONObject("roster").toString() }
    fun watchStatsSnapshot(): NativeWatchStatsSnapshot {
        val session = session(); val read = session.read()
        return session.owned(read.owner) {
            val genres = synchronized(this) { detailCache.values.filter { it.first == read.owner }.associate { it.second.id to it.second.genres } }
            val records = NativeWatchStatsProjection.records(library(read))
            val allowed = if (parental(read)) visibleLocal(records.map { MetaItem(it.id, MediaType.fromId(it.type), it.name) }, read).map { it.id }.toSet() else null
            NativeWatchStatsSnapshot(read.owner, records.filter { allowed == null || it.id in allowed }, genres)
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
        val session = session(); val read = session.read()
        val captured = context ?: return@attempt PlaybackSessionToken.NOOP
        check(ownerToken == owner(read.owner) && captured.owner.profileId == read.owner.profileID && captured.owner.usesEngineHistory)
        check(captured.nativeSessionRevision == null || captured.nativeSessionRevision == read.owner.revision) { "Native playback owner expired" }
        require(captured.type in setOf("movie", "series"))
        requireWatchIdentity(read, MediaType.fromId(captured.type), captured.contentId)
        require(captured.contentId.isNotBlank() && captured.videoId.isNotBlank())
        if (parental(read)) check(synchronized(this) {
            detailCache[MediaType.fromId(captured.type) to captured.contentId]?.let { (cachedOwner, detail) ->
                cachedOwner == read.owner && (captured.videoId == detail.id || detail.videos.any { it.id == captured.videoId })
            } == true
        }) { "Approved native metadata required for playback" }
        session.owned(read.owner) { synchronized(this) {
            PlaybackSessionToken(playbackSequence.incrementAndGet()).also { playing = Playing(it, read.owner, captured) }
        } }
    }
    private fun progress(sessionToken: PlaybackSessionToken, positionMs: Long, durationMs: Long) {
        val session = session(); val current = synchronized(this) { playing } ?: return
        if (current.token != sessionToken) return
        require(positionMs >= 0 && durationMs >= 0)
        session.owned(current.owner) {
            synchronized(this) {
                if (playing !== current) return@owned
                session.dispatch(listOf(action("report_progress").put("metaId", current.context.contentId).put("videoId", current.context.videoId)
                    .put("name", current.context.title).put("positionMs", positionMs).put("durationMs", durationMs)
                    .put("metadata", JSONObject().put("type", current.context.type).put("poster", current.context.poster))), current.owner)
            }
        }
    }
    override suspend fun reportProgress(session: PlaybackSessionToken, positionMs: Long, durationMs: Long) = attempt { progress(session, positionMs, durationMs) }
    override suspend fun endPlaybackSession(session: PlaybackSessionToken, positionMs: Long, durationMs: Long) =
        endPlaybackSessionWithDurableWatchReceipt(session, positionMs, durationMs).map { Unit }
    private fun watchedStamp(projection: JSONObject, context: PlaybackContext, requireType: Boolean): Long? =
        projection.getJSONArray("history").objects().filter { row ->
            row.getString("metaId") == context.contentId && row.getBoolean("watched") &&
                (!requireType || row.optStringOrNull("type") == context.type) &&
                (row.optStringOrNull("videoId") == context.videoId ||
                    context.type == "movie" && context.videoId == context.contentId && row.optStringOrNull("videoId") == null)
        }.maxOfOrNull { it.getLong("updatedAt") }

    override suspend fun endPlaybackSessionWithDurableWatchReceipt(token: PlaybackSessionToken, positionMs: Long, durationMs: Long): Result<DurableWatchedPlaybackReceipt?> = attempt {
        val session = session(); val current = synchronized(this) { playing } ?: return@attempt null
        if (current.token != token) return@attempt null
        require(positionMs >= 0 && durationMs >= 0)
        session.owned(current.owner) { synchronized(this) {
            if (playing !== current) return@owned null
            val query = JSONObject().put("kind", "profile_playback").put("profileId", current.owner.profileID)
            val prior = watchedStamp(session.resolve(query, current.owner), current.context, false) ?: 0L
            try {
                session.dispatch(listOf(action("report_progress").put("metaId", current.context.contentId).put("videoId", current.context.videoId)
                    .put("name", current.context.title).put("positionMs", positionMs).put("durationMs", durationMs)
                    .put("metadata", JSONObject().put("type", current.context.type).put("poster", current.context.poster))), current.owner)
                val committed = session.resolveCommitted(query, current.owner)
                check(committed.getString("kind") == "profile_playback" && committed.getString("profileId") == current.owner.profileID)
                val stamp = watchedStamp(committed, current.context, true)
                // The kernel alone decides completion. A prior watch plus a partial/zero terminal
                // report is not a new durable finish from this playback session.
                val admission = if (stamp != null && stamp > prior && durationMs > 0L) captureReclaimAdmission?.invoke(session, current.owner) else null
                if (stamp == null || admission == null) null else {
                    if (durableWatchReceipts.size >= 128) durableWatchReceipts.clear()
                    DurableWatchedPlaybackReceipt(current.context, owner(current.owner)).also {
                        durableWatchReceipts[it] = DurableWatchProof(current.owner, token, stamp, admission)
                    }
                }
            } finally { if (playing === current) playing = null }
        } }
    }
    override fun reclaimAfterDurableWatchedPlaybackReceipt(receipt: DurableWatchedPlaybackReceipt, action: () -> Boolean): Boolean = runCatching { withReclaimLifecycle {
        val session = session()
        val proof = synchronized(this) { durableWatchReceipts[receipt] } ?: return@withReclaimLifecycle false
        session.owned(proof.owner) { synchronized(this) {
            if (durableWatchReceipts[receipt] !== proof || receipt.owner != owner(proof.owner) ||
                receipt.context.owner != PlaybackContext.Owner(proof.owner.profileID, true)) return@owned false
            // Production enters the download lifecycle first, then Session -> auth -> mounted lifecycle.
            // Point-in-time owner checks
            // alone cannot serialize a destructive callback with logout/epoch retirement.
            proof.admit {
                val committed = session.resolveCommitted(JSONObject().put("kind", "profile_playback").put("profileId", proof.owner.profileID), proof.owner)
                if (committed.getString("kind") != "profile_playback" || watchedStamp(committed, receipt.context, true) != proof.watchedAt) false else {
                    // The UI coordinator independently waits for every decoder/lease to release.
                    durableWatchReceipts.remove(receipt)
                    action()
                }
            }
        } }
    } }.getOrDefault(false)
    override suspend fun resolve(source: StreamSource, episode: Episode?): Result<Playable> = attempt {
        val session = session(); val read = session.read()
        val binding = synchronized(this) { sourceBindings[source.nativePlaybackToken] }
        check(binding != null && binding.owner == read.owner) { "Native source selection expired; reload sources" }
        check(episode == null || episode.id == binding.context.videoId) { "Native episode selection changed" }
        resolveOwned(session, read, source, episode, binding).copy(playbackContext = binding.context)
    }
    private suspend fun resolveOwned(session: VortxNativeSession, read: VortxNativeRead, source: StreamSource, episode: Episode?, binding: SourceBinding? = null): Playable {
        val sequence = resolveSequence.incrementAndGet()
        val sourceToken = source.nativePlaybackToken
        val resolutionCoroutine = currentCoroutineContext()
        // The resolver may await local preparation. Its retirement probe uses the same captured
        // owner and selection checks as final admission, without capturing a newer session/owner.
        fun requireCurrent() {
            resolutionCoroutine.ensureActive()
            check(sessionProvider() === session && resolveSequence.get() == sequence) { "Native playback superseded" }
            if (binding != null) synchronized(this) { check(sourceBindings[sourceToken] === binding) { "Native source selection expired" } }
        }
        val playable = try {
            playbackResolver.resolve(source, episode,
                isCurrent = { try { session.owned(read.owner) { requireCurrent(); true } } catch (_: Exception) { false } },
                // A handed-off lease outlives its resolve Job and later source loads/prewarm.
                // Its durable account/profile/binding authority is the exact captured native owner.
                playbackIsCurrent = { try { sessionProvider() === session && session.accepts(read.owner) } catch (_: Exception) { false } })
        } catch (cancelled: CancellationException) {
            // Resolver retirement is a handled stale selection, not cancellation of its caller.
            // A genuinely cancelled caller or a still-current resolver cancellation stays terminal.
            resolutionCoroutine.ensureActive()
            session.owned(read.owner) { requireCurrent() }
            throw cancelled
        }
        try {
            currentCoroutineContext().ensureActive()
            return session.owned(read.owner) {
                requireCurrent()
                if (binding == null) playable else {
                    val resume = session.resolve(JSONObject().put("kind", "resume_point").put("id", binding.context.videoId), read.owner)
                    check(resume.getString("kind") == "resume_point") { "Native resume projection unavailable" }
                    playable.copy(startPositionMs = resume.optJSONObject("resume")?.getLong("offsetMs") ?: 0L)
                }
            }
        } catch (error: Throwable) { playable.playbackLease?.close(); throw error }
    }
    override suspend fun resolveDirectLink(url: String, title: String): Result<Playable> = attempt {
        val session = session(); val read = session.read()
        check(!parental(read)) { "Uncertified direct links are blocked by parental settings" }
        val source = StreamSource(id = url, addon = "Direct link", title = title, url = url)
        requireNotNull(nativeDirectPlayable(source)) { "Only HTTP(S) direct links are supported" }
        resolveOwned(session, read, source, null)
    }
    override suspend fun resolveMagnet(infoHash: String, title: String, fileIdx: Int?): Result<Playable> = attempt {
        val session = session(); val read = session.read()
        check(!parental(read)) { "Uncertified magnets are blocked by parental settings" }
        require(Regex("[a-fA-F0-9]{40}").matches(infoHash) && (fileIdx == null || fileIdx >= 0))
        resolveOwned(session, read, StreamSource(id = infoHash, addon = "Magnet", title = title,
            infoHash = infoHash, fileIdx = fileIdx, isTorrent = true), null)
    }
    override suspend fun signIn(email: String, password: String) = attempt<Unit> { unsupported("Stremio authentication") }
    override suspend fun signOut() {
        if (signOutAccount != null) signOutAccount.invoke() else session().close()
        nativeAuth.value = AuthState.SignedOut
    }
}

private fun JSONArray?.objects(): List<JSONObject> = this?.let { array -> (0 until array.length()).map(array::getJSONObject) }.orEmpty()
private fun JSONArray.strings(): List<String> = (0 until length()).map(::getString)
private fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key) || !has(key)) null else getString(key)
