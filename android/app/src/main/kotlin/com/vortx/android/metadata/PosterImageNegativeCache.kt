package com.vortx.android.metadata

import android.os.SystemClock
import java.security.MessageDigest

/**
 * Status-classified negative cache for poster / catalog art fetches, the Kotlin port of Apple
 * `PosterImageNegativeCachePolicy` + `PosterImageNegativeCache` (PosterImageLoader.swift). Coil already owns
 * the bounded concurrency, off-main decode, and disk cache; this adds the one thing it does not: a short
 * suppression window so a card that just failed does not re-hammer the network on every scroll, with the
 * expiry chosen by WHY it failed.
 *
 * A response that cannot become an image without the resource changing (400/404/405/406/410/411/413/414/
 * 415/416/422 -> [Failure.TERMINAL]) gets the long expiry; authentication, throttling, timeouts, and server
 * failures ([Failure.TRANSIENT]) retry after a short backoff. A 2xx clears any prior negative.
 *
 * PRIVACY (matching Apple): the URL is retained only as a SHA-256 digest of its normalized host+path, so a
 * signed query value or a title id never becomes long-lived cache metadata. Bounded by insertion order so a
 * long browse across many failing hosts can never grow it without limit.
 */
object PosterImageNegativeCache {

    private const val TRANSIENT_TTL_MS = 5_000L
    private const val TERMINAL_TTL_MS = 10 * 60 * 1000L
    private const val CAPACITY = 512

    enum class Failure { TRANSIENT, TERMINAL }

    private data class Entry(val expiresAt: Long, val sequence: Long)

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    private var nextSequence = 0L

    /** Terminal-vs-transient classification for an HTTP status, or null when the status is a success. */
    fun classify(status: Int): Failure? {
        if (status in 200..299) return null
        return if (status in TERMINAL_STATUSES) Failure.TERMINAL else Failure.TRANSIENT
    }

    private val TERMINAL_STATUSES = setOf(400, 404, 405, 406, 410, 411, 413, 414, 415, 416, 422)

    /** Stable, privacy-preserving key for a URL: SHA-256 of its lowercased host + path (no query/fragment). */
    fun key(host: String?, path: String?): String {
        val normalized = "${host?.lowercase().orEmpty()}${path.orEmpty()}"
        val digest = MessageDigest.getInstance("SHA-256").digest(normalized.toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) sb.append("%02x".format(b.toInt() and 0xFF))
        return sb.toString()
    }

    /** True when [key]'s last failure is still inside its TTL, so the caller should not re-fetch yet. */
    fun shouldSuppress(key: String, now: Long = SystemClock.elapsedRealtime()): Boolean = synchronized(lock) {
        val entry = entries[key] ?: return false
        if (entry.expiresAt <= now) {
            entries.remove(key)
            return false
        }
        true
    }

    /** Record a failure for [key] with the TTL for its [failure] class, evicting the oldest if over capacity. */
    fun record(key: String, failure: Failure, now: Long = SystemClock.elapsedRealtime()) = synchronized(lock) {
        purgeExpired(now)
        val ttl = if (failure == Failure.TERMINAL) TERMINAL_TTL_MS else TRANSIENT_TTL_MS
        entries[key] = Entry(expiresAt = now + ttl, sequence = nextSequence++)
        if (entries.size > CAPACITY) {
            val oldest = entries.minByOrNull { it.value.sequence }?.key
            if (oldest != null) entries.remove(oldest)
        }
    }

    /** Clear any negative for [key] (a subsequent success). */
    fun clear(key: String) = synchronized(lock) { entries.remove(key); Unit }

    private fun purgeExpired(now: Long) {
        val expired = entries.filterValues { it.expiresAt <= now }.keys.toList()
        for (k in expired) entries.remove(k)
    }
}
