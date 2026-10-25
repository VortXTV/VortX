package com.vortx.android.trickplay

import kotlinx.coroutines.CompletableDeferred

/**
 * One small monitor for session metadata and immutable preview publication. Callbacks passed to
 * [withState] must not suspend, decode/crop a bitmap, touch disk or perform network I/O.
 *
 * Source and request claims are opaque identities, not value-equal content keys: A -> B -> A never
 * revives the first request. Repeated ticks for the same source/bucket are deliberately idempotent.
 */
internal class TrickplayPublication<T> {
    data class SourceIdentity(
        val isSeries: Boolean,
        val imdb: String?,
        val tmdb: Int?,
        val season: Int?,
        val episode: Int?,
    )

    class SourceClaim internal constructor(
        val identity: SourceIdentity,
        val consentGeneration: Long,
    )

    class Request internal constructor(val source: SourceClaim, val durationBucket: Int)

    class Preview<T> internal constructor(val request: Request, val key: String, val sheet: T?)

    private val monitor = Any()
    private var currentSource: SourceClaim? = null
    private var currentRequest: Request? = null
    private var closed = false
    @Volatile private var published: Preview<T>? = null

    fun <R> withState(block: () -> R): R = synchronized(monitor) { block() }

    fun configure(identity: SourceIdentity, generation: Long, bucket: Int): Request? = withState {
        if (closed) return@withState null
        val retained = currentSource
        val source = if (retained == null || retained.identity != identity || retained.consentGeneration != generation) {
            val replacement = SourceClaim(identity, generation)
            currentSource = replacement
            currentRequest = null
            published = null
            replacement
        } else retained
        if (currentRequest?.durationBucket == bucket) return@withState null
        Request(source, bucket).also { currentRequest = it; published = null }
    }

    fun bind(request: Request, key: String): Boolean = withState {
        if (!isCurrent(request)) return@withState false
        published = Preview(request, key, null)
        true
    }

    fun publish(request: Request, key: String, sheet: T): Boolean = withState {
        val expected = published
        if (!isCurrent(request) || expected == null || expected.request !== request || expected.key != key) {
            return@withState false
        }
        published = Preview(request, key, sheet)
        true
    }

    fun snapshot(): Preview<T>? = published

    fun isCurrent(request: Request): Boolean = withState {
        !closed && currentRequest === request && currentSource === request.source
    }

    fun isCurrent(source: SourceClaim): Boolean = withState { currentSource === source }

    fun isCurrent(preview: Preview<T>): Boolean = withState {
        !closed && published === preview && currentRequest === preview.request
    }

    /** Only new capture calls need the open check; calls admitted before close can finish in order. */
    fun captureSource(): SourceClaim? = withState { currentSource.takeUnless { closed } }

    /** Keep prior frame/final admissions valid, but deny new configuration/capture and fetched previews. */
    fun close(): SourceClaim? = withState {
        closed = true
        published = null
        currentSource
    }

    /** Consent revocation also retires every old source/request, including a later equal identity. */
    fun invalidate() = withState {
        currentSource = null
        currentRequest = null
        published = null
    }
}

/** One original-source IMDb lookup can serve a newer duration-bucket request without being recaptured. */
internal class TrickplayResolution(private val publication: TrickplayPublication<*>) {
    class Lookup internal constructor(val source: TrickplayPublication.SourceClaim) {
        val result = CompletableDeferred<String?>()
    }

    data class Admission(val lookup: Lookup, val startsLookup: Boolean)
    private var current: Lookup? = null

    fun admit(request: TrickplayPublication.Request): Admission? = publication.withState {
        if (!publication.isCurrent(request)) return@withState null
        val existing = current
        if (existing != null && existing.source === request.source) Admission(existing, false)
        else Lookup(request.source).also { current = it }.let { Admission(it, true) }
    }

    fun reset() = publication.withState { current = null }
}
