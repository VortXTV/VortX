package com.vortx.android.debrid

/// Shared, process-lifetime circuit breaker for provider network failures across every caller: the TorBox
/// search-index lookup and the debrid resolve/download/stream calls. Keyed by (provider, stable source
/// identity) so ONE tripped circuit is visible to every view, refresh, and player instance that might touch
/// the same provider/source pair, instead of each of them keeping its own private retry memory. The Kotlin
/// port of Apple `app/SourcesShared/ProviderCircuitBreaker.swift`.
///
/// WHY THIS EXISTS: [com.vortx.android.torbox.TorBoxSearchSource] used to track its own `cooldownUntilMs` as
/// plain instance state on a per-detail-screen object. Every navigation away and back rebuilt a fresh
/// `TorBoxSearchSource`, so a provider that had JUST answered a 429 or gone transport-dark got hit again
/// immediately by the next screen, forever, because nothing outside that one dead instance remembered the
/// failure. Moving the memory into a shared process singleton, keyed by content identity rather than view
/// identity, closes that hole for the search path and for the debrid resolve/download path, which had no
/// persistent failure memory of its own at all.
///
/// The Apple version is an `actor`; here the same state is guarded by a plain monitor lock ([lock]) because
/// every operation is a cheap, non-suspending map mutation. Callers on Apple `await`; on Android they call
/// these synchronous methods directly from any thread.
class ProviderCircuitBreaker internal constructor(
    /// Injected clock (epoch millis) so a standalone JVM test can advance time deterministically instead of
    /// sleeping through real cooldown windows. Production always uses the default ([System.currentTimeMillis]).
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    /// Where in the playback pipeline a recorded failure happened. [DISCOVER] is the TorBox search-index
    /// lookup (not a debrid call at all); [RESOLVE] is minting a fresh direct link from a torrent/nzb;
    /// [DOWNLOAD] is regenerating an already-resolved link (the Continue-Watching fast path); [STREAM] is
    /// reserved for a future caller attributing a data-plane failure once a URL is already playing. Nothing
    /// wires [STREAM] today: that failure class belongs to the player watchdogs, not a provider HTTP call
    /// this breaker can gate. Mirrors the Apple `Phase`.
    enum class Phase { DISCOVER, RESOLVE, DOWNLOAD, STREAM }

    /// The classified cause of one recorded failure, carried alongside the phase/timestamp so a diagnostic
    /// dump (or a future recovery policy) can tell a rate limit apart from a dead host apart from a decode
    /// failure without re-deriving it from a free-text string. Mirrors the Apple `FailureReason` (Apple's
    /// `network(URLError.Code)` becomes [Network] carrying a short cause string, since Android has no
    /// `URLError.Code`).
    sealed interface FailureReason {
        data class HttpStatus(val code: Int) : FailureReason
        data class Network(val detail: String) : FailureReason
        data class Other(val detail: String) : FailureReason
    }

    data class FailureRecord(
        val reason: FailureReason,
        val phase: Phase,
        /// Cooldown hint in millis parsed from a `Retry-After` header, or null.
        val retryAfterMs: Long?,
        val timestampMs: Long,
    )

    sealed interface State {
        data object Closed : State
        data class Open(val untilMs: Long, val reason: FailureReason) : State
        data object HalfOpen : State
    }

    /// A read-only snapshot for diagnostics/tests; never mutates the entry it describes. Mirrors Apple `Status`.
    data class Status(
        val state: State,
        val consecutiveFailures: Int,
        val lastFailure: FailureRecord?,
    )

    private data class Entry(
        var state: State = State.Closed,
        var consecutiveFailures: Int = 0,
        var lastFailure: FailureRecord? = null,
        /// When the current half-open probe was issued, so an abandoned probe (its owning coroutine was
        /// cancelled, or its screen torn down, before reporting an outcome) does not wedge the circuit shut
        /// forever; a stale probe is treated as abandoned and a fresh one is issued.
        var halfOpenSinceMs: Long? = null,
    )

    private data class Key(val provider: String, val sourceId: String)

    private val lock = Any()
    private val entries = HashMap<Key, Entry>()

    /// Whether the caller may contact this (provider, source) right now.
    ///
    /// - Closed: always true.
    /// - Open before `until`: false, no network.
    /// - Open at/after `until`: transitions to HalfOpen and returns true ONCE, the single probe this circuit
    ///   allows after a cooldown; every other caller that arrives while that probe is outstanding sees
    ///   HalfOpen and gets false, so a second view/refresh cannot pile a duplicate request onto a provider
    ///   that is still being probed.
    /// - HalfOpen with a live probe: false.
    /// - HalfOpen with an abandoned probe (past [HALF_OPEN_PROBE_TIMEOUT_MS]): re-arms a fresh probe and
    ///   returns true, so a cancelled/torn-down caller can never permanently wedge the circuit shut.
    ///
    /// The caller that receives true for an open/half-open circuit OWNS reporting the outcome via
    /// [recordSuccess] or [recordFailure]; a caller that never reports (it was itself cancelled) simply leaves
    /// the probe to expire and be reissued to the next caller. Mirrors the Apple `shouldAttempt`.
    fun shouldAttempt(provider: String, sourceId: String): Boolean = synchronized(lock) {
        val key = Key(provider, sourceId)
        val entry = entries[key] ?: Entry()
        when (val state = entry.state) {
            is State.Closed -> true
            is State.HalfOpen -> {
                val since = entry.halfOpenSinceMs
                if (since != null && now() - since < HALF_OPEN_PROBE_TIMEOUT_MS) {
                    false
                } else {
                    entry.halfOpenSinceMs = now()
                    entries[key] = entry
                    true
                }
            }
            is State.Open -> {
                if (now() < state.untilMs) {
                    false
                } else {
                    entry.state = State.HalfOpen
                    entry.halfOpenSinceMs = now()
                    entries[key] = entry
                    true
                }
            }
        }
    }

    /// Report a completed, successful attempt: fully resets the circuit to Closed with a zeroed streak,
    /// whether it was closed, half-open (the probe passed), or, defensively, still open. Mirrors the Apple
    /// `recordSuccess`.
    fun recordSuccess(provider: String, sourceId: String) = synchronized(lock) {
        entries.remove(Key(provider, sourceId))
        Unit
    }

    /// Report a completed, failed attempt. Trip policy:
    /// - a half-open probe that fails re-arms the full cooldown immediately (the provider is still down);
    /// - an HTTP 429 or an explicit [retryAfterMs] trips on the FIRST occurrence (the server told us to back
    ///   off; there is nothing to gain from accumulating a streak first);
    /// - an ordinary transport/network/other failure only trips after [CONSECUTIVE_FAILURE_THRESHOLD] in a
    ///   row, so one offline blip self-heals on the very next attempt with no backoff at all.
    /// Mirrors the Apple `recordFailure`.
    fun recordFailure(
        provider: String,
        sourceId: String,
        phase: Phase,
        reason: FailureReason,
        retryAfterMs: Long? = null,
    ) = synchronized(lock) {
        val key = Key(provider, sourceId)
        val entry = entries[key] ?: Entry()
        entry.consecutiveFailures += 1
        val timestamp = now()
        entry.lastFailure = FailureRecord(reason, phase, retryAfterMs, timestamp)

        val isRateLimited = reason is FailureReason.HttpStatus && reason.code == 429
        val wasHalfOpen = entry.state is State.HalfOpen

        if (!(wasHalfOpen || isRateLimited || retryAfterMs != null ||
                entry.consecutiveFailures >= CONSECUTIVE_FAILURE_THRESHOLD)
        ) {
            entry.state = State.Closed
            entries[key] = entry
            return@synchronized
        }
        val cooldown = minOf(retryAfterMs ?: DEFAULT_COOLDOWN_MS, MAX_COOLDOWN_MS)
        entry.state = State.Open(untilMs = timestamp + cooldown, reason = reason)
        entries[key] = entry
    }

    /// Read-only snapshot for diagnostics/tests. Never observed by [shouldAttempt]/[recordFailure] itself.
    /// Mirrors the Apple `status`.
    fun status(provider: String, sourceId: String): Status = synchronized(lock) {
        val entry = entries[Key(provider, sourceId)] ?: Entry()
        Status(entry.state, entry.consecutiveFailures, entry.lastFailure)
    }

    companion object {
        /// The process-wide singleton every real caller shares. Mirrors the Apple `static let shared`.
        val shared = ProviderCircuitBreaker()

        /// Default cooldown once a circuit trips with no explicit `Retry-After`. Mirrors the ~15 minute window
        /// the TorBox scraper cooldown this replaces already used.
        const val DEFAULT_COOLDOWN_MS = 15L * 60L * 1000L

        /// A malformed or deliberately huge `Retry-After` must not wedge a provider closed indefinitely.
        const val MAX_COOLDOWN_MS = 60L * 60L * 1000L

        /// A single blip self-heals with no backoff at all; only a PERSISTENT streak of ordinary failures
        /// trips the circuit. A rate limit or an explicit `Retry-After` trips on the FIRST occurrence instead.
        const val CONSECUTIVE_FAILURE_THRESHOLD = 3

        /// How long a half-open probe may stay outstanding before it is considered abandoned.
        const val HALF_OPEN_PROBE_TIMEOUT_MS = 30L * 1000L

        /// Parse an HTTP `Retry-After` header value (seconds, or an RFC 7231 HTTP-date) into a millis interval
        /// from now. Null on anything unparseable, so a malformed header never manufactures a bogus interval;
        /// the caller then falls back to [recordFailure]'s own default cooldown. Mirrors the Apple
        /// `retryAfterSeconds(from:)`.
        fun retryAfterMillis(headerValue: String?, nowMs: Long = System.currentTimeMillis()): Long? {
            val value = headerValue?.trim().orEmpty()
            if (value.isEmpty()) return null
            value.toLongOrNull()?.let { seconds -> if (seconds >= 0) return seconds * 1000L }
            val date = runCatching {
                java.time.ZonedDateTime.parse(value, java.time.format.DateTimeFormatter.RFC_1123_DATE_TIME)
            }.getOrNull() ?: return null
            val deltaMs = date.toInstant().toEpochMilli() - nowMs
            return if (deltaMs > 0) deltaMs else 0L
        }
    }
}
