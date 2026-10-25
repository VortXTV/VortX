package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewModelScope
import com.vortx.android.data.AddonManagementSnapshot
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.engine.AddonHealthProbe
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.engine.AddonProbeResult
import com.vortx.android.model.InstalledAddon
import com.vortx.android.ui.UiState
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
import org.junit.Assert.*
import org.junit.Test

/** Real ViewModel/lifecycle with a deterministic owner-bound repository. Native authority is tested
 * separately in NativeRepositoryMutationJniTest; this suite tests queued UI/error/finally delivery. */
@OptIn(ExperimentalCoroutinesApi::class)
class AddonVisibilityOwnershipTest {
    private class Repository : CatalogRepository by PreviewCatalogRepository(latencyMs = 0) {
        private data class Token(val repository: Repository, val revision: Long)
        data class Pending(val release: CompletableDeferred<Unit>, val failure: Boolean = false)
        var revision = 0L
        var addon = InstalledAddon("https://synthetic.invalid/manifest.json", "Synthetic", rawDescriptorJson = "{synthetic}")
        val calls = mutableListOf<Long>()
        val pending = ArrayDeque<Pending>()
        var mutations = 0
        fun switchProfile() { revision++; addon = addon.copy(isDisabled = false) }
        private fun snapshot(): AddonManagementSnapshot {
            val captured = revision
            return AddonManagementSnapshot(listOf(addon), Token(this, captured)) { action ->
                if (revision == captured) { action(); true } else false
            }
        }
        override suspend fun addonManagementSnapshot() = Result.success(snapshot())
        override suspend fun installedAddons() = Result.success(listOf(addon))
        override suspend fun setAddonVisibility(snapshot: AddonManagementSnapshot, addon: InstalledAddon, disabled: Boolean): Result<AddonManagementSnapshot> {
            val token = snapshot.visibilityOwner as Token
            calls += token.revision
            val held = pending.removeFirstOrNull()
            held?.release?.await()
            if (held?.failure == true) return Result.failure(IllegalStateException("Synthetic visibility failure"))
            if (token.repository !== this || token.revision != revision || snapshot.addons.single() != addon || this.addon != addon)
                return Result.failure(IllegalStateException("Original owner expired"))
            mutations++
            this.addon = addon.copy(isDisabled = disabled)
            revision++
            return Result.success(this.snapshot())
        }
    }

    private fun withModel(block: suspend TestScope.(AddonsViewModel, Repository) -> Unit) = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val repository = Repository()
        val store = ViewModelStore()
        val model = AddonsViewModel(repository, AddonHealthStore(
            probe = AddonHealthProbe { AddonProbeResult(200, 1) }, nowMillis = { testScheduler.currentTime }))
        val job = checkNotNull(model.viewModelScope.coroutineContext[Job])
        store.put("addon-visibility", model)
        try {
            advanceUntilIdle()
            block(model, repository)
        } finally {
            try {
                store.clear()
                advanceUntilIdle()
                withContext(NonCancellable) { withTimeout(5_000) { job.join() } }
            } finally { Dispatchers.resetMain() }
        }
    }
    private fun visible(model: AddonsViewModel) = (model.state.value as UiState.Success<List<InstalledAddon>>).data.single()

    @Test fun `revoked publication admission rejects without swallowing callback exceptions`() {
        var entered = false
        val revoked = AddonManagementSnapshot(emptyList()) { _ -> throw IllegalStateException("Synthetic revoked admission") }
        assertFalse(revoked.publishIfCurrent { entered = true })
        assertFalse(entered)
        val callbackError = IllegalStateException("Synthetic callback error")
        val current = AddonManagementSnapshot(emptyList())
        assertSame(callbackError, runCatching { current.publishIfCurrent { throw callbackError } }.exceptionOrNull())
    }

    @Test fun `eye is busy immediately deduplicates taps and changes only after acknowledgment`() = withModel { model, repository ->
        val release = CompletableDeferred<Unit>(); repository.pending += Repository.Pending(release)
        val row = visible(model)
        model.toggleAddon(row)
        assertEquals(row.transportUrl, model.changingVisibility.value)
        model.toggleAddon(row)
        runCurrent()
        assertEquals(listOf(0L), repository.calls)
        assertFalse(visible(model).isDisabled)
        release.complete(Unit); advanceUntilIdle()
        assertTrue(visible(model).isDisabled)
        assertNull(model.changingVisibility.value)
        assertTrue(model.visibilityMessages.value.isEmpty())
        model.toggleAddon(visible(model)); advanceUntilIdle()
        assertFalse(visible(model).isDisabled)
        assertEquals(2, repository.mutations)
    }

    @Test fun `current-owner failure is visible and preserves enabled installed row`() = withModel { model, repository ->
        val release = CompletableDeferred<Unit>(); repository.pending += Repository.Pending(release, failure = true)
        val row = visible(model); model.toggleAddon(row); runCurrent()
        release.complete(Unit); advanceUntilIdle()
        assertFalse(visible(model).isDisabled)
        assertEquals(0, repository.mutations)
        assertNull(model.changingVisibility.value)
        assertEquals("Couldn't change this add-on's visibility. Try again.", model.visibilityMessages.value[row.transportUrl])
    }

    @Test fun `profile switches before queued VM launch retain original authority and reject mutation`() = withModel { model, repository ->
        val row = visible(model); model.toggleAddon(row)
        repository.switchProfile()
        runCurrent(); advanceUntilIdle()
        assertEquals(listOf(0L), repository.calls)
        assertEquals(0, repository.mutations)
        assertFalse(visible(model).isDisabled)
        assertTrue(model.visibilityMessages.value.isEmpty())
        assertNull(model.changingVisibility.value)
    }

    @Test fun `queued A to B to A does not revive original row authority`() = withModel { model, repository ->
        val row = visible(model); model.toggleAddon(row)
        repository.switchProfile(); repository.switchProfile()
        runCurrent(); advanceUntilIdle()
        assertEquals(listOf(0L), repository.calls)
        assertEquals(0, repository.mutations)
        assertFalse(visible(model).isDisabled)
        assertTrue(model.visibilityMessages.value.isEmpty())
    }

    @Test fun `late old-owner error and finally cannot overwrite successor row or busy operation`() = withModel { model, repository ->
        val oldRelease = CompletableDeferred<Unit>(); repository.pending += Repository.Pending(oldRelease, failure = true)
        model.toggleAddon(visible(model)); runCurrent()
        repository.switchProfile(); model.load(showLoading = false); runCurrent()
        val newRelease = CompletableDeferred<Unit>(); repository.pending += Repository.Pending(newRelease)
        val currentRow = visible(model); model.toggleAddon(currentRow); runCurrent()
        assertEquals(listOf(0L, 1L), repository.calls)
        oldRelease.complete(Unit); runCurrent()
        assertEquals(currentRow.transportUrl, model.changingVisibility.value)
        assertTrue(model.visibilityMessages.value.isEmpty())
        assertFalse(visible(model).isDisabled)
        newRelease.complete(Unit); advanceUntilIdle()
        assertTrue(visible(model).isDisabled)
        assertEquals(1, repository.mutations)
        assertNull(model.changingVisibility.value)
    }

    @Test fun `stale copied row is rejected before repository work`() = withModel { model, repository ->
        model.toggleAddon(visible(model).copy(rawDescriptorJson = "different"))
        advanceUntilIdle()
        assertTrue(repository.calls.isEmpty())
        assertEquals(0, repository.mutations)
        assertFalse(visible(model).isDisabled)
    }
}
