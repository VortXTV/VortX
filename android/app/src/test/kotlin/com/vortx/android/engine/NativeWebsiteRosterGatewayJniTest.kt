package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.NativeAccountReadCapture
import com.vortx.android.sync.NativeWebsiteRosterCandidate
import com.vortx.android.sync.SessionOwnerSnapshot
import java.io.File
import java.lang.management.ManagementFactory
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.SecretKey
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Real packaged JNI + actual coordinator/exclusion/Session.open. Authenticated-read issuance,
 * original-auth gate and local-presence results are explicitly synthetic. No HTTP, real account,
 * filesystem/Keystore or manager transaction proof. Authored UNRUN; this opt-in gate must
 * report zero skips. Once enabled, missing/mismatched JNI is a failure, never a skip. */
class NativeWebsiteRosterGatewayJniTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 7)
    private fun b(value: String) = value.toByteArray(Charsets.UTF_8)
    private fun source() = b("""{"addons":[],"apiKeys":{"tmdb":"synthetic-value"},"future":{"n":9007199254740993,"fraction":1.2300e+2,"text":"\u0061"}}""")
    private class Bindings : VortxRuntimeBindings {
        init {
            assumeTrue("Explicit reviewed website roster JNI gate required", System.getenv("VORTX_JNI_WEBSITE_ROSTER_ADMISSION") == "1")
            val file = File(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")) { "Actual JNI fixture required" })
            val expected = requireNotNull(System.getenv("VORTX_JNI_SHA256"))
            require(Regex("[0-9a-f]{64}").matches(expected) && file.isAbsolute && file.isFile)
            assertEquals("Reviewed native artifact hash", expected, OHJson.sha(file.readBytes()))
            System.load(file.absolutePath)
        }
        val live = Collections.synchronizedSet(mutableSetOf<Long>())
        var created = 0
        var freed = 0
        var afterImport: (() -> Unit)? = null
        override fun create(ownerId: String, ownerName: String): Long = VortxCore.nativeInitRuntime(
            JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString()).also { created++; live.add(it) }
        override fun hydrate(snapshot: String): Long = VortxCore.nativeInitFromStateJson(snapshot).also { created++; live.add(it) }
        override fun dispatch(handle: Long, action: String): String? = VortxCore.nativeDispatchJson(handle, action).also {
            if (JSONObject(action).getString("type") == "import_legacy_sync") afterImport?.invoke()
        }
        override fun resolve(handle: Long, request: String): String? = error("No native resource resolution allowed")
        override fun state(handle: Long): String? = VortxCore.nativeGetStateJson(handle)
        override fun delta(handle: Long): String? = error("No native delta drain allowed")
        override fun free(handle: Long) { VortxCore.nativeEngineFree(handle); live.remove(handle); freed++ }
    }
    // Observe the real monitor being contended; no field replacement or production seam.
    private fun monitor(instance: Any, field: String): Any =
        instance.javaClass.getDeclaredField(field).also { it.isAccessible = true }.get(instance)
    private fun waitsFor(thread: Thread, lock: Any): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        val threads = ManagementFactory.getThreadMXBean()
        while (System.nanoTime() < deadline) {
            val info = threads.getThreadInfo(thread.id)
            if (info?.threadState == Thread.State.BLOCKED &&
                info.lockInfo?.identityHashCode == System.identityHashCode(lock)) return true
            if (!thread.isAlive) return false
            Thread.sleep(1)
        }
        return false
    }
    private fun joinBounded(thread: Thread) {
        thread.join(10_000)
        check(!thread.isAlive) { "Fixture worker did not drain" }
    }

    private inner class Fixture : AutoCloseable {
        val bindings = Bindings()
        var authGeneration = 1
        var presence = AccountFileLocalPresence.ABSENT
        var observations = 0
        var allowOrdinaryReceive = false
        var reads = 0
        var writes = 0
        var remembered = 0
        var publications = 0
        var transportCreations = 0
        var state: String? = null
        private val store = object : VortxCheckpointStore {
            override fun inspectWebsiteRosterAbsence(scope: VortxAccountScope,
                readExistingKey: (VortxAccountScope) -> SecretKey?): AccountFileLocalPresence {
                assertEquals("account.${account.id}", scope.accountID)
                assertEquals(UserProfile.OWNER_ID, scope.ownerProfileID)
                observations++; return presence
            }
            override fun read(scope: VortxAccountScope): String? {
                check(allowOrdinaryReceive) { "Detached route touched production store" }; reads++; return state
            }
            override fun commit(scope: VortxAccountScope, snapshot: String) {
                check(allowOrdinaryReceive) { "Detached route wrote production store" }; writes++; state = snapshot
            }
            override fun remember(scope: VortxAccountScope) {
                check(allowOrdinaryReceive); remembered++
            }
            override fun readPreflight(accountID: String): NativeMigrationPreflight? {
                check(allowOrdinaryReceive) { "Detached route read production preflight" }; return null
            }
            override fun commitPreflight(next: NativeMigrationPreflight, expected: NativeMigrationPreflight?) =
                error("No production preflight write allowed")
        }
        val gateway = NativeAccountCoordinator(bindings, store, {
            check(allowOrdinaryReceive) { "Detached route created production resource transport" }; transportCreations++
            object : VortxResourceTransport {
                override fun makeCancellation(): VortxResourceCancellation = error("No provider request")
                override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No provider request")
            }
        }, { it == account }, { it() }, {
            check(allowOrdinaryReceive) { "Detached route published native state" }; publications++
        }, captureOwnAccountAdmission = { captured ->
            val generation = authGeneration
            if (captured != account) null else { action -> if (authGeneration == generation) action() else false }
        })
        fun read(raw: ByteArray, version: Long = 17) = NativeAccountReadCapture.fromAuthenticatedPull(
            account, authGeneration.toLong(), account.id, account.generation, version, raw)
        fun assertDetached() {
            assertNull(gateway.currentMountToken(account)); assertNull(state)
            assertEquals(0, reads); assertEquals(0, writes); assertEquals(0, remembered)
            assertEquals(0, publications); assertEquals(0, transportCreations)
            assertTrue(bindings.live.isEmpty()); assertEquals(bindings.created, bindings.freed)
        }
        override fun close() { gateway.retire(); assertTrue(bindings.live.isEmpty()) }
    }

    @Test fun `real complete admission stays detached and ordinary receive starts only after callback release`() = runBlocking {
        Fixture().use { fixture ->
            val raw = source(); val before = raw.copyOf(); val capture = fixture.read(raw)
            val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            var retained: NativeWebsiteRosterCandidate? = null
            try {
                val confirmed = fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    retained = candidate
                    fixture.assertDetached()
                    assertTrue(candidate.currency.isCurrent())
                    assertEquals(17L, candidate.sourceRevision)
                    candidate.requireLocalAbsenceForSubmission()
                    val bytes = candidate.copyProjectedBytes()
                    assertArrayEquals(NativeWebsiteRosterProjection.project(before), bytes)
                    assertArrayEquals(OHJson.Obj(before).raw("apiKeys"), OHJson.Obj(bytes).raw("apiKeys"))
                    assertArrayEquals(OHJson.Obj(before).raw("future"), OHJson.Obj(bytes).raw("future"))
                    // A separate synthetic readback, never a relabelled source/candidate receipt.
                    bytes
                }
                val candidate = requireNotNull(retained)
                assertFalse(candidate.currency.isCurrent())
                assertTrue(runCatching { candidate.copyProjectedBytes() }.isFailure)
                fixture.assertDetached()
                assertArrayEquals(before, raw)
                fixture.allowOrdinaryReceive = true
                val confirmedBytes = requireNotNull(confirmed)
                val incoming = fixture.read(confirmedBytes, 18)
                try { assertTrue(fixture.gateway.applyRawDocument(account, incoming) { true }) }
                finally { incoming.retire(); confirmedBytes.fill(0) }
                assertNotNull(fixture.gateway.currentMountToken(account))
                assertEquals("Main", fixture.gateway.session().read().state.getJSONObject("roster")
                    .getJSONObject("profiles").getJSONObject(UserProfile.OWNER_ID).getString("name"))
                assertEquals(1, fixture.writes); assertEquals(1, fixture.remembered); assertEquals(1, fixture.publications)
            } finally { capture.retire() }
        }
    }

    @Test fun `local evidence changing after preparation prevents submission and expires the candidate`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            var retained: NativeWebsiteRosterCandidate? = null
            var passedSubmissionGate = false
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    retained = candidate; fixture.assertDetached(); fixture.presence = AccountFileLocalPresence.PRESENT
                    candidate.requireLocalAbsenceForSubmission()
                    passedSubmissionGate = true
                    Unit
                } }
                assertTrue(result.isFailure)
                assertFalse(passedSubmissionGate)
                assertFalse(requireNotNull(retained).currency.isCurrent())
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }

    @Test fun `same value auth retirement during actual native import closes the handle without callback`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            fixture.bindings.afterImport = { fixture.authGeneration++ }
            var callbacks = 0
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { callbacks++; Unit } }
                assertTrue(result.isFailure); assertEquals(0, callbacks)
                assertEquals(1, fixture.bindings.created)
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }

    @Test fun `noncooperative callback cancellation retains reservation until actual drain`() = runBlocking {
        Fixture().use { fixture -> coroutineScope {
            val entered = CompletableDeferred<NativeWebsiteRosterCandidate>()
            val release = CompletableDeferred<Unit>()
            val task = launch {
                val capture = fixture.read(source())
                val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
                try { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    entered.complete(candidate)
                    withContext(NonCancellable) { release.await() }
                    Unit
                } } finally { capture.retire() }
            }
            try {
                val candidate = withTimeout(10_000) { entered.await() }
                task.cancel()
                assertFalse(candidate.currency.isCurrent())
                assertNull(fixture.gateway.withRestoreNativeExclusion(account, {}) { true })
                assertFalse(task.isCompleted)
                release.complete(Unit)
                withTimeout(10_000) { task.join() }
                assertEquals(true, fixture.gateway.withRestoreNativeExclusion(account, {}) { true })
                fixture.assertDetached()
            } finally { release.complete(Unit); task.cancel(); task.join() }
        } }
    }

    @Test fun `retiring the exact read revokes detached currency before submission`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            var currentAfterRetirement: Boolean? = null
            var copyAfterRetirement: Result<ByteArray>? = null
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    capture.retire()
                    currentAfterRetirement = candidate.currency.isCurrent()
                    copyAfterRetirement = runCatching { candidate.copyProjectedBytes() }
                    Unit
                } }
                assertTrue(result.isFailure)
                assertEquals(false, currentAfterRetirement)
                assertTrue(requireNotNull(copyAfterRetirement).isFailure)
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }

    @Test fun `read retirement wins while candidate action waits for the real lifecycle monitor`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            val actions = AtomicInteger()
            val actionResult = AtomicReference<Result<Int?>?>()
            val retirementResult = AtomicReference<Result<Unit>?>()
            val retirementDone = CountDownLatch(1)
            var waitedForLifecycle = false
            var retiredBeforeRelease = false
            var callbacks = 0
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    callbacks++
                    val lifecycle = monitor(fixture.gateway, "lifecycleLock")
                    val worker = Thread {
                        actionResult.set(runCatching { candidate.currency.withCurrentSession { actions.incrementAndGet(); 7 } })
                    }.also { it.isDaemon = true }
                    val retireWorker = Thread {
                        try { retirementResult.set(runCatching { capture.retire() }) }
                        finally { retirementDone.countDown() }
                    }.also { it.isDaemon = true }
                    try {
                        synchronized(lifecycle) {
                            worker.start()
                            waitedForLifecycle = waitsFor(worker, lifecycle)
                            // V1 has already released the read lock at this point. V2 has not
                            // entered it yet. This retire must win before either action can run.
                            retireWorker.start()
                            retiredBeforeRelease = retirementDone.await(10, TimeUnit.SECONDS)
                        }
                    } finally {
                        joinBounded(worker)
                        if (retireWorker.state != Thread.State.NEW) joinBounded(retireWorker)
                    }
                    Unit
                } }
                assertTrue(result.isFailure) // Post-callback original read is retired.
                assertEquals(1, callbacks)
                assertTrue(waitedForLifecycle)
                assertTrue(retiredBeforeRelease)
                assertTrue(requireNotNull(retirementResult.get()).isSuccess)
                assertFalse(capture.isCurrentFor(account))
                assertEquals(0, actions.get())
                val observed = requireNotNull(actionResult.get())
                assertTrue(observed.isSuccess)
                assertNull(observed.getOrThrow())
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }

    @Test fun `candidate action linearizes before concurrent exact read retirement`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            val events = Collections.synchronizedList(mutableListOf<String>())
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val actionResult = AtomicReference<Result<String?>?>()
            val retirementResult = AtomicReference<Result<Unit>?>()
            var retirementWaitedForRead = false
            var callbacks = 0
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    callbacks++
                    val readMonitor = monitor(capture, "lock")
                    val worker = Thread {
                        actionResult.set(runCatching { candidate.currency.withCurrentSession {
                            events.add("action-start"); entered.countDown()
                            check(release.await(10, TimeUnit.SECONDS)) { "Fixture action release timed out" }
                            events.add("action-end")
                            "admitted"
                        } })
                    }.also { it.isDaemon = true }
                    val retireWorker = Thread {
                        retirementResult.set(runCatching { capture.retire(); events.add("retired"); Unit })
                    }.also { it.isDaemon = true }
                    try {
                        worker.start()
                        check(entered.await(10, TimeUnit.SECONDS)) { "Fixture candidate action did not enter" }
                        retireWorker.start()
                        retirementWaitedForRead = waitsFor(retireWorker, readMonitor)
                    } finally {
                        release.countDown()
                        joinBounded(worker)
                        if (retireWorker.state != Thread.State.NEW) joinBounded(retireWorker)
                    }
                    Unit
                } }
                assertTrue(result.isFailure) // Retirement completed before the outer callback returned.
                assertEquals(1, callbacks)
                assertTrue(retirementWaitedForRead)
                assertEquals("admitted", requireNotNull(actionResult.get()).getOrThrow())
                assertTrue(requireNotNull(retirementResult.get()).isSuccess)
                assertEquals(listOf("action-start", "action-end", "retired"), events.toList())
                assertFalse(capture.isCurrentFor(account))
                fixture.assertDetached()
            } finally { release.countDown(); capture.retire() }
        }
    }

    @Test fun `same account coordinator retirement revokes the reservation currency`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            var retained: NativeWebsiteRosterCandidate? = null
            try {
                var currentAfterRetirement: Boolean? = null
                var copyAfterRetirement: Result<ByteArray>? = null
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    retained = candidate; fixture.gateway.retire()
                    currentAfterRetirement = candidate.currency.isCurrent()
                    copyAfterRetirement = runCatching { candidate.copyProjectedBytes() }
                    Unit
                } }
                assertTrue(result.isFailure)
                assertEquals(false, currentAfterRetirement)
                assertTrue(requireNotNull(copyAfterRetirement).isFailure)
                assertFalse(requireNotNull(retained).currency.isCurrent())
                assertEquals(true, fixture.gateway.withRestoreNativeExclusion(account, {}) { true })
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }
}
