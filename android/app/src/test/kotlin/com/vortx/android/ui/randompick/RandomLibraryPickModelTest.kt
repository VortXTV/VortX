package com.vortx.android.ui.randompick

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.UserProfile
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Behavioral coverage for the in-memory Library picker model.
 *
 * This intentionally injects only the authoritative library read. A passing test therefore
 * demonstrates that picking/opening is read-only: there is no repository mutation, saved-state
 * write, or watched-state write available to the model seam.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RandomLibraryPickModelTest {
    private val mainOwner = owner("main", revision = 1L)
    private val mainProfile = profile("main")
    private val movieA = MetaItem("movie-a", MediaType.MOVIE, "Movie A")
    private val movieB = MetaItem("movie-b", MediaType.MOVIE, "Movie B")
    private val showA = MetaItem("show-a", MediaType.SERIES, "Show A")

    private fun owner(id: String, revision: Long = 1L) = ContinueWatchingOwner(
        profileId = id,
        accountSlot = "slot-$id",
        principal = "principal-$id",
        usesEngineHistory = false,
        revision = revision,
    )

    private fun profile(id: String, isKids: Boolean = false, pin: String? = null) = UserProfile(
        id = id,
        name = id,
        avatar = "ember",
        isKids = isKids,
        pin = pin,
    )

    private fun readyProfile(profile: UserProfile = mainProfile) =
        RandomLibraryPickProfile(profile = profile, selectionReady = true)

    private fun result(vararg items: MetaItem) = Result.success(LibraryResult(items = items.toList()))

    @Test
    fun `profile selection and PIN readiness gate the read before any candidate work`() =
        runTest(StandardTestDispatcher()) {
            var reads = 0
            val lockedKids = profile(
                id = "kids",
                isKids = true,
                pin = "sha256:fixture-kids-pin",
            )
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { owner("kids", revision = 2L) },
                captureProfile = { RandomLibraryPickProfile(lockedKids, selectionReady = false) },
                readLibrary = {
                    reads++
                    result(movieA)
                },
                nextInt = { error("locked profile must not reach random selection") },
            )

            model.pick(RandomLibraryFilter.MOVIES)
            advanceUntilIdle()

            assertEquals("A PIN-locked/kids profile is not selection-ready", 0, reads)
            assertNull(model.state.value.preview)
            assertFalse(model.state.value.loading)
            // Selection readiness is a typed profile-admission failure, not a load error.
            assertEquals(RandomLibraryPickNotice.PROFILE_LOCKED, model.state.value.message)
            assertEquals(RandomLibraryFilter.MOVIES, model.state.value.filter)
        }

    @Test
    fun `empty and failed authoritative reads expose typed non-navigation outcomes`() =
        runTest(StandardTestDispatcher()) {
            var failed = false
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { mainOwner },
                captureProfile = { readyProfile() },
                readLibrary = {
                    if (failed) Result.failure(IOException("temporary")) else result()
                },
                nextInt = { error("neither empty nor failed read may randomise") },
            )

            model.pick()
            advanceUntilIdle()
            assertNull(model.state.value.preview)
            assertEquals(RandomLibraryPickNotice.EMPTY, model.state.value.message)

            failed = true
            model.pick()
            advanceUntilIdle()
            assertNull(model.state.value.preview)
            assertEquals(RandomLibraryPickNotice.LOAD_ERROR, model.state.value.message)
        }

    @Test
    fun `successful pick applies the requested filter and does not mutate the injected catalog`() =
        runTest(StandardTestDispatcher()) {
            var reads = 0
            val catalog = listOf(movieA, movieB, showA)
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { mainOwner },
                captureProfile = { readyProfile() },
                readLibrary = {
                    reads++
                    result(*catalog.toTypedArray())
                },
                nextInt = { bound ->
                    assertEquals("Only the two movie candidates should be randomised", 2, bound)
                    1
                },
            )

            model.pick(RandomLibraryFilter.MOVIES)
            advanceUntilIdle()

            assertEquals(1, reads)
            assertSame(movieB, model.state.value.preview)
            assertEquals(RandomLibraryFilter.MOVIES, model.state.value.filter)
            assertFalse(model.state.value.loading)
            assertNull(model.state.value.message)
        }

    @Test
    fun `explicit Shows chooses a series while All can rotate across movies and series`() =
        runTest(StandardTestDispatcher()) {
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { mainOwner },
                captureProfile = { readyProfile() },
                readLibrary = { result(movieA, showA) },
                nextInt = { bound ->
                    assertEquals("All starts with both VOD types", 2, bound)
                    0
                },
            )

            model.pick(RandomLibraryFilter.ALL)
            advanceUntilIdle()
            assertSame(movieA, model.state.value.preview)

            // The current movie is excluded when another typed identity exists, so the same All
            // control can reach the series without relying on a second random draw.
            model.pick(RandomLibraryFilter.ALL)
            advanceUntilIdle()
            assertSame(showA, model.state.value.preview)

            model.pick(RandomLibraryFilter.SHOWS)
            advanceUntilIdle()
            assertSame(showA, model.state.value.preview)
            assertEquals(RandomLibraryFilter.SHOWS, model.state.value.filter)
        }

    @Test
    fun `pick again excludes the current typed identity when an alternative exists`() =
        runTest(StandardTestDispatcher()) {
            val firstRead = CompletableDeferred<Result<LibraryResult>>()
            val secondRead = CompletableDeferred<Result<LibraryResult>>()
            var reads = 0
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { mainOwner },
                captureProfile = { readyProfile() },
                readLibrary = {
                    when (++reads) {
                        1 -> firstRead.await()
                        2 -> secondRead.await()
                        else -> error("pick again must not issue an extra read")
                    }
                },
                nextInt = { bound ->
                    assertEquals("The first pool contains two alternatives", 2, bound)
                    1
                },
            )

            model.pick(RandomLibraryFilter.MOVIES)
            runCurrent()
            firstRead.complete(result(movieA, movieB))
            advanceUntilIdle()
            assertSame(movieB, model.state.value.preview)

            model.pick(RandomLibraryFilter.MOVIES)
            runCurrent()
            secondRead.complete(result(movieA, movieB))
            advanceUntilIdle()

            assertEquals(2, reads)
            assertSame(movieA, model.state.value.preview)
        }

    @Test
    fun `owner drift while a read is suspended discards the result`() =
        runTest(StandardTestDispatcher()) {
            var currentOwner = mainOwner
            val pending = CompletableDeferred<Result<LibraryResult>>()
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { currentOwner },
                captureProfile = { readyProfile() },
                readLibrary = { pending.await() },
                nextInt = { 0 },
            )

            model.pick()
            runCurrent()
            currentOwner = owner("replacement", revision = 2L)
            pending.complete(result(movieA))
            advanceUntilIdle()

            assertNull(model.state.value.preview)
            assertFalse(model.state.value.loading)
            assertEquals(RandomLibraryPickNotice.PROFILE_LOCKED, model.state.value.message)
        }

    @Test
    fun `an in-flight PIN or Kids profile edit invalidates the captured full profile`() =
        runTest(StandardTestDispatcher()) {
            var currentProfile = readyProfile()
            val pending = CompletableDeferred<Result<LibraryResult>>()
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { mainOwner },
                captureProfile = { currentProfile },
                readLibrary = { pending.await() },
                nextInt = { 0 },
            )

            model.pick()
            runCurrent()
            currentProfile = readyProfile(
                profile(
                    id = "main",
                    isKids = true,
                    pin = UserProfile.pinHash("1357", "main"),
                ),
            )
            pending.complete(result(movieA))
            advanceUntilIdle()

            assertNull(model.state.value.preview)
            assertEquals(RandomLibraryPickNotice.PROFILE_LOCKED, model.state.value.message)
        }

    @Test
    fun `clear and owner ABA retire a late noncancellable request without hiding the replacement`() =
        runTest(StandardTestDispatcher()) {
            var currentOwner = mainOwner
            var currentProfile = readyProfile()
            val retired = CompletableDeferred<Result<LibraryResult>>()
            val superseded = CompletableDeferred<Result<LibraryResult>>()
            val replacement = CompletableDeferred<Result<LibraryResult>>()
            val requests = AtomicInteger(0)
            val replacementTitle = movieB.copy(name = "Replacement")
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { currentOwner },
                captureProfile = { currentProfile },
                readLibrary = {
                    when (requests.incrementAndGet()) {
                        1 -> withContext(NonCancellable) { retired.await() }
                        2 -> withContext(NonCancellable) { superseded.await() }
                        3 -> withContext(NonCancellable) { replacement.await() }
                        else -> error("retired request must not restart the replacement")
                    }
                },
                nextInt = { 0 },
            )

            model.pick()
            runCurrent()
            model.clear()

            currentOwner = owner("replacement", revision = 2L)
            currentProfile = readyProfile(profile("replacement"))
            model.pick()
            runCurrent()

            // A second profile transition retires B and starts the final A request. The old A
            // request must not regain authority just because the owner later returns to A.
            currentOwner = mainOwner
            currentProfile = readyProfile(mainProfile)
            model.pick()
            runCurrent()

            replacement.complete(result(replacementTitle))
            advanceUntilIdle()
            assertSame(replacementTitle, model.state.value.preview)

            retired.complete(result(movieA))
            superseded.complete(result(movieA))
            advanceUntilIdle()
            assertSame("The old A request cannot publish after A-B-A", replacementTitle, model.state.value.preview)
            assertEquals(3, requests.get())
        }

    @Test
    fun `open preview re-reads membership and refuses a title removed before confirmation`() =
        runTest(StandardTestDispatcher()) {
            var catalog = listOf(movieA)
            var reads = 0
            var accepted: MetaItem? = null
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { mainOwner },
                captureProfile = { readyProfile() },
                readLibrary = {
                    reads++
                    result(*catalog.toTypedArray())
                },
                nextInt = { 0 },
            )

            model.pick()
            advanceUntilIdle()
            assertSame(movieA, model.state.value.preview)

            catalog = emptyList()
            model.openPreview { accepted = it }
            advanceUntilIdle()

            assertEquals(2, reads)
            assertNull("Open must use the fresh typed library membership", accepted)
        }

    @Test
    fun `open preview confirms a still-admitted title exactly once`() =
        runTest(StandardTestDispatcher()) {
            var accepted: MetaItem? = null
            var callbackCount = 0
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { mainOwner },
                captureProfile = { readyProfile() },
                readLibrary = { result(movieA) },
                nextInt = { 0 },
            )

            model.pick()
            advanceUntilIdle()
            model.openPreview {
                callbackCount++
                accepted = it
            }
            advanceUntilIdle()

            assertSame(movieA, accepted)
            assertEquals(1, callbackCount)
        }

    @Test
    fun `owner drift blocks explicit open before it performs a fresh read`() =
        runTest(StandardTestDispatcher()) {
            var currentOwner = mainOwner
            var reads = 0
            var callbackCount = 0
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { currentOwner },
                captureProfile = { readyProfile() },
                readLibrary = {
                    reads++
                    result(movieA)
                },
                nextInt = { 0 },
            )

            model.pick()
            advanceUntilIdle()
            currentOwner = owner("replacement", revision = 2L)
            model.openPreview { callbackCount++ }
            advanceUntilIdle()

            assertEquals("The stale owner is rejected before action I/O", 1, reads)
            assertEquals(0, callbackCount)
            assertNull(model.state.value.preview)
            assertEquals(RandomLibraryPickNotice.PROFILE_LOCKED, model.state.value.message)
        }

    @Test
    fun `clear retires a noncancellable open and prevents its late callback`() =
        runTest(StandardTestDispatcher()) {
            val pending = CompletableDeferred<Result<LibraryResult>>()
            var reads = 0
            var callbackCount = 0
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { mainOwner },
                captureProfile = { readyProfile() },
                readLibrary = {
                    when (++reads) {
                        1 -> result(movieA)
                        2 -> withContext(NonCancellable) { pending.await() }
                        else -> error("open should perform only one fresh read")
                    }
                },
                nextInt = { 0 },
            )

            model.pick()
            advanceUntilIdle()
            model.openPreview { callbackCount++ }
            runCurrent()
            model.clear()
            pending.complete(result(movieA))
            advanceUntilIdle()

            assertEquals(2, reads)
            assertEquals(0, callbackCount)
            assertNull(model.state.value.preview)
        }

    @Test
    fun `owner and full profile drift during a fresh open read clears admission without callback`() =
        runTest(StandardTestDispatcher()) {
            var currentOwner = mainOwner
            var currentProfile = readyProfile()
            val pending = CompletableDeferred<Result<LibraryResult>>()
            var reads = 0
            var callbackCount = 0
            val model = RandomLibraryPickModel(
                scope = this,
                captureOwner = { currentOwner },
                captureProfile = { currentProfile },
                readLibrary = {
                    when (++reads) {
                        1 -> result(movieA)
                        2 -> withContext(NonCancellable) { pending.await() }
                        else -> error("the explicit action owns one fresh read")
                    }
                },
                nextInt = { 0 },
            )

            model.pick()
            advanceUntilIdle()
            model.openPreview { callbackCount++ }
            runCurrent()

            currentOwner = owner("replacement", revision = 2L)
            currentProfile = readyProfile(
                profile(
                    id = "replacement",
                    isKids = true,
                    pin = "sha256:fixture-replacement-pin",
                ),
            )
            pending.complete(result(movieA))
            advanceUntilIdle()

            assertEquals(2, reads)
            assertEquals(0, callbackCount)
            assertNull(model.state.value.preview)
            assertEquals(RandomLibraryPickNotice.PROFILE_LOCKED, model.state.value.message)
        }
}
