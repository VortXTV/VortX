package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.engine.AddonHealthProbe
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.engine.AddonProbeResult
import com.vortx.android.model.InstalledAddon
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AddonManifestRefreshTest {
    private class Repository : CatalogRepository by PreviewCatalogRepository(latencyMs = 0) {
        val addon = InstalledAddon("https://synthetic.invalid/manifest.json", "Synthetic", rawDescriptorJson = "{}")
        val calls = mutableListOf<String>()
        var release: CompletableDeferred<Unit>? = null
        var outcome = Result.success(Unit)
        override suspend fun installedAddons() = Result.success(listOf(addon))
        override suspend fun changeAddonUrl(oldAddon: InstalledAddon, newUrl: String): Result<Unit> {
            assertEquals(addon, oldAddon)
            calls += newUrl
            release?.await()
            return outcome
        }
    }

    private fun withModel(block: suspend TestScope.(AddonsViewModel, Repository) -> Unit) = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val repository = Repository()
        val store = ViewModelStore()
        val model = AddonsViewModel(repository, AddonHealthStore(
            probe = AddonHealthProbe { AddonProbeResult(200, 1) }, nowMillis = { testScheduler.currentTime }))
        val job = checkNotNull(model.viewModelScope.coroutineContext[Job])
        store.put("addon-refresh", model)
        try {
            advanceUntilIdle()
            block(model, repository)
        } finally {
            try {
                store.clear()
                advanceUntilIdle()
                withContext(NonCancellable) { withTimeout(5_000) { job.join() } }
            } finally {
                Dispatchers.resetMain()
            }
        }
    }

    @Test fun `same URL refresh reaches repository once and confirms only after success`() = withModel { model, repository ->
        repository.release = CompletableDeferred()
        model.onChangeUrlOpen()
        model.changeAddonUrl(repository.addon, repository.addon.transportUrl)
        assertTrue(model.changingUrl.value)
        model.changeAddonUrl(repository.addon, repository.addon.transportUrl)
        runCurrent()
        assertEquals(listOf(repository.addon.transportUrl), repository.calls)
        assertEquals(0, model.changeUrlDone.value)
        repository.release!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, model.changeUrlDone.value)
        assertFalse(model.changingUrl.value)
    }

    @Test fun `same URL refresh failure stays visible without success dismissal`() = withModel { model, repository ->
        repository.outcome = Result.failure(IllegalStateException("Synthetic refresh failed"))
        model.changeAddonUrl(repository.addon, repository.addon.transportUrl)
        advanceUntilIdle()
        assertEquals(0, model.changeUrlDone.value)
        assertEquals("Synthetic refresh failed" to true, model.changeUrlMessage.value)
        assertFalse(model.changingUrl.value)
    }

    @Test fun `blank manifest endpoint remains rejected without starting work`() = withModel { model, repository ->
        model.changeAddonUrl(repository.addon, " ")
        advanceUntilIdle()
        assertTrue(repository.calls.isEmpty())
        assertFalse(model.changingUrl.value)
        assertEquals(0, model.changeUrlDone.value)
    }
}
