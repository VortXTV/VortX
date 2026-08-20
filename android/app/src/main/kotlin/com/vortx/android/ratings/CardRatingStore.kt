package com.vortx.android.ratings

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Process-wide memoized ratings-by-id cache over the keyless VortX ratings service ([VortXRatingsClient]),
 * the Kotlin port of Apple `CardRatingStore` (CardRatingBadge.swift). A rail of landscape cards makes at
 * most one request per id (misses cached too, so a title with no rating is not re-fetched on every reappear)
 * and a recycled cell repaints from memory.
 *
 * A stored key with a null value is a REMEMBERED MISS (looked up, no rating), distinct from an unseen id;
 * `containsKey` tells the two apart. In-flight requests are deduped so overlapping card batches for the same
 * id don't double-fetch. Thread-safe via a [Mutex] (Apple relies on `@MainActor`; Android may call from any
 * card coroutine).
 */
object CardRatingStore {

    private val lock = Mutex()
    private val cache = HashMap<String, MdbListRatings?>()
    private val inflight = HashMap<String, CompletableDeferred<MdbListRatings?>>()

    /** Cross-provider ratings for an id (keyless), memoized. Null on a miss (remembered so it isn't refetched). */
    suspend fun ratings(id: String, type: String): MdbListRatings? {
        val owned = CompletableDeferred<MdbListRatings?>()
        val existing: CompletableDeferred<MdbListRatings?>? = lock.withLock {
            if (cache.containsKey(id)) return cache[id]
            val inFlight = inflight[id]
            if (inFlight != null) {
                inFlight
            } else {
                inflight[id] = owned
                null
            }
        }
        if (existing != null) return existing.await()

        val value = VortXRatingsClient.ratings(id, type)
        lock.withLock {
            cache[id] = value
            inflight.remove(id)
        }
        owned.complete(value)
        return value
    }
}
