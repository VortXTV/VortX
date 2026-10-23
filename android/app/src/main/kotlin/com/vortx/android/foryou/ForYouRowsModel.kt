package com.vortx.android.foryou

import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.ZoneOffset

/** One fetched For You row: an interest row (with its plan) or a smart collection pinned to Home. */
data class ForYouInterestRow(val plan: ForYouRowPlan, val items: List<MetaItem>)
data class ForYouCollectionRow(val collection: SmartCollection, val items: List<MetaItem>)
data class ForYouRows(val interest: List<ForYouInterestRow> = emptyList(), val collections: List<ForYouCollectionRow> = emptyList())

/**
 * Home's For You rows and pinned smart collection rows; a port of Apple `ForYouRowsModel`.
 *
 * Fetching is keyed only by what changes the query (profile, interests or rules, and the day, since
 * "released by today" moves); raw results are cached, and library ownership plus "hide what I've
 * watched" are applied on publish, so a library change re-filters without refetching. Rows are fetched
 * one at a time and published as each lands. Call from one thread (the owning view model's scope).
 */
internal class ForYouRowsModel(
    private val scope: CoroutineScope,
    private val ruleTitles: suspend (String?, String?) -> List<MetaItem> = { movie, tv -> ForYouTmdb.ruleTitles(movie, tv) },
    private val personTitles: suspend (Int) -> List<MetaItem> = { ForYouTmdb.personTopTitles(it) },
    private val today: () -> LocalDate = { LocalDate.now(ZoneOffset.UTC) },
    private val onRows: (ForYouRows) -> Unit,
) {
    private var interestKey: String? = null
    private var collectionKey: String? = null
    private var interestRaw: List<ForYouInterestRow> = emptyList()
    private val collectionRaw = HashMap<String, List<MetaItem>>()
    private var interestJob: Job? = null
    private var collectionJob: Job? = null
    private var collectionRequest: Any? = null
    private var owned: Set<String> = emptySet()
    private var watched: Set<String> = emptySet()
    private var pinned: List<SmartCollection> = emptyList()
    private var published = ForYouRows()

    /** [enabled] is false for a kids profile or before the profile's saved choices are known: clear. */
    fun refresh(profileId: String?, interests: ForYouInterests?, collections: List<SmartCollection>,
                owned: Set<String>, watched: Set<String>, enabled: Boolean) {
        this.owned = owned
        this.watched = watched
        if (!enabled || profileId == null) { clear(); return }
        val day = today()
        refreshInterests(profileId, interests, day)
        refreshCollections(profileId, collections.filter { it.home }, day)
        publish()
    }

    fun clear() {
        collectionRequest = null
        interestJob?.cancel(); collectionJob?.cancel()
        interestJob = null; collectionJob = null
        interestKey = null; collectionKey = null
        interestRaw = emptyList(); collectionRaw.clear(); pinned = emptyList()
        publish()
    }

    private fun refreshInterests(profileId: String, interests: ForYouInterests?, day: LocalDate) {
        val plan = interests?.let { ForYouQuery.plan(it, day) }.orEmpty()
        val key = "$profileId|$day|" + plan.joinToString(",") { "${it.id}=${it.source}" }
        if (key == interestKey) return
        interestJob?.cancel()
        interestKey = key
        interestRaw = emptyList()
        if (plan.isEmpty()) return
        interestJob = scope.launch {
            for (row in plan) {
                val items = when (val source = row.source) {
                    is ForYouSource.Discover -> ruleTitles(source.movie, source.tv)
                    is ForYouSource.Person -> personTitles(source.id)
                }
                if (interestKey != key) return@launch
                interestRaw = interestRaw + ForYouInterestRow(row, items)
                publish()
            }
            // An all-empty result is most likely a failed fetch: forget the key so the next refresh retries.
            if (interestKey == key && interestRaw.all { it.items.isEmpty() }) interestKey = null
        }
    }

    private fun refreshCollections(profileId: String, collections: List<SmartCollection>, day: LocalDate) {
        pinned = collections
        val key = "$profileId|$day|" + collections.joinToString(",") { "${it.id}=${it.rules}" }
        if (key == collectionKey) return
        collectionRequest = null
        collectionJob?.cancel()
        collectionKey = key
        val wanted = collections.map(::rawKey).toSet()
        collectionRaw.keys.retainAll(wanted)
        val missing = collections.filter { rawKey(it) !in collectionRaw }
        if (missing.isEmpty()) return
        val request = Any()
        collectionRequest = request
        collectionJob = scope.launch {
            try {
                for (collection in missing) {
                    val items = try { titles(collection.rules, ruleTitles, day) }
                        catch (cancel: CancellationException) { throw cancel }
                        catch (_: Exception) { emptyList() }
                    coroutineContext.ensureActive()
                    if (collectionRequest !== request || collectionKey != key) return@launch
                    if (items.isNotEmpty()) collectionRaw[rawKey(collection)] = items
                    publish()
                }
            } finally {
                // Retain successful raw rows, including rows hidden by the watched filter. Empty/failing
                // rows retry only on a later refresh; a retired request cannot reset a replacement's key.
                if (collectionRequest === request && collectionKey == key) {
                    collectionRequest = null
                    if (missing.any { rawKey(it) !in collectionRaw }) collectionKey = null
                }
            }
        }
    }

    private fun publish() {
        val rows = ForYouRows(
            interest = interestRaw.mapNotNull { row ->
                row.items.filterNot { it.id in owned }.takeIf { it.isNotEmpty() }?.let { ForYouInterestRow(row.plan, it) }
            },
            collections = pinned.mapNotNull { collection ->
                val raw = collectionRaw[rawKey(collection)] ?: return@mapNotNull null
                val items = if (collection.rules.hideWatched) raw.filterNot { it.id in watched } else raw
                items.takeIf { it.isNotEmpty() }?.let { ForYouCollectionRow(collection, it) }
            },
        )
        if (rows != published) { published = rows; onRows(rows) }
    }

    companion object {
        /** Raw results depend only on the rules, so renaming or pinning a collection reuses them. */
        fun rawKey(collection: SmartCollection) = "${collection.id}|${collection.rules}"

        /** Titles for one collection's rules (also the builder's live preview). */
        suspend fun titles(rules: SmartCollectionRules,
                           ruleTitles: suspend (String?, String?) -> List<MetaItem> = { movie, tv -> ForYouTmdb.ruleTitles(movie, tv) },
                           day: LocalDate = LocalDate.now(ZoneOffset.UTC)): List<MetaItem> {
            val source = ForYouQuery.collectionSource(rules, day)
            return ruleTitles(source.movie, source.tv)
        }
    }
}
