package com.vortx.android.communityjs

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.Job
import okhttp3.HttpUrl.Companion.toHttpUrl

class CommunityJsProviderContractTest {
    @Test
    fun fixtureProviderMapsASelectableDirectSourceWithHeadersAndSubtitles() {
        val provider = CommunityJsProviderStore.Provider(
            id = "fixture",
            name = "Fixture provider",
            supportedTypes = setOf("movie"),
            code = "module.exports.getStreams = () => []",
            enabled = true,
        )
        val group = CommunityJsProviderSource.mapGroup(
            provider,
            listOf(
                CommunityJsRuntime.ProviderStream(
                    name = "Fixture source",
                    title = "Example feature",
                    url = "https://93.184.216.34/media.m3u8",
                    quality = "1080p",
                    size = "1.2 GB",
                    headers = mapOf("Referer" to "https://93.184.216.34/"),
                    subtitles = listOf(CommunityJsRuntime.Subtitle("https://93.184.216.34/sub.vtt", "en", "English", emptyMap())),
                ),
            ),
        )

        assertNotNull(group)
        val stream = requireNotNull(group).streams.single()
        assertEquals("1080p", stream.quality)
        assertEquals("https://93.184.216.34/media.m3u8", stream.url)
        assertEquals("https://93.184.216.34/", stream.requestHeaders["Referer"])
        assertEquals(listOf("https://93.184.216.34/sub.vtt"), stream.externalSubtitles)
        assertTrue(stream.communityJsTransport)
    }

    @Test
    fun networkPolicyRejectsLocalTargetsAndAcceptsAPublicLiteral() {
        assertFalse(CommunityJsUrlPolicy.isPublicHttpUrl("http://127.0.0.1:8080/stream"))
        assertFalse(CommunityJsUrlPolicy.isPublicHttpUrl("http://192.168.1.10/stream"))
        assertFalse(CommunityJsUrlPolicy.isPublicHttpsUrl("https://localhost/manifest.json"))
        assertTrue(CommunityJsUrlPolicy.isPublicHttpUrl("https://93.184.216.34/stream"))
    }

    @Test
    fun `refresh replacement cancels the prior provider invocation deterministically`() {
        val owner = CommunityJsRefreshJobOwner()
        val first = Job()
        val second = Job()

        owner.replace(first)
        owner.replace(second)

        assertTrue(first.isCancelled)
        assertFalse(second.isCancelled)
        owner.cancel()
        assertTrue(second.isCancelled)
    }

    @Test
    fun `new generation fences stale provider publication`() {
        val fence = CommunityJsGenerationFence()
        fence.begin(41)
        fence.begin(42)

        assertFalse(fence.publishIfCurrent(41) { error("stale request published") })
        assertTrue(fence.publishIfCurrent(42) {})
        fence.invalidate()
        assertFalse(fence.publishIfCurrent(42) { error("invalidated request published") })
    }

    @Test
    fun `cancellation closes broker execution admission before late binding`() {
        val admission = CommunityJsBrokerExecutionAdmission<String>()
        admission.cancel()

        assertNull(admission.reserveIfActive(broker = "late-broker", isActive = { true }))
    }

    @Test
    fun `cancellation between reservation and call denies the late execute`() {
        val admission = CommunityJsBrokerExecutionAdmission<String>()
        val lease = requireNotNull(admission.reserveIfActive(broker = "broker", isActive = { true }))

        assertEquals("broker", admission.cancel())
        assertFalse(admission.claimForCall(lease))
    }

    @Test
    fun `cancellation returns promptly while admitted binder call is blocked`() {
        class BlockingBroker {
            val executeEntered = CountDownLatch(1)
            val releaseExecute = CountDownLatch(1)
            val cancelCalled = CountDownLatch(1)

            fun execute() {
                executeEntered.countDown()
                assertTrue(releaseExecute.await(5, TimeUnit.SECONDS))
            }

            fun cancel() {
                cancelCalled.countDown()
            }
        }

        val admission = CommunityJsBrokerExecutionAdmission<BlockingBroker>()
        val broker = BlockingBroker()
        val lease = requireNotNull(admission.reserveIfActive(broker, isActive = { true }))
        assertTrue(admission.claimForCall(lease))
        val executeEntered = CountDownLatch(1)
        val cancelCompleted = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val execution = pool.submit {
                executeEntered.countDown()
                broker.execute()
            }
            assertTrue(executeEntered.await(5, TimeUnit.SECONDS))
            assertTrue(broker.executeEntered.await(5, TimeUnit.SECONDS))

            val cancellation = pool.submit {
                admission.cancel()?.cancel()
                cancelCompleted.countDown()
            }
            assertTrue(cancelCompleted.await(1, TimeUnit.SECONDS))
            assertTrue(broker.cancelCalled.await(1, TimeUnit.SECONDS))
            assertEquals(1L, broker.releaseExecute.count)

            broker.releaseExecute.countDown()
            execution.get(5, TimeUnit.SECONDS)
            cancellation.get(5, TimeUnit.SECONDS)
        } finally {
            broker.releaseExecute.countDown()
            pool.shutdownNow()
        }
    }

    @Test
    fun `broker tombstone rejects late execute within horizon then expires`() {
        var now = 1_000L
        val registry = CommunityJsCancellationRegistry(
            clockMs = { now },
            tombstoneHorizonMs = 100L,
            maxTombstones = 4,
        )

        registry.cancel("late-token")
        now = 1_099L
        assertNull(registry.begin("late-token"))

        now = 1_100L
        val afterExpiry = requireNotNull(registry.begin("late-token"))
        registry.finish("late-token", afterExpiry)
    }

    @Test
    fun `broker tombstone capacity evicts oldest first`() {
        var now = 0L
        val registry = CommunityJsCancellationRegistry(
            clockMs = { now },
            tombstoneHorizonMs = 10_000L,
            maxTombstones = 2,
        )

        registry.cancel("oldest")
        now += 1
        registry.cancel("middle")
        now += 1
        registry.cancel("newest")

        assertEquals(2, registry.tombstoneCountForTesting())
        val evicted = requireNotNull(registry.begin("oldest"))
        assertNull(registry.begin("middle"))
        assertNull(registry.begin("newest"))
        registry.finish("oldest", evicted)
    }

    @Test
    fun `tombstone pruning never evicts active cancellation flags`() {
        var now = 0L
        val registry = CommunityJsCancellationRegistry(
            clockMs = { now },
            tombstoneHorizonMs = 10_000L,
            maxTombstones = 1,
        )
        val running = requireNotNull(registry.begin("running-token"))

        registry.cancel("running-token")
        registry.cancel("tombstone-one")
        now += 1
        registry.cancel("tombstone-two")

        assertTrue(running.get())
        assertEquals(1, registry.activeCountForTesting())
        assertEquals(1, registry.tombstoneCountForTesting())
        registry.finish("running-token", running)
        assertEquals(0, registry.activeCountForTesting())
    }

    @Test
    fun `cancellation registry diagnostics never render tokens`() {
        val secretToken = "secret-provider-token"
        val registry = CommunityJsCancellationRegistry()
        registry.cancel(secretToken)

        assertFalse(registry.toString().contains(secretToken))
        assertTrue(registry.toString().contains("tombstones=1"))
    }

    @Test
    fun `origin policy keeps provider headers only on the exact origin`() {
        val root = "https://media.example/root/master.m3u8".toHttpUrl()
        val headers = mapOf(
            "Authorization" to "video-secret",
            "Cookie" to "session-secret",
            "X-Provider-Token" to "custom-secret",
            "Accept" to "application/vnd.apple.mpegurl",
            "User-Agent" to "provider-agent",
        )

        assertEquals(headers, CommunityJsHttpPolicy.requestHeaders(root, "https://media.example/root/key.bin".toHttpUrl(), headers))
        val crossOrigin = CommunityJsHttpPolicy.requestHeaders(root, "https://cdn.example/segment.ts".toHttpUrl(), headers)
        assertTrue(crossOrigin.isEmpty())
        assertEquals(
            setOf("Range", "Accept", "User-Agent"),
            CommunityJsHttpPolicy.transportHeaders(
                mapOf("Range" to "bytes=1-", "Accept" to "video/*", "User-Agent" to "Media3", "X-Token" to "secret"),
            ).keys,
        )
    }

    @Test
    fun `redirect policy denies downgrade and body replay and applies standard methods`() {
        val root = "https://media.example/start".toHttpUrl()
        assertNull(CommunityJsHttpPolicy.redirect(root, root, "http://media.example/plain", 302, "GET", null))
        assertNull(CommunityJsHttpPolicy.redirect(root, root, "https://other.example/upload", 307, "POST", "body".toByteArray()))

        val seeOther = requireNotNull(
            CommunityJsHttpPolicy.redirect(root, root, "/result", 303, "POST", "body".toByteArray()),
        )
        assertEquals("GET", seeOther.method)
        assertNull(seeOther.body)

        val temporary = requireNotNull(
            CommunityJsHttpPolicy.redirect(root, root, "/retry", 307, "POST", "body".toByteArray()),
        )
        assertEquals("POST", temporary.method)
        assertEquals("body", temporary.body?.toString(Charsets.UTF_8))
    }

    @Test
    fun `binder envelope ceiling is conservative and deterministic`() {
        val exact = "x".repeat(COMMUNITY_JS_MAX_BINDER_RESULT_CHARS)
        assertEquals(exact, communityJsBoundedEnvelope(exact))
        assertEquals(
            COMMUNITY_JS_BINDER_FAILURE_ENVELOPE,
            communityJsBoundedEnvelope(exact + "x"),
        )
    }

    @Test
    fun `execute Binder budget accepts exact ceilings and rejects overages before IPC`() {
        val exact = CommunityJsBinderPayloads.isExecuteRequestSafe(
            token = "t".repeat(CommunityJsBinderPayloads.MAX_TOKEN_CHARS),
            code = "c".repeat(CommunityJsBinderPayloads.MAX_EXECUTE_CODE_CHARS),
            tmdbId = "1".repeat(CommunityJsBinderPayloads.MAX_MEDIA_ID_CHARS),
            mediaType = "m".repeat(CommunityJsBinderPayloads.MAX_MEDIA_TYPE_CHARS),
            settingsJson = "s".repeat(CommunityJsBinderPayloads.MAX_EXECUTE_SETTINGS_CHARS),
        )
        assertTrue(exact)
        assertFalse(CommunityJsBinderPayloads.isExecuteRequestSafe(
            token = "token",
            code = "c".repeat(CommunityJsBinderPayloads.MAX_EXECUTE_CODE_CHARS + 1),
            tmdbId = "1",
            mediaType = "movie",
            settingsJson = "{}",
        ))

        var brokerCalls = 0
        assertFalse(communityJsExecuteOverBinder(
            token = "token",
            code = "c".repeat(CommunityJsBinderPayloads.MAX_EXECUTE_CODE_CHARS + 1),
            tmdbId = "1",
            mediaType = "movie",
            settingsJson = "{}",
        ) { brokerCalls += 1 })
        assertEquals(0, brokerCalls)
    }

    @Test
    fun `broker rejects oversized inbound execute without complete or fetch callback admission`() {
        var completeCallbacks = 0
        var fetchCallbacks = 0
        assertFalse(communityJsDispatchInboundBrokerExecute(
            token = "t".repeat(CommunityJsBinderPayloads.MAX_TOKEN_CHARS + 1),
            code = "module.exports = {}",
            tmdbId = "1",
            mediaType = "movie",
            settingsJson = "{}",
        ) { completeCallbacks += 1; fetchCallbacks += 1 })
        assertFalse(communityJsDispatchInboundBrokerExecute(
            token = "token",
            code = "c".repeat(CommunityJsBinderPayloads.MAX_EXECUTE_CODE_CHARS + 1),
            tmdbId = "1",
            mediaType = "movie",
            settingsJson = "{}",
        ) { completeCallbacks += 1; fetchCallbacks += 1 })
        assertEquals(0, completeCallbacks)
        assertEquals(0, fetchCallbacks)
    }

    @Test
    fun `settings are bounded before parsing and invalid JSON never canonicalizes`() {
        assertNull(CommunityJsBinderPayloads.canonicalSettingsJson(
            "x".repeat(CommunityJsBinderPayloads.MAX_EXECUTE_SETTINGS_CHARS + 1),
        ))
        assertNull(CommunityJsBinderPayloads.canonicalSettingsJson("{broken"))

        val escaped = "{\"title\":\"" + "\\u0061".repeat(1_000) + "\"}"
        val canonical = requireNotNull(CommunityJsBinderPayloads.canonicalSettingsJson(escaped))
        assertTrue(canonical.length <= CommunityJsBinderPayloads.MAX_EXECUTE_SETTINGS_CHARS)
        assertTrue(canonical.contains("a".repeat(1_000)))
    }

    @Test
    fun `settings enforce exact UTF-8 byte ceiling before and after canonicalization`() {
        val prefix = "{\"x\":\""
        val suffix = "\"}"
        val exact = prefix + "a".repeat(COMMUNITY_JS_MAX_SETTINGS_BYTES - prefix.toByteArray().size - suffix.toByteArray().size) + suffix
        assertEquals(COMMUNITY_JS_MAX_SETTINGS_BYTES, exact.toByteArray().size)
        assertNotNull(CommunityJsBinderPayloads.canonicalSettingsJson(exact))

        // The UTF-16 character count is under 64 Ki, but the UTF-8 byte count exceeds it.
        val multibyteOver = prefix + "😀".repeat(COMMUNITY_JS_MAX_SETTINGS_BYTES / 4) + suffix
        assertTrue(multibyteOver.length <= CommunityJsBinderPayloads.MAX_EXECUTE_SETTINGS_CHARS)
        assertTrue(multibyteOver.toByteArray().size > COMMUNITY_JS_MAX_SETTINGS_BYTES)
        assertNull(CommunityJsBinderPayloads.canonicalSettingsJson(multibyteOver))
    }

    @Test
    fun `oversized fetch payload is rejected without calling the Binder callback`() {
        var callbackCalls = 0
        val result = communityJsFetchOverBinder(
            token = "token",
            url = "https://example.test/" + "x".repeat(CommunityJsBinderPayloads.MAX_FETCH_URL_CHARS),
            optionsJson = "{}",
            remainingTimeoutMs = 1_000L,
        ) { _, _, _, _ ->
            callbackCalls += 1
            "unexpected"
        }

        assertEquals(COMMUNITY_JS_EMPTY_FETCH_RESPONSE, result)
        assertEquals(0, callbackCalls)
    }

    @Test
    fun `fetch Binder response budget accepts exact ceiling and replaces oversized body before return IPC`() {
        var callbackCalls = 0
        val exact = communityJsFetchOverBinder("token", "https://example.test", "{}", 1_000L) { _, _, _, _ ->
            callbackCalls += 1
            "r".repeat(CommunityJsBinderPayloads.MAX_FETCH_RESPONSE_CHARS)
        }
        assertEquals(CommunityJsBinderPayloads.MAX_FETCH_RESPONSE_CHARS, exact.length)

        val tooLarge = communityJsFetchOverBinder("token", "https://example.test", "{}", 1_000L) { _, _, _, _ ->
            callbackCalls += 1
            "r".repeat(CommunityJsBinderPayloads.MAX_FETCH_RESPONSE_CHARS + 1)
        }
        assertEquals(COMMUNITY_JS_EMPTY_FETCH_RESPONSE, tooLarge)
        assertEquals(2, callbackCalls)
    }

    @Test
    fun `broker executor rejects saturation and removes cancelled queued work`() {
        val executor = CommunityJsBoundedTaskExecutor()
        val running = CountDownLatch(1)
        val release = CountDownLatch(1)
        val runningFinished = CountDownLatch(1)
        val queuedRan = CountDownLatch(1)
        try {
            assertTrue(executor.submit("running", work = {
                running.countDown()
                release.await(5, TimeUnit.SECONDS)
            }, onFinished = { runningFinished.countDown() }))
            assertTrue(running.await(5, TimeUnit.SECONDS))
            assertTrue(executor.submit("queued", work = { queuedRan.countDown() }, onFinished = {}))
            assertEquals(2, executor.admittedCountForTesting())
            assertEquals(1, executor.queuedCountForTesting())

            assertFalse(executor.submit("overload", work = {}, onFinished = {}))
            assertTrue(executor.cancel("queued"))
            assertEquals(1, executor.admittedCountForTesting())
            assertEquals(0, executor.queuedCountForTesting())
            assertFalse(executor.retainsWorkForTesting("queued"))

            release.countDown()
            assertTrue(runningFinished.await(5, TimeUnit.SECONDS))
            assertEquals(1L, queuedRan.count)
            assertEquals(0, executor.admittedCountForTesting())
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `broker controller orders cancel before submit and retains running admission until exit`() {
        val controller = CommunityJsBrokerController()
        controller.cancel("cancelled-before-submit")
        assertFalse(controller.submit("cancelled-before-submit") { error("cancelled work ran") })

        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val finished = CountDownLatch(1)
        try {
            assertTrue(controller.submit("running", onFinished = { finished.countDown() }) { flag ->
                entered.countDown()
                while (release.count > 0L) {
                    try { release.await() } catch (_: InterruptedException) { /* cancellation is also in flag */ }
                }
                assertTrue(flag.get())
            })
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            controller.cancel("running")
            assertEquals(1, controller.admittedCountForTesting())
            release.countDown()
            assertTrue(finished.await(5, TimeUnit.SECONDS))
            assertEquals(0, controller.admittedCountForTesting())
        } finally {
            release.countDown()
            controller.shutdownNow()
        }
    }

    @Test
    fun `binding owner unbinds exactly once across reentrant completion`() {
        var unbinds = 0
        val owner = CommunityJsBindingOwner { unbinds++ }
        owner.terminate()
        assertEquals(0, unbinds)
        owner.onBindResult(success = true)
        owner.terminate()
        assertEquals(1, unbinds)
    }
}
