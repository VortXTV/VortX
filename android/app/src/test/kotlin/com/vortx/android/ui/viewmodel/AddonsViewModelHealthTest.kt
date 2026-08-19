package com.vortx.android.ui.viewmodel

import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.engine.AddonHealth
import com.vortx.android.engine.AddonHealthProbe
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.engine.AddonProbeResult
import com.vortx.android.ui.UiState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

@OptIn(ExperimentalCoroutinesApi::class)
class AddonsViewModelHealthTest {
    @Test
    fun `list load probes installed addons and recheck explicitly forces refresh`() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(main)
        try {
            val calls = AtomicInteger()
            val healthStore = AddonHealthStore(
                probe = AddonHealthProbe {
                    calls.incrementAndGet()
                    AddonProbeResult(statusCode = 200, latencyMillis = 30)
                },
                nowMillis = { 0L },
            )
            val viewModel = AddonsViewModel(
                repo = PreviewCatalogRepository(latencyMs = 0),
                healthStore = healthStore,
            )

            advanceUntilIdle()

            assertTrue(viewModel.state.value is UiState.Success)
            assertEquals(1, calls.get())
            assertEquals(
                AddonHealth.Online(30),
                viewModel.health.value["https://v3-cinemeta.strem.io/manifest.json"],
            )

            viewModel.recheckHealth()
            advanceUntilIdle()

            assertEquals(2, calls.get())
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `screen reopen is non-forced and probes unchanged list only after limiter elapsed`() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(main)
        try {
            val calls = AtomicInteger()
            val healthStore = AddonHealthStore(
                probe = AddonHealthProbe {
                    calls.incrementAndGet()
                    AddonProbeResult(statusCode = 200, latencyMillis = 30)
                },
                nowMillis = { testScheduler.currentTime },
            )
            val viewModel = AddonsViewModel(
                repo = PreviewCatalogRepository(latencyMs = 0),
                healthStore = healthStore,
            )
            advanceUntilIdle()
            assertEquals(1, calls.get())

            viewModel.onScreenEntry()
            runCurrent()
            assertEquals("rapid reopen must stay Store-rate-limited", 1, calls.get())

            advanceTimeBy(20_000)
            runCurrent()
            assertEquals("rapid reopen must not queue a delayed retry", 1, calls.get())

            viewModel.onScreenEntry()
            advanceUntilIdle()
            assertEquals(2, calls.get())
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `rapid reopen during active same-list probe preserves its generation owner`() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(main)
        try {
            val started = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val calls = AtomicInteger()
            val cancellations = AtomicInteger()
            val healthStore = AddonHealthStore(
                probe = AddonHealthProbe {
                    calls.incrementAndGet()
                    started.complete(Unit)
                    try {
                        release.await()
                    } catch (cancelled: CancellationException) {
                        cancellations.incrementAndGet()
                        throw cancelled
                    }
                    AddonProbeResult(statusCode = 200, latencyMillis = 30)
                },
                nowMillis = { testScheduler.currentTime },
            )
            val viewModel = AddonsViewModel(
                repo = PreviewCatalogRepository(latencyMs = 0),
                healthStore = healthStore,
            )

            started.await()
            assertEquals(
                AddonHealth.Checking,
                viewModel.health.value["https://v3-cinemeta.strem.io/manifest.json"],
            )

            viewModel.onScreenEntry()
            runCurrent()

            assertEquals(1, calls.get())
            assertEquals(0, cancellations.get())
            assertEquals(
                AddonHealth.Checking,
                viewModel.health.value["https://v3-cinemeta.strem.io/manifest.json"],
            )

            release.complete(Unit)
            advanceUntilIdle()
            assertEquals(
                AddonHealth.Online(30),
                viewModel.health.value["https://v3-cinemeta.strem.io/manifest.json"],
            )
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `changed list during active probe is queued behind bulk window and owns next generation`() = runTest {
        val main = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(main)
        try {
            val firstProbeStarted = CompletableDeferred<Unit>()
            val firstProbeCancelled = CompletableDeferred<Unit>()
            val requestedHosts = mutableListOf<String>()
            var cinemetaCalls = 0
            val healthStore = AddonHealthStore(
                probe = AddonHealthProbe { url ->
                    requestedHosts += url.host
                    if (url.host == "v3-cinemeta.strem.io" && ++cinemetaCalls == 1) {
                        firstProbeStarted.complete(Unit)
                        try {
                            awaitCancellation()
                        } finally {
                            firstProbeCancelled.complete(Unit)
                        }
                    }
                    AddonProbeResult(statusCode = 200, latencyMillis = 25)
                },
                nowMillis = { testScheduler.currentTime },
            )
            val viewModel = AddonsViewModel(
                repo = PreviewCatalogRepository(latencyMs = 0),
                healthStore = healthStore,
            )

            firstProbeStarted.await()
            viewModel.onUrlChange("https://b.example/manifest.json")
            viewModel.install()
            runCurrent()

            val changedListCancelledOldProbe = firstProbeCancelled.isCompleted
            if (!changedListCancelledOldProbe) {
                // Keep the intentionally failing RED case from leaving an Activity-scoped job alive.
                viewModel.recheckHealth()
                runCurrent()
            }
            assertTrue(changedListCancelledOldProbe)
            assertFalse("b.example" in requestedHosts)

            advanceTimeBy(19_999)
            runCurrent()
            assertFalse("b.example" in requestedHosts)

            advanceTimeBy(1)
            runCurrent()

            assertTrue("b.example" in requestedHosts)
            assertEquals(
                AddonHealth.Online(25),
                viewModel.health.value["https://b.example/manifest.json"],
            )
            assertEquals(
                setOf(
                    "https://b.example/manifest.json",
                    "https://v3-cinemeta.strem.io/manifest.json",
                ),
                viewModel.health.value.keys,
            )
        } finally {
            Dispatchers.resetMain()
        }
    }
}
