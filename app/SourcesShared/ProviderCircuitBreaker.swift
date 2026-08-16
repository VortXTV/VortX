import Foundation

/// Shared, process-lifetime circuit breaker for provider network failures across every caller: the TorBox
/// search-index lookup and the debrid resolve/download/stream calls. Keyed by (provider, stable source
/// identity) so ONE tripped circuit is visible to every view, refresh, and player instance that might touch
/// the same provider/source pair, instead of each of them keeping its own private retry memory.
///
/// WHY THIS EXISTS: `TorBoxSearchSource` used to track its own `cooldownUntil` / `consecutiveTransportErrors`
/// as plain instance state on a per-detail-view `@StateObject`. Every navigation away and back (a "UI
/// refresh") built a fresh `TorBoxSearchSource`, so a provider that had JUST answered a 429 or gone
/// transport-dark got hit again immediately by the next view, forever, because nothing outside that one
/// dead instance remembered the failure. The diag-21 log shows exactly this: the same content id tripping
/// TorBox's scraper cooldown six separate times over the session. Moving the memory into a shared actor,
/// keyed by content identity rather than view identity, closes that hole for the search path and for the
/// debrid resolve/download path, which had no persistent failure memory of its own at all.
actor ProviderCircuitBreaker {
    static let shared = ProviderCircuitBreaker()

    /// Where in the playback pipeline a recorded failure happened. `.discover` is the TorBox search-index
    /// lookup (not a debrid call at all); `.resolve` is minting a fresh direct link from a torrent/nzb;
    /// `.download` is regenerating an already-resolved link (the Continue-Watching fast path); `.stream` is
    /// reserved for a future caller attributing a data-plane failure once a URL is already playing. Nothing
    /// wires `.stream` today: that failure class belongs to the player watchdogs, not a provider HTTP call
    /// this breaker can gate.
    enum Phase: String, Sendable {
        case discover
        case resolve
        case download
        case stream
    }

    /// The classified cause of one recorded failure, carried alongside the phase/timestamp so a diagnostic
    /// dump (or a future recovery policy) can tell a rate limit apart from a dead host apart from a decode
    /// failure without re-deriving it from a free-text string.
    enum FailureReason: Sendable, Equatable {
        case httpStatus(Int)
        case network(URLError.Code)
        case other(String)
    }

    struct FailureRecord: Sendable, Equatable {
        let reason: FailureReason
        let phase: Phase
        let retryAfter: TimeInterval?
        let timestamp: Date
    }

    enum State: Sendable, Equatable {
        case closed
        case open(until: Date, reason: FailureReason)
        case halfOpen
    }

    /// A read-only snapshot for diagnostics/tests; never mutates the entry it describes.
    struct Status: Sendable {
        let state: State
        let consecutiveFailures: Int
        let lastFailure: FailureRecord?
    }

    private struct Entry {
        var state: State = .closed
        var consecutiveFailures = 0
        var lastFailure: FailureRecord?
        /// When the current half-open probe was issued, so an abandoned probe (its owning task was
        /// cancelled, or its view torn down, before reporting an outcome) does not wedge the circuit shut
        /// forever; a stale probe is treated as abandoned and a fresh one is issued.
        var halfOpenSince: Date?
    }

    private struct Key: Hashable {
        let provider: String
        let sourceID: String
    }

    /// Default cooldown once a circuit trips with no explicit `Retry-After`. Mirrors the ~15 minute window
    /// the TorBox scraper cooldown this replaces already used.
    private static let defaultCooldown: TimeInterval = 15 * 60
    /// A malformed or deliberately huge `Retry-After` must not wedge a provider closed indefinitely.
    private static let maxCooldown: TimeInterval = 60 * 60
    /// A single blip self-heals with no backoff at all; only a PERSISTENT streak of ordinary failures trips
    /// the circuit. A rate limit or an explicit `Retry-After` trips on the FIRST occurrence instead (see
    /// `recordFailure`).
    private static let consecutiveFailureThreshold = 3
    /// How long a half-open probe may stay outstanding before it is considered abandoned.
    private static let halfOpenProbeTimeout: TimeInterval = 30

    private var entries: [Key: Entry] = [:]
    /// Injected clock so a standalone harness can advance time deterministically instead of sleeping through
    /// real cooldown windows. Production always uses the default (`Date()`).
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Whether the caller may contact this (provider, source) right now.
    ///
    /// - `.closed`: always `true`.
    /// - `.open` before `until`: `false`, no network.
    /// - `.open` at/after `until`: transitions to `.halfOpen` and returns `true` ONCE, the single probe this
    ///   circuit allows after a cooldown; every other caller that arrives while that probe is outstanding
    ///   sees `.halfOpen` and gets `false`, so a second view/refresh cannot pile a duplicate request onto a
    ///   provider that is still being probed.
    /// - `.halfOpen` with a live probe: `false`.
    /// - `.halfOpen` with an abandoned probe (past `halfOpenProbeTimeout`): re-arms a fresh probe and
    ///   returns `true`, so a cancelled/torn-down caller can never permanently wedge the circuit shut.
    ///
    /// The caller that receives `true` for an open/half-open circuit OWNS reporting the outcome via
    /// `recordSuccess` or `recordFailure`; a caller that never reports (it was itself cancelled) simply
    /// leaves the probe to expire and be reissued to the next caller.
    func shouldAttempt(provider: String, sourceID: String) -> Bool {
        let key = Key(provider: provider, sourceID: sourceID)
        var entry = entries[key] ?? Entry()
        switch entry.state {
        case .closed:
            return true
        case .halfOpen:
            if let since = entry.halfOpenSince, now().timeIntervalSince(since) < Self.halfOpenProbeTimeout {
                return false
            }
            entry.halfOpenSince = now()
            entries[key] = entry
            return true
        case let .open(until, _):
            guard now() >= until else { return false }
            entry.state = .halfOpen
            entry.halfOpenSince = now()
            entries[key] = entry
            return true
        }
    }

    /// Report a completed, successful attempt: fully resets the circuit to `.closed` with a zeroed streak,
    /// whether it was closed, half-open (the probe passed), or, defensively, still open.
    func recordSuccess(provider: String, sourceID: String) {
        entries[Key(provider: provider, sourceID: sourceID)] = nil
    }

    /// Report a completed, failed attempt. Trip policy:
    /// - a half-open probe that fails re-arms the full cooldown immediately (the provider is still down);
    /// - an HTTP 429 or an explicit `retryAfter` trips on the FIRST occurrence (the server told us to back
    ///   off; there is nothing to gain from accumulating a streak first);
    /// - an ordinary transport/network/other failure only trips after `consecutiveFailureThreshold` in a
    ///   row, so one offline blip self-heals on the very next attempt with no backoff at all.
    func recordFailure(
        provider: String, sourceID: String, phase: Phase, reason: FailureReason,
        retryAfter: TimeInterval? = nil
    ) {
        let key = Key(provider: provider, sourceID: sourceID)
        var entry = entries[key] ?? Entry()
        entry.consecutiveFailures += 1
        let timestamp = now()
        entry.lastFailure = FailureRecord(reason: reason, phase: phase, retryAfter: retryAfter, timestamp: timestamp)

        var isRateLimited = false
        if case .httpStatus(429) = reason { isRateLimited = true }
        var wasHalfOpen = false
        if case .halfOpen = entry.state { wasHalfOpen = true }

        guard wasHalfOpen || isRateLimited || retryAfter != nil
                || entry.consecutiveFailures >= Self.consecutiveFailureThreshold else {
            entry.state = .closed
            entries[key] = entry
            return
        }
        let cooldown = min(retryAfter ?? Self.defaultCooldown, Self.maxCooldown)
        entry.state = .open(until: timestamp.addingTimeInterval(cooldown), reason: reason)
        entries[key] = entry
    }

    /// Read-only snapshot for diagnostics/tests. Never observed by `shouldAttempt`/`recordFailure` itself.
    func status(provider: String, sourceID: String) -> Status {
        let entry = entries[Key(provider: provider, sourceID: sourceID)] ?? Entry()
        return Status(state: entry.state, consecutiveFailures: entry.consecutiveFailures, lastFailure: entry.lastFailure)
    }
}

extension ProviderCircuitBreaker {
    /// Parse an HTTP `Retry-After` header value (seconds, or an RFC 7231 HTTP-date) into a `TimeInterval`
    /// from now. `nil` on anything unparseable, so a malformed header never manufactures a bogus interval;
    /// the caller then falls back to `recordFailure`'s own default cooldown.
    nonisolated static func retryAfterSeconds(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
