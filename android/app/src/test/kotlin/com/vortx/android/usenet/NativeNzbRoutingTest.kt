package com.vortx.android.usenet

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean

class NativeNzbRoutingTest {
    private val mirrors = listOf("https://one.invalid/api?nzb=token", "https://two.invalid/mirror")
    private val addon = listOf("nntps://addon:secret@one.invalid:563/5", "nntp://two.invalid:119/2")
    private val saved = listOf("nntps://saved:secret@three.invalid:563/6", "nntps://four.invalid:563/3")

    @Test fun `addon then saved are complete ordered arrays and cloud is last`() = runBlocking {
        val calls = mutableListOf<List<String>>()
        val result = NativeNzbRouting.resolve(mirrors, addon, saved, null, true, isCurrent = { true },
            local = { urls, providers -> assertEquals(mirrors, urls); calls += providers; throw NativeNzbTransport.Unavailable() },
            torBox = { url -> assertEquals(mirrors.first(), url); calls += listOf("cloud"); "https://cloud.invalid/media" })
        assertEquals(listOf(addon, saved, listOf("cloud")), calls)
        assertEquals("https://cloud.invalid/media", result?.url)
    }

    @Test fun `successful addon route never tries saved or cloud and transfers lease`() = runBlocking {
        var closed = 0
        val result = NativeNzbRouting.resolve(mirrors, addon, saved, null, true, isCurrent = { true },
            local = { _, providers -> assertEquals(addon, providers); NativeNzbPlayback("http://127.0.0.1:1/stream", AutoCloseable { closed++ }) },
            torBox = { fail("Unexpected cloud"); null })
        assertEquals(0, closed)
        requireNotNull(result).lease.close()
        assertEquals(1, closed)
    }

    @Test fun `positively cached TorBox mirror is selected without any local route`() = runBlocking {
        val result = NativeNzbRouting.resolve(mirrors, addon, saved, setOf(mirrors[1]), true, isCurrent = { true },
            local = { _, _ -> error("Cached cloud selection must not open native NNTP") },
            torBox = { assertEquals(mirrors[1], it); "https://cloud.invalid/cached" })
        assertEquals("https://cloud.invalid/cached", result?.url)
    }

    @Test fun `uncached gate permits local but never cloud add`() = runBlocking {
        assertNull(NativeNzbRouting.resolve(mirrors, emptyList(), emptyList(), emptySet(), true,
            isCurrent = { true }, local = { _, _ -> error("No providers") }, torBox = { error("Not cache confirmed") }))
    }

    @Test fun `owner change cancels pending resolve and never proceeds to saved or cloud`() = runBlocking {
        val active = AtomicBoolean(true)
        val entered = CompletableDeferred<Unit>()
        val released = CompletableDeferred<Unit>()
        val task = async {
            try {
                NativeNzbRouting.resolve(mirrors, addon, saved, null, true, isCurrent = active::get,
                    local = { _, providers ->
                        assertEquals(addon, providers); entered.complete(Unit)
                        try { awaitCancellation() } finally { released.complete(Unit) }
                    }, torBox = { error("Retired cloud request") })
            } catch (_: CancellationException) { null }
        }
        entered.await(); active.set(false)
        withTimeout(2_000) { released.await(); task.await() }
        Unit
    }

    @Test fun `late local result is closed when admission retires`() = runBlocking {
        var active = true
        var closed = 0
        try {
            NativeNzbRouting.resolve(mirrors, addon, saved, null, false, isCurrent = { active },
                local = { _, _ -> active = false; NativeNzbPlayback("local", AutoCloseable { closed++ }) },
                torBox = { error("No cloud") })
            fail("Retired result accepted")
        } catch (_: CancellationException) { }
        assertEquals(1, closed)
    }

    @Test fun `caller cancellation is terminal and never swallowed as provider fallback`() = runBlocking {
        var attempted = 0
        try {
            NativeNzbRouting.resolve(mirrors, addon, saved, null, true, isCurrent = { true },
                local = { _, _ -> attempted++; throw CancellationException("fixture") },
                torBox = { error("Cancellation must not start cloud") })
            fail("Cancellation swallowed")
        } catch (_: CancellationException) { }
        assertEquals(1, attempted)
    }
}
