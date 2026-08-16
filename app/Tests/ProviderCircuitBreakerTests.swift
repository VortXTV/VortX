// Standalone strict executable for the production shared circuit breaker.
//
// Run with:
//   swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -o /tmp/provider-circuit-breaker \
//     app/SourcesShared/ProviderCircuitBreaker.swift \
//     app/Tests/ProviderCircuitBreakerTests.swift && /tmp/provider-circuit-breaker
//
// Compiles the exact production actor with no stubs (it depends on nothing but Foundation). Time is driven
// by an injected clock (`ProviderCircuitBreaker.init(now:)`) so every cooldown/half-open-timeout scenario
// below runs in milliseconds instead of sleeping through real 15-minute/30-second windows.

import Foundation

@MainActor private var failures = 0

@MainActor
private func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

/// A mutable box the test can advance between calls; the breaker reads it through the injected closure.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

@main
private enum ProviderCircuitBreakerTests {
    @MainActor
    static func main() async {
        await testClosedByDefault()
        await testOrdinaryFailureNeedsAStreak()
        await testSuccessResetsTheStreak()
        await testRateLimitTripsOnFirstOccurrence()
        await testExplicitRetryAfterTripsOnFirstOccurrenceAndSetsTheWindow()
        await testCooldownIsClampedToMaxCooldown()
        await testHalfOpenAllowsExactlyOneProbe()
        await testFailedHalfOpenProbeReArmsTheFullCooldown()
        await testSuccessfulHalfOpenProbeFullyCloses()
        await testAbandonedHalfOpenProbeIsReissued()
        await testDifferentSourcesAndProvidersAreIndependent()
        testRetryAfterHeaderParsing()

        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILED")
            exit(1)
        }
    }

    @MainActor
    static func testClosedByDefault() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        check(
            await breaker.shouldAttempt(provider: "torBox", sourceID: "tt0000001"),
            "a never-seen (provider, source) pair starts closed and allows an attempt"
        )
    }

    @MainActor
    static func testOrdinaryFailureNeedsAStreak() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        let key = (provider: "torBox", sourceID: "tt0000002")
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .discover, reason: .other("offline"))
        check(
            await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "one ordinary failure self-heals: the very next attempt is still allowed, no backoff"
        )
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .discover, reason: .other("offline"))
        check(
            await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "two consecutive ordinary failures still self-heal (threshold is three)"
        )
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .discover, reason: .other("offline"))
        check(
            await !breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "the THIRD consecutive ordinary failure trips the circuit"
        )
    }

    @MainActor
    static func testSuccessResetsTheStreak() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        let key = (provider: "realDebrid", sourceID: "abc123")
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .resolve, reason: .other("blip"))
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .resolve, reason: .other("blip"))
        await breaker.recordSuccess(provider: key.provider, sourceID: key.sourceID)
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .resolve, reason: .other("blip"))
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .resolve, reason: .other("blip"))
        check(
            await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "a success zeroes the streak: two more failures after it are still under threshold"
        )
    }

    @MainActor
    static func testRateLimitTripsOnFirstOccurrence() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        let key = (provider: "torBox", sourceID: "tt0000003")
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .discover, reason: .httpStatus(429))
        check(
            await !breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "a single HTTP 429 trips the circuit immediately, no streak required"
        )
        let status = await breaker.status(provider: key.provider, sourceID: key.sourceID)
        check(status.consecutiveFailures == 1, "the 429 trip still records exactly one consecutive failure")
    }

    @MainActor
    static func testExplicitRetryAfterTripsOnFirstOccurrenceAndSetsTheWindow() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        let key = (provider: "allDebrid", sourceID: "def456")
        await breaker.recordFailure(
            provider: key.provider, sourceID: key.sourceID, phase: .resolve,
            reason: .httpStatus(503), retryAfter: 120
        )
        check(
            await !breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "an explicit Retry-After trips the circuit on the first occurrence"
        )
        clock.advance(119)
        check(
            await !breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "one second short of the requested Retry-After window, still closed to new attempts"
        )
        clock.advance(2)
        check(
            await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "past the requested Retry-After window, the single half-open probe is granted"
        )
    }

    @MainActor
    static func testCooldownIsClampedToMaxCooldown() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        let key = (provider: "premiumize", sourceID: "ghi789")
        await breaker.recordFailure(
            provider: key.provider, sourceID: key.sourceID, phase: .resolve,
            reason: .httpStatus(429), retryAfter: 24 * 60 * 60
        )
        clock.advance(60 * 60 + 1)
        check(
            await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "a day-long Retry-After is clamped to the one-hour cooldown ceiling, not honoured verbatim"
        )
    }

    @MainActor
    static func testHalfOpenAllowsExactlyOneProbe() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        let key = (provider: "torBox", sourceID: "tt0000004")
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .discover, reason: .httpStatus(429))
        clock.advance(15 * 60 + 1)
        check(
            await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "past cooldown, the FIRST caller gets the half-open probe"
        )
        check(
            await !breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "a SECOND caller arriving while that probe is outstanding gets refused, not a duplicate probe"
        )
    }

    @MainActor
    static func testFailedHalfOpenProbeReArmsTheFullCooldown() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        let key = (provider: "torBox", sourceID: "tt0000005")
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .discover, reason: .httpStatus(429))
        clock.advance(15 * 60 + 1)
        _ = await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID)   // consume the probe
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .discover, reason: .other("still down"))
        check(
            await !breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "a failed half-open probe re-arms the full cooldown immediately"
        )
        clock.advance(15 * 60 + 1)
        check(
            await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "the re-armed cooldown itself still expires and grants exactly one more probe"
        )
    }

    @MainActor
    static func testSuccessfulHalfOpenProbeFullyCloses() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        let key = (provider: "torBox", sourceID: "tt0000006")
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .discover, reason: .httpStatus(429))
        clock.advance(15 * 60 + 1)
        _ = await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID)   // consume the probe
        await breaker.recordSuccess(provider: key.provider, sourceID: key.sourceID)
        let status = await breaker.status(provider: key.provider, sourceID: key.sourceID)
        check(status.consecutiveFailures == 0, "a successful probe zeroes the consecutive-failure count")
        check(
            await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "a successful probe fully closes the circuit for the next attempt"
        )
    }

    @MainActor
    static func testAbandonedHalfOpenProbeIsReissued() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        let key = (provider: "torBox", sourceID: "tt0000007")
        await breaker.recordFailure(provider: key.provider, sourceID: key.sourceID, phase: .discover, reason: .httpStatus(429))
        clock.advance(15 * 60 + 1)
        _ = await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID)   // probe issued, never reported
        clock.advance(31)                                                                  // past the 30s probe timeout
        check(
            await breaker.shouldAttempt(provider: key.provider, sourceID: key.sourceID),
            "an abandoned probe (its owner never reported success/failure) is reissued rather than wedging the circuit shut forever"
        )
    }

    @MainActor
    static func testDifferentSourcesAndProvidersAreIndependent() async {
        let clock = TestClock()
        let breaker = ProviderCircuitBreaker(now: clock.now)
        await breaker.recordFailure(provider: "torBox", sourceID: "tt0000008", phase: .discover, reason: .httpStatus(429))
        check(
            await breaker.shouldAttempt(provider: "torBox", sourceID: "tt0000009"),
            "a tripped circuit for one content id does not affect a different content id"
        )
        check(
            await breaker.shouldAttempt(provider: "realDebrid", sourceID: "tt0000008"),
            "a tripped circuit for one provider does not affect a different provider on the SAME source id"
        )
    }

    @MainActor
    static func testRetryAfterHeaderParsing() {
        func response(_ value: String?) -> HTTPURLResponse? {
            guard let value, let url = URL(string: "https://example.com") else { return nil }
            return HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": value])
        }
        check(
            ProviderCircuitBreaker.retryAfterSeconds(from: response("120")) == 120,
            "a numeric Retry-After parses as seconds"
        )
        check(
            ProviderCircuitBreaker.retryAfterSeconds(from: response(nil)) == nil,
            "no Retry-After header yields nil"
        )
        check(
            ProviderCircuitBreaker.retryAfterSeconds(from: response("not-a-date")) == nil,
            "an unparseable Retry-After yields nil rather than a bogus interval"
        )
        let future = Date().addingTimeInterval(90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let httpDate = formatter.string(from: future)
        let parsed = ProviderCircuitBreaker.retryAfterSeconds(from: response(httpDate))
        check(
            parsed != nil && abs((parsed ?? 0) - 90) < 2,
            "an RFC 7231 HTTP-date Retry-After parses to a seconds-from-now interval"
        )
    }
}
