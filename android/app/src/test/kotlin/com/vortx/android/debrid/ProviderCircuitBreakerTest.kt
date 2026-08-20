package com.vortx.android.debrid

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Deterministic tests for the shared [ProviderCircuitBreaker]. The breaker takes an injected clock, so time
/// is advanced explicitly instead of sleeping through real cooldown windows. Mirrors the invariants the Apple
/// `ProviderCircuitBreaker` doc states: a single blip self-heals, a rate limit trips on the first occurrence,
/// a cooldown grants exactly one half-open probe, and an abandoned probe re-arms.
class ProviderCircuitBreakerTest {
    private var nowMs = 0L
    private fun breaker() = ProviderCircuitBreaker { nowMs }

    @Test
    fun `closed circuit allows an attempt`() {
        val b = breaker()
        assertTrue(b.shouldAttempt("torBox", "id1"))
    }

    @Test
    fun `rate limit trips on the first occurrence and blocks until the cooldown lifts`() {
        val b = breaker()
        assertTrue(b.shouldAttempt("torBox", "id1"))
        b.recordFailure("torBox", "id1", ProviderCircuitBreaker.Phase.DISCOVER, ProviderCircuitBreaker.FailureReason.HttpStatus(429))
        // Open on the FIRST 429, no streak needed.
        assertFalse(b.shouldAttempt("torBox", "id1"))
        assertTrue(b.status("torBox", "id1").state is ProviderCircuitBreaker.State.Open)
        // A DIFFERENT source is unaffected (keyed by provider + source).
        assertTrue(b.shouldAttempt("torBox", "id2"))
        // Past the cooldown, the circuit grants a probe.
        nowMs += ProviderCircuitBreaker.DEFAULT_COOLDOWN_MS
        assertTrue(b.shouldAttempt("torBox", "id1"))
    }

    @Test
    fun `an explicit retry-after trips on the first occurrence`() {
        val b = breaker()
        b.recordFailure(
            "torBox", "id1", ProviderCircuitBreaker.Phase.RESOLVE,
            ProviderCircuitBreaker.FailureReason.Other("x"), retryAfterMs = 1_000L,
        )
        assertFalse(b.shouldAttempt("torBox", "id1"))
        nowMs += 1_000L
        assertTrue(b.shouldAttempt("torBox", "id1"))
    }

    @Test
    fun `an ordinary transport failure only trips after the streak threshold`() {
        val b = breaker()
        repeat(ProviderCircuitBreaker.CONSECUTIVE_FAILURE_THRESHOLD - 1) {
            b.recordFailure("rd", "h", ProviderCircuitBreaker.Phase.RESOLVE, ProviderCircuitBreaker.FailureReason.Other("transport"))
            // Still closed: a single blip (or two) self-heals with no backoff.
            assertTrue(b.shouldAttempt("rd", "h"))
        }
        // The threshold-th consecutive failure trips it.
        b.recordFailure("rd", "h", ProviderCircuitBreaker.Phase.RESOLVE, ProviderCircuitBreaker.FailureReason.Other("transport"))
        assertFalse(b.shouldAttempt("rd", "h"))
    }

    @Test
    fun `a success resets the streak so a later blip self-heals`() {
        val b = breaker()
        b.recordFailure("rd", "h", ProviderCircuitBreaker.Phase.RESOLVE, ProviderCircuitBreaker.FailureReason.Other("transport"))
        b.recordFailure("rd", "h", ProviderCircuitBreaker.Phase.RESOLVE, ProviderCircuitBreaker.FailureReason.Other("transport"))
        b.recordSuccess("rd", "h")
        assertTrue(b.status("rd", "h").state is ProviderCircuitBreaker.State.Closed)
        assertEquals(0, b.status("rd", "h").consecutiveFailures)
        // A fresh failure now starts a new streak from zero, so it does not trip immediately.
        b.recordFailure("rd", "h", ProviderCircuitBreaker.Phase.RESOLVE, ProviderCircuitBreaker.FailureReason.Other("transport"))
        assertTrue(b.shouldAttempt("rd", "h"))
    }

    @Test
    fun `a cooldown grants exactly one half-open probe`() {
        val b = breaker()
        b.recordFailure("torBox", "id1", ProviderCircuitBreaker.Phase.DISCOVER, ProviderCircuitBreaker.FailureReason.HttpStatus(429))
        nowMs += ProviderCircuitBreaker.DEFAULT_COOLDOWN_MS
        assertTrue(b.shouldAttempt("torBox", "id1"))   // the single probe
        assertFalse(b.shouldAttempt("torBox", "id1"))  // every other caller blocked while the probe is live
    }

    @Test
    fun `a failed half-open probe re-arms the full cooldown`() {
        val b = breaker()
        b.recordFailure("torBox", "id1", ProviderCircuitBreaker.Phase.DISCOVER, ProviderCircuitBreaker.FailureReason.HttpStatus(429))
        nowMs += ProviderCircuitBreaker.DEFAULT_COOLDOWN_MS
        assertTrue(b.shouldAttempt("torBox", "id1"))   // probe granted (half-open)
        b.recordFailure("torBox", "id1", ProviderCircuitBreaker.Phase.DISCOVER, ProviderCircuitBreaker.FailureReason.Other("still down"))
        assertFalse(b.shouldAttempt("torBox", "id1"))  // re-armed immediately, still cooling down
    }

    @Test
    fun `an abandoned half-open probe re-arms after the probe timeout`() {
        val b = breaker()
        b.recordFailure("torBox", "id1", ProviderCircuitBreaker.Phase.DISCOVER, ProviderCircuitBreaker.FailureReason.HttpStatus(429))
        nowMs += ProviderCircuitBreaker.DEFAULT_COOLDOWN_MS
        assertTrue(b.shouldAttempt("torBox", "id1"))   // probe issued, never reported
        assertFalse(b.shouldAttempt("torBox", "id1"))  // live probe
        nowMs += ProviderCircuitBreaker.HALF_OPEN_PROBE_TIMEOUT_MS
        assertTrue(b.shouldAttempt("torBox", "id1"))   // abandoned probe -> a fresh one is issued
    }

    @Test
    fun `retryAfterMillis parses seconds and rejects garbage`() {
        assertEquals(5_000L, ProviderCircuitBreaker.retryAfterMillis("5"))
        assertEquals(0L, ProviderCircuitBreaker.retryAfterMillis("0"))
        assertNull(ProviderCircuitBreaker.retryAfterMillis("not-a-number"))
        assertNull(ProviderCircuitBreaker.retryAfterMillis(null))
        assertNull(ProviderCircuitBreaker.retryAfterMillis(""))
    }
}
