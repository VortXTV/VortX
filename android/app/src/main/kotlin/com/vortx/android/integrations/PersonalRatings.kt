package com.vortx.android.integrations

import com.vortx.android.model.MediaRef
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

internal data class RatingTitle(val isSeries: Boolean, val imdb: String?, val tmdb: Int?) {
    val aliases: Set<String> get() = listOfNotNull(imdb, tmdb?.let { "tmdb:$it" })
        .mapTo(linkedSetOf()) { "${if (isSeries) "show" else "movie"}:$it" }
    val bucket: String get() = if (isSeries) "shows" else "movies"
    companion object {
        fun from(ref: MediaRef): RatingTitle? {
            val imdb = ref.imdb?.takeIf { it.matches(Regex("tt[0-9]+")) }
            val tmdb = ref.tmdb?.takeIf { it > 0 }
            return if (imdb == null && tmdb == null) null else RatingTitle(ref.isSeries, imdb, tmdb)
        }
        fun fromId(id: String, isSeries: Boolean): RatingTitle? {
            val typed = if (isSeries) "tmdb:tv:" else "tmdb:movie:"
            val tmdb = when {
                id.startsWith(typed) -> id.removePrefix(typed).toIntOrNull()
                id.startsWith("tmdb:") -> id.removePrefix("tmdb:").toIntOrNull()
                else -> null
            }
            return from(MediaRef(isSeries, imdb = id, tmdb = tmdb))
        }
    }
}

internal data class PersonalRating(val title: RatingTitle, val value: Int?, val ratedAt: Instant?)
internal data class PersonalRatingState(val value: Int? = null, val busy: Boolean = false, val message: String? = null)

/** The live session owns this shadow. It is never placed in shared preferences or an account backup. */
internal class PersonalRatingsController(private val access: ExternalIntegrationAccess = ConnectedIntegrationAccess) {
    private class Cache(val owner: ExternalIntegrationOwner) {
        val values = mutableListOf<PersonalRating>()
        val busy = mutableSetOf<String>()
        val messages = mutableMapOf<String, String>()
        var revision = 0L
        var refreshing = false
        var refreshedAt: Long? = null
    }
    private val lock = Any()
    private val caches = mutableMapOf<RatingProvider, Cache>()
    private val changes = MutableStateFlow(0L)
    val revision = changes.asStateFlow()

    fun owner(provider: RatingProvider): ExternalIntegrationOwner? = access.owner(provider, ratings = true)
    fun reconcile() = synchronized(lock) {
        if (caches.entries.removeAll { !access.current(it.value.owner, ratings = true) }) changed()
    }

    fun state(owner: ExternalIntegrationOwner, title: RatingTitle): PersonalRatingState = synchronized(lock) {
        val cache = currentCache(owner) ?: return@synchronized PersonalRatingState()
        PersonalRatingState(find(cache, title)?.value, title.aliases.any(cache.busy::contains),
            title.aliases.firstNotNullOfOrNull(cache.messages::get))
    }

    suspend fun refresh(owner: ExternalIntegrationOwner): Boolean {
        val plan = synchronized(lock) {
            val cache = currentCache(owner) ?: return false
            if (cache.refreshing) return false
            if (cache.refreshedAt?.let { System.currentTimeMillis() - it < 60_000 } == true) return true
            cache.refreshing = true
            cache to cache.revision
        }
        try {
            val paths = when (owner.provider) {
                RatingProvider.TRAKT -> listOf("/sync/ratings/movies", "/sync/ratings/shows")
                RatingProvider.SIMKL -> listOf("movies", "shows", "anime").map { "/sync/ratings/$it/1,2,3,4,5,6,7,8,9,10" }
            }
            val rows = mutableListOf<PersonalRating>()
            for (path in paths) {
                if (!access.current(owner, ratings = true)) return false
                val response = access.request(owner, "GET",
                    path, ratings = true) ?: return false
                if (response.status != 200) return false
                rows += PersonalRatingsWire.parse(owner.provider, response.body) ?: return false
            }
            return synchronized(lock) { access.publish(owner, ratings = true) {
                val cache = currentCache(owner) ?: return@publish false
                if (cache !== plan.first || cache.revision != plan.second) return@publish false
                // A missing title never erases a local value; newer, valid timestamps converge it.
                for (row in rows) {
                    val old = find(cache, row.title)
                    if (old == null || (row.ratedAt != null && old.ratedAt != null && row.ratedAt > old.ratedAt)) {
                        replace(cache, row)
                    } else if (old.title.imdb == null || old.title.tmdb == null) {
                        replace(cache, old.copy(title = old.title.copy(imdb = old.title.imdb ?: row.title.imdb,
                            tmdb = old.title.tmdb ?: row.title.tmdb)))
                    }
                }
                cache.refreshedAt = System.currentTimeMillis()
                changed()
                true
            } ?: false }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return false
        } finally {
            synchronized(lock) { plan.first.refreshing = false }
            reconcile()
        }
    }

    /** One in-flight write per title. The captured owner is required; callers cannot retarget an old tap. */
    suspend fun set(owner: ExternalIntegrationOwner, title: RatingTitle, value: Int?): Boolean {
        if (value != null && value !in 1..10 || title.aliases.isEmpty()) return false
        val cache = synchronized(lock) {
            val current = currentCache(owner) ?: return false
            if (title.aliases.any(current.busy::contains)) return false
            current.busy.addAll(title.aliases)
            title.aliases.forEach(current.messages::remove)
            current.revision++ // Any earlier read cannot overwrite this explicit action.
            changed()
            current
        }
        val ratedAt = Instant.now()
        try {
            val path = if (value == null) "/sync/ratings/remove" else "/sync/ratings"
            val response = access.request(owner, "POST", path,
                PersonalRatingsWire.payload(title, value, ratedAt), ratings = true)
            val accepted = response?.let { PersonalRatingsWire.accepted(owner.provider, title, value, it) } == true
            return synchronized(lock) { access.publish(owner, ratings = true) {
                if (currentCache(owner) !== cache) return@publish false
                if (accepted) {
                    replace(cache, PersonalRating(title, value, ratedAt))
                    title.aliases.forEach { cache.messages[it] = if (value == null) "Rating removed." else "Rating saved." }
                } else title.aliases.forEach { cache.messages[it] = "Rating could not be saved. Try again." }
                cache.revision++
                changed()
                accepted
            } ?: false }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            synchronized(lock) {
                if (currentCache(owner) === cache) {
                    title.aliases.forEach { cache.messages[it] = "Rating could not be saved. Try again." }
                    changed()
                }
            }
            return false
        } finally {
            synchronized(lock) { cache.busy.removeAll(title.aliases); changed() }
            reconcile()
        }
    }

    private fun currentCache(owner: ExternalIntegrationOwner): Cache? {
        if (!access.current(owner, ratings = true)) {
            if (caches[owner.provider]?.owner == owner) caches.remove(owner.provider)
            return null
        }
        val existing = caches[owner.provider]
        return if (existing?.owner == owner) existing else Cache(owner).also { caches[owner.provider] = it }
    }
    private fun find(cache: Cache, title: RatingTitle) = cache.values.firstOrNull { it.title.aliases.any(title.aliases::contains) }
    private fun replace(cache: Cache, rating: PersonalRating) {
        val old = find(cache, rating.title)
        val enriched = rating.copy(title = rating.title.copy(imdb = rating.title.imdb ?: old?.title?.imdb,
            tmdb = rating.title.tmdb ?: old?.title?.tmdb))
        cache.values.removeAll { it.title.aliases.any(enriched.title.aliases::contains) }
        cache.values.add(enriched)
    }
    private fun changed() { changes.value += 1 }
}

internal object PersonalRatingsWire {
    fun payload(title: RatingTitle, value: Int?, ratedAt: Instant): String = JSONObject().put(title.bucket,
        JSONArray().put(JSONObject().apply {
            put("ids", JSONObject().apply { title.imdb?.let { put("imdb", it) }; title.tmdb?.let { put("tmdb", it) } })
            if (value != null) { put("rating", value); put("rated_at", ratedAt.toString()) }
        })).toString()

    fun accepted(provider: RatingProvider, title: RatingTitle, value: Int?, response: IntegrationsHttp.Response): Boolean {
        if (!response.isSuccess) return false
        // SIMKL documents an empty successful body for remove only.
        if (provider == RatingProvider.SIMKL && value == null && response.body.isBlank()) return true
        val root = runCatching { JSONObject(response.body) }.getOrNull() ?: return false
        if ((root.optJSONObject("not_found")?.optJSONArray(title.bucket)?.length() ?: 0) > 0) return false
        return if (value == null) root.optJSONObject("deleted")?.let {
            it.has(title.bucket) && it.optInt(title.bucket, -1) >= 0
        } == true
        else listOf("added", "updated").sumOf { root.optJSONObject(it)?.optInt(title.bucket) ?: 0 } > 0
    }

    fun parse(provider: RatingProvider, body: String): List<PersonalRating>? = runCatching {
        if (provider == RatingProvider.SIMKL && body.isBlank()) return@runCatching emptyList()
        val out = mutableListOf<PersonalRating>()
        fun fold(array: JSONArray, series: Boolean?, simkl: Boolean) {
            for (i in 0 until array.length()) {
                val row = array.optJSONObject(i) ?: continue
                val isSeries = series ?: when (row.optString("type")) {
                    "movie" -> false
                    "show" -> true
                    else -> if (row.has("show") && !row.has("episode")) true else if (row.has("movie")) false else continue
                }
                val ids = row.optJSONObject(if (isSeries) "show" else "movie")?.optJSONObject("ids") ?: continue
                val title = RatingTitle.from(MediaRef(isSeries, ids.optString("imdb"), ids.optInt("tmdb", 0))) ?: continue
                val value = row.optInt(if (simkl) "user_rating" else "rating", -1)
                if (value !in 1..10) continue
                val at = runCatching { Instant.parse(row.optString(if (simkl) "user_rated_at" else "rated_at")) }.getOrNull()
                out.add(PersonalRating(title, value, at))
            }
        }
        if (provider == RatingProvider.TRAKT) fold(JSONArray(body), null, false) else {
            val root = JSONObject(body)
            require(listOf("movies", "shows", "anime").any(root::has))
            for (bucket in listOf("movies", "shows", "anime")) {
                if (root.has(bucket) && !root.isNull(bucket)) fold(root.getJSONArray(bucket), bucket != "movies", true)
            }
        }
        out
    }.getOrNull()
}

internal object PersonalRatings {
    val controller = PersonalRatingsController()
}
