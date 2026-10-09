package com.vortx.android.integrations

import com.vortx.android.home.ImportedListCatalog
import com.vortx.android.home.ImportedListProvider
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

internal data class MyTraktList(
    val name: String, val owner: String, val slug: String, val itemCount: Int,
    val privacy: String, val liked: Boolean,
) {
    val id: String get() = "imported:trakt:$owner:$slug"
    val canonicalUrl: String get() = "https://trakt.tv/users/$owner/lists/$slug"
    val path: String get() = "/users/$owner/lists/$slug"
    val requiresConnection: Boolean get() = privacy != "public"
}

internal data class MyTraktListsState(
    val owner: ExternalIntegrationOwner? = null,
    val lists: List<MyTraktList> = emptyList(),
    val loading: Boolean = false,
    val loaded: Boolean = false,
    val busyIds: Set<String> = emptySet(),
    val message: String? = null,
)

/** The account's lists are read-only. Adding/removing a Home row never edits a Trakt list. */
internal class TraktMyListsController(
    private val access: ExternalIntegrationAccess = ConnectedIntegrationAccess,
    private val register: (ImportedListCatalog) -> Boolean,
    private val remove: (String) -> Unit,
) {
    private val lock = Any()
    private val mutableState = MutableStateFlow(MyTraktListsState())
    val state = mutableState.asStateFlow()

    fun reconcile() = synchronized(lock) {
        val owner = access.owner(RatingProvider.TRAKT)
        if (mutableState.value.owner != owner) mutableState.value = MyTraktListsState(owner = owner)
    }

    suspend fun load() {
        val owner = synchronized(lock) {
            reconcile()
            val state = mutableState.value
            val owner = state.owner ?: run { mutableState.value = state.copy(loaded = true); return }
            if (state.loading) return
            mutableState.value = state.copy(loading = true, message = null)
            owner
        }
        try {
            val settings = get(owner, "/users/settings") ?: error("Unavailable")
            val user = JSONObject(settings).optJSONObject("user")?.optJSONObject("ids")?.optString("slug")
            val personal = JSONArray(get(owner, "/users/me/lists") ?: error("Unavailable"))
            val liked = JSONArray(get(owner, "/users/likes/lists?limit=100") ?: error("Unavailable"))
            val lists = TraktMyListsWire.parse(personal, liked, user)
            publish(owner) { it.copy(lists = lists, loaded = true, loading = false) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            publish(owner) { it.copy(loaded = true, loading = false, message = "Could not load your Trakt lists. Try again.") }
        } finally {
            publish(owner) { it.copy(loading = false) }
            reconcile()
        }
    }

    suspend fun add(owner: ExternalIntegrationOwner, list: MyTraktList): Boolean {
        synchronized(lock) {
            if (!access.current(owner) || mutableState.value.owner != owner || list !in mutableState.value.lists ||
                list.id in mutableState.value.busyIds) return false
            mutableState.value = mutableState.value.copy(busyIds = mutableState.value.busyIds + list.id, message = null)
        }
        try {
            // Privacy can change after opening the picker. Re-read it before deciding persistence.
            val fresh = TraktMyListsWire.list(JSONObject(get(owner, list.path) ?: error("Unavailable")), list.liked, list.owner)
                ?.takeIf { it.id == list.id } ?: error("Unavailable")
            val items = TraktMyListsWire.items(JSONArray(get(owner, "${list.path}/items/movie,show?extended=full") ?: error("Unavailable")))
            if (items.isEmpty()) error("Empty")
            val catalog = ImportedListCatalog(fresh.id, fresh.name, ImportedListProvider.TRAKT, fresh.canonicalUrl,
                items, fresh.requiresConnection, if (fresh.requiresConnection) owner else null)
            var success = false
            publish(owner) { current ->
                success = register(catalog)
                current.copy(message = if (success) "Added ${fresh.name} to Home." else "Could not add this row. Try again.")
            }
            return success
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            publish(owner) { it.copy(message = "This list could not be added. It may be empty or unavailable. Try again.") }
            return false
        } finally {
            publish(owner) { it.copy(busyIds = it.busyIds - list.id) }
            reconcile()
        }
    }

    fun remove(owner: ExternalIntegrationOwner, list: MyTraktList) = publish(owner) {
        if (list in it.lists && list.id !in it.busyIds) {
            remove(list.id)
            it.copy(message = "Removed ${list.name} from Home. Your list on Trakt is unchanged.")
        } else it
    }

    private suspend fun get(owner: ExternalIntegrationOwner, path: String): String? {
        if (!access.current(owner)) return null
        val response = access.request(owner, "GET", path)
        return response?.takeIf { it.status == 200 && access.current(owner) }?.body
    }
    private fun publish(owner: ExternalIntegrationOwner, change: (MyTraktListsState) -> MyTraktListsState) = synchronized(lock) {
        access.publish(owner) {
            if (mutableState.value.owner == owner) mutableState.value = change(mutableState.value)
        }
    }
}

internal object TraktMyListsWire {
    private fun segment(raw: String?): String? = raw?.trim()?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,100}")) }
    fun list(row: JSONObject, liked: Boolean, fallbackOwner: String?): MyTraktList? {
        val name = row.optString("name").trim().takeIf { it.isNotEmpty() && it.length <= 200 } ?: return null
        val owner = segment(row.optJSONObject("user")?.optJSONObject("ids")?.optString("slug")) ?: segment(fallbackOwner) ?: return null
        val ids = row.optJSONObject("ids") ?: return null
        val slug = segment(ids.optString("slug")) ?: ids.optLong("trakt", 0).takeIf { it > 0 }?.toString() ?: return null
        val privacy = row.optString("privacy").lowercase().takeIf { it in setOf("public", "private", "friends") } ?: "private"
        return MyTraktList(name, owner, slug, row.optInt("item_count", 0).coerceAtLeast(0), privacy, liked)
    }
    fun parse(personal: JSONArray, liked: JSONArray, user: String?): List<MyTraktList> = buildList {
        for (i in 0 until personal.length()) personal.optJSONObject(i)?.let { list(it, false, user) }?.let(::add)
        for (i in 0 until liked.length()) liked.optJSONObject(i)?.optJSONObject("list")?.let { list(it, true, null) }?.let(::add)
    }.distinctBy { it.id }

    fun items(array: JSONArray): List<MetaItem> = buildList {
        for (i in 0 until array.length()) {
            val row = array.optJSONObject(i) ?: continue
            val series = when (row.optString("type")) { "movie" -> false; "show" -> true; else -> continue }
            val media = row.optJSONObject(if (series) "show" else "movie") ?: continue
            val ids = media.optJSONObject("ids") ?: continue
            val title = RatingTitle.from(com.vortx.android.model.MediaRef(series, ids.optString("imdb"), ids.optInt("tmdb", 0))) ?: continue
            val id = title.imdb ?: "tmdb:${title.tmdb}"
            val name = media.optString("title").trim().takeIf { it.isNotEmpty() && it.length <= 300 } ?: continue
            add(MetaItem(id, if (series) MediaType.SERIES else MediaType.MOVIE, name,
                poster = title.imdb?.let { "https://images.metahub.space/poster/medium/$it/img" }))
        }
    }.distinctBy { "${it.type.id}:${it.id}" }.take(150)
}
