package com.vortx.android.trickplay

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class TrickplayPublicationTest {
    private fun identity(id: String) = TrickplayPublication.SourceIdentity(false, id, null, null, null)

    @Test fun `late old fetch cannot replace a newer key`() {
        val state = TrickplayPublication<String>()
        val first = requireNotNull(state.configure(identity("tt1"), 0L, 10))
        assertTrue(state.bind(first, "key-1"))
        val second = requireNotNull(state.configure(identity("tt2"), 0L, 10))
        assertNull(state.snapshot())
        assertTrue(state.bind(second, "key-2"))
        assertTrue(state.publish(second, "key-2", "new-sheet"))
        val current = requireNotNull(state.snapshot())
        assertFalse(state.publish(first, "key-1", "old-sheet"))
        assertSame(current, state.snapshot())
    }

    @Test fun `source ABA does not revive original request or frame admission`() {
        val state = TrickplayPublication<String>()
        val first = requireNotNull(state.configure(identity("tt1"), 0L, 10))
        state.bind(first, "key-1")
        state.configure(identity("tt2"), 0L, 10)
        val final = requireNotNull(state.configure(identity("tt1"), 0L, 10))
        assertNotSame(first.source, final.source)
        assertFalse(state.isCurrent(first.source))
        assertFalse(state.bind(first, "key-1"))
        assertTrue(state.bind(final, "key-1"))
        assertFalse(state.publish(first, "key-1", "stale"))
        assertTrue(state.publish(final, "key-1", "current"))
        assertEquals("current", state.snapshot()?.sheet)
    }

    @Test fun `repeated source bucket ticks do not clear a good preview or launch another request`() {
        val state = TrickplayPublication<String>()
        val request = requireNotNull(state.configure(identity("tt1"), 4L, 10))
        state.bind(request, "key-1")
        state.publish(request, "key-1", "sheet")
        val original = requireNotNull(state.snapshot())
        repeat(100) { assertNull(state.configure(identity("tt1"), 4L, 10)) }
        assertSame(original, state.snapshot())
        assertSame(request.source, state.captureSource())
    }

    @Test fun `duration bucket ABA retires requests but preserves same timeline frame owner`() {
        val state = TrickplayPublication<String>()
        val first = requireNotNull(state.configure(identity("tt1"), 0L, 10))
        state.bind(first, "bucket-10")
        val second = requireNotNull(state.configure(identity("tt1"), 0L, 11))
        assertSame(first.source, second.source)
        val final = requireNotNull(state.configure(identity("tt1"), 0L, 10))
        assertSame(first.source, final.source)
        assertNotSame(first, final)
        assertTrue(state.isCurrent(first.source))
        assertFalse(state.publish(first, "bucket-10", "old-sheet"))
        assertTrue(state.bind(final, "bucket-10"))
        assertTrue(state.publish(final, "bucket-10", "new-sheet"))
    }

    @Test fun `a newer bucket awaits original source resolution and alone binds its result`() = runBlocking {
        val state = TrickplayPublication<String>()
        val resolver = TrickplayResolution(state)
        val first = requireNotNull(state.configure(identity("tmdb:1"), 0L, 10))
        val oldLookup = requireNotNull(resolver.admit(first))
        assertTrue(oldLookup.startsLookup)
        val fresh = requireNotNull(state.configure(identity("tmdb:1"), 0L, 11))
        val shared = requireNotNull(resolver.admit(fresh))
        assertFalse(shared.startsLookup)
        assertSame(oldLookup.lookup, shared.lookup)
        oldLookup.lookup.result.complete("tt1")
        assertEquals("tt1", shared.lookup.result.await())
        assertFalse(state.bind(first, "old-bucket"))
        assertTrue(state.bind(fresh, "new-bucket"))
        assertNull(state.configure(identity("tmdb:1"), 0L, 11))
        assertEquals("new-bucket", state.snapshot()?.key)
    }

    @Test fun `old resolution completion cannot clear a newer consent source lookup`() = runBlocking {
        val state = TrickplayPublication<String>()
        val resolver = TrickplayResolution(state)
        val first = requireNotNull(state.configure(identity("tmdb:1"), 0L, 10))
        val old = requireNotNull(resolver.admit(first))
        state.withState { state.invalidate(); resolver.reset() }
        val fresh = requireNotNull(state.configure(identity("tmdb:1"), 1L, 10))
        val current = requireNotNull(resolver.admit(fresh))
        assertTrue(current.startsLookup)
        assertNotSame(old.lookup, current.lookup)
        old.lookup.result.complete("tt-old")
        assertFalse(current.lookup.result.isCompleted)
        current.lookup.result.complete("tt-new")
        assertEquals("tt-new", current.lookup.result.await())
        assertFalse(state.bind(first, "key"))
        assertTrue(state.bind(fresh, "key"))
    }

    @Test fun `revocation and re-enable cannot revive an equal key or old render snapshot`() {
        val state = TrickplayPublication<String>()
        val gate = TrickplayConsentGate()
        val first = requireNotNull(state.configure(identity("tt1"), gate.admit(), 10))
        state.bind(first, "same-key")
        state.publish(first, "same-key", "old")
        val rendering = requireNotNull(state.snapshot())
        state.withState { gate.revoke(); state.invalidate() }
        val fresh = requireNotNull(state.configure(identity("tt1"), gate.admit(), 10))
        state.bind(fresh, "same-key")
        state.publish(fresh, "same-key", "new")
        assertFalse(gate.permits(first.source.consentGeneration))
        assertFalse(state.isCurrent(first.source))
        assertFalse(state.isCurrent(rendering))
        assertFalse(state.publish(first, "same-key", "late-old"))
        assertEquals("new", state.snapshot()?.sheet)
    }

    @Test fun `snapshot key and sheet are one atomic fallback identity`() {
        val state = TrickplayPublication<String>()
        val old = requireNotNull(state.configure(identity("tt1"), 0L, 10))
        state.bind(old, "one")
        state.publish(old, "one", "one-sheet")
        val oldRead = requireNotNull(state.snapshot())
        val fresh = requireNotNull(state.configure(identity("tt2"), 0L, 10))
        state.bind(fresh, "two")
        val fallback = requireNotNull(state.snapshot())
        assertEquals("two", fallback.key)
        assertNull(fallback.sheet)
        assertFalse(state.isCurrent(oldRead))
        state.publish(fresh, "two", "two-sheet")
        assertFalse(state.isCurrent(fallback))
        assertEquals("two", state.snapshot()?.key)
        assertEquals("two-sheet", state.snapshot()?.sheet)
    }

    @Test fun `teardown closes new work while keeping original admitted frame and final owner`() {
        val state = TrickplayPublication<String>()
        val request = requireNotNull(state.configure(identity("tt1"), 0L, 10))
        state.bind(request, "one")
        assertSame(request.source, state.close())
        assertNull(state.captureSource())
        assertNull(state.snapshot())
        assertNull(state.configure(identity("tt2"), 0L, 20))
        assertFalse(state.publish(request, "one", "late"))
        assertTrue(state.isCurrent(request.source))
        state.invalidate()
        assertFalse(state.isCurrent(request.source))
        assertNull(state.configure(identity("tt1"), 1L, 10))
    }

    @Test fun `wrong-key fetch cannot mutate an admitted local fallback snapshot`() {
        val state = TrickplayPublication<String>()
        val request = requireNotNull(state.configure(identity("tt1"), 0L, 10))
        state.bind(request, "one")
        val original = requireNotNull(state.snapshot())
        assertFalse(state.publish(request, "other-key", "wrong"))
        assertSame(original, state.snapshot())
    }

    @Test fun `revocation drops deferred ghost and ignores late old completion`() {
        val coordinator = TrickplayUploadCoordinator()
        val old = requireNotNull(coordinator.request("one", TrickplayUploadCoordinator.Kind.PROGRESSIVE, 1, 2, 0, true, true)).claim
        assertNotNull(coordinator.request("one", TrickplayUploadCoordinator.Kind.FINAL, 2, 3, 0, true, true))
        assertNotNull(coordinator.deferredFinal)
        coordinator.revokeAdmissions()
        assertNull(coordinator.inFlight)
        assertNull(coordinator.deferredFinal)
        val fresh = requireNotNull(coordinator.request("one", TrickplayUploadCoordinator.Kind.PROGRESSIVE, 3, 4, 0, true, true)).claim
        assertTrue(fresh.sequence > old.sequence)
        assertFalse(coordinator.complete(old, TrickplayUploadCoordinator.Outcome.STORED).applied)
        assertSame(fresh, coordinator.inFlight)
        assertTrue(coordinator.complete(fresh, TrickplayUploadCoordinator.Outcome.STORED).applied)
        assertEquals(3L, coordinator.deliveredRevision("one"))
    }

    @Test fun `revocation does not carry an old final rejection into a fresh contribution epoch`() {
        val coordinator = TrickplayUploadCoordinator()
        val old = requireNotNull(coordinator.request("one", TrickplayUploadCoordinator.Kind.FINAL, 1, 2, 0, true, true)).claim
        coordinator.complete(old, TrickplayUploadCoordinator.Outcome.REJECTED)
        assertTrue(coordinator.isFinalRejected("one"))
        coordinator.revokeAdmissions()
        assertFalse(coordinator.isFinalRejected("one"))
        assertNotNull(coordinator.request("one", TrickplayUploadCoordinator.Kind.FINAL, 2, 3, 0, true, true))
    }

    @Test fun `actual session joins claims to resolve fetch crop frame flush and revocation`() {
        val source = productionSource()
        val revoke = source.substringAfter("private fun revokeContributionConsent()").substringBefore("private fun resetRetainedState()")
        assertTrue(revoke.contains("publication.withState"))
        assertTrue(revoke.contains("publication.invalidate()"))
        assertTrue(revoke.contains("resetRetainedState()"))
        assertTrue(revoke.contains("uploadCoordinator.revokeAdmissions()"))
        assertFalse(revoke.contains("scope.launch"))
        assertFalse(source.contains("sheet = fetched"))
        assertFalse(source.contains("private var localKey"))
        assertTrue(source.contains("val request = publication.withState"))
        assertTrue(source.contains("resolveTt(ref, request)"))
        assertTrue(source.contains("resolution.admit(request)"))
        assertTrue(source.contains("admission.lookup.result.await()"))
        assertTrue(source.contains("admission.lookup.result.complete(resolved)"))
        assertTrue(source.contains("publication.publish(request, key, fetched)"))
        assertTrue(source.contains("publication.isCurrent(expected)"))
        assertTrue(source.contains("localCache.previewAt(expected.key, timeSeconds)"))
        assertTrue(source.contains("sourceOwner !== source"))
        assertTrue(source.contains("localCache.store(key, timeSeconds, jpeg)"))
        val finish = source.substringAfter("fun finishAndFlush()").substringBefore("private fun uploadDecision(")
        assertTrue(finish.contains("val source = publication.close()"))
        assertTrue(finish.contains("admissionQueue.closeAndEnqueue"))
        assertTrue(finish.contains("uploadDecision(progressive = false, source = it)"))
        assertFalse(finish.contains("consentGate.admit()"))
    }

    private fun productionSource(): String = listOf(
        File("src/main/kotlin/com/vortx/android/trickplay/TrickplaySession.kt"),
        File("app/src/main/kotlin/com/vortx/android/trickplay/TrickplaySession.kt"),
        File("android/app/src/main/kotlin/com/vortx/android/trickplay/TrickplaySession.kt"),
    ).firstOrNull(File::isFile)?.readText() ?: error("TrickplaySession.kt not found")
}
