package com.vortx.android.ui.viewmodel

import com.vortx.android.data.AddonManagementAccess
import com.vortx.android.data.AddonManagementTarget
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.data.requireCurrentAddonTarget
import com.vortx.android.engine.AddonHealthProbe
import com.vortx.android.engine.AddonHealthStore
import com.vortx.android.engine.AddonProbeResult
import com.vortx.android.model.InstalledAddon
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Assert.*
import org.junit.Test

/** The old public UI calls are intentional: these regressions execute unchanged against the baseline VM. */
@OptIn(ExperimentalCoroutinesApi::class)
class AddonsViewModelOwnershipTest {
    private class Repository : CatalogRepository by PreviewCatalogRepository(0) {
        var owner = ContinueWatchingOwner("owner", "native-fixture", "account-fixture", true, 1)
        var addons = mutableListOf<InstalledAddon>()
        val writes = mutableListOf<Pair<String, ContinueWatchingOwner>>()
        var gate = CompletableDeferred(Unit)
        var reject = false
        var replaceAfterCommit = false
        override fun continueWatchingOwner() = owner
        override fun addonManagementAccess() = AddonManagementAccess(owner, true)
        override fun ctxUpdates() = flowOf(Unit)
        override suspend fun installedAddons() = Result.success(addons.toList())
        override fun normalizedAddonUrl(raw: String) = raw.trim().let { if (it.endsWith("/manifest.json")) it else "$it/manifest.json" }
        override suspend fun installAddon(url: String): Result<Unit> = runCatching {
            gate.await(); check(!reject) { "Fixture manifest rejected" }
            writes += url to owner
            addons.removeAll { it.transportUrl == normalizedAddonUrl(url) }
            addons += addon(normalizedAddonUrl(url), "updated")
            if (replaceAfterCommit) owner = owner.copy(revision = owner.revision + 2)
        }
        override suspend fun installAddon(url: String, target: AddonManagementTarget): Result<ContinueWatchingOwner> = runCatching {
            requireCurrentAddonTarget(target, owner, addons)
            gate.await(); check(!reject) { "Fixture manifest rejected" }
            requireCurrentAddonTarget(target, owner, addons)
            if (target.addon == null) check(addons.none { it.transportUrl == normalizedAddonUrl(url) })
            writes += url to target.owner
            addons.removeAll { it.transportUrl == normalizedAddonUrl(url) }
            addons += addon(normalizedAddonUrl(url), "updated")
            owner = owner.copy(revision = owner.revision + 1)
            val receipt = owner
            if (replaceAfterCommit) owner = owner.copy(revision = owner.revision + 2)
            receipt
        }
    }
    private fun viewModel(repository: Repository) = AddonsViewModel(repository,
        AddonHealthStore(probe = AddonHealthProbe { AddonProbeResult(200, 10) }, nowMillis = { 0L }))
    private fun test(block: suspend TestScope.() -> Unit) = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try { block() } finally { Dispatchers.resetMain() }
    }

    @Test fun `confirmation captured on A cannot update B or an ABA replacement A`() = test {
        for (aba in listOf(false, true)) {
            val repo = Repository().apply { addons += addon(URL) }
            val vm = viewModel(repo); advanceUntilIdle()
            vm.onUrlChange(URL); vm.install(); assertEquals(URL, vm.pendingUpdate.value)
            repo.owner = repo.owner.copy(profileId = if (aba) "owner" else "guest", revision = 3)
            vm.confirmUpdate(); advanceUntilIdle()
            assertTrue(repo.writes.isEmpty())
            assertEquals("original", repo.addons.single().rawDescriptorJson)
        }
    }

    @Test fun `owner is captured before coroutine dispatcher enters install`() = test {
        val repo = Repository(); val vm = viewModel(repo); advanceUntilIdle()
        vm.onUrlChange(URL); vm.install()
        repo.owner = repo.owner.copy(principal = "replacement-account", revision = 2)
        advanceUntilIdle()
        assertTrue("No foreign account mutation", repo.writes.isEmpty())
        assertEquals(URL, vm.urlInput.value)
        assertNull(vm.installMessage.value)
    }

    @Test fun `update removed during manifest fetch cannot recreate the addon`() = test {
        val repo = Repository().apply { addons += addon(URL); gate = CompletableDeferred() }
        val vm = viewModel(repo); advanceUntilIdle()
        vm.onUrlChange(URL); vm.install(); vm.confirmUpdate(); runCurrent()
        repo.addons.clear() // Legacy same-owner registry changes also require a descriptor witness.
        repo.gate.complete(Unit); advanceUntilIdle()
        assertTrue(repo.writes.isEmpty()); assertTrue(repo.addons.isEmpty())
        assertTrue(vm.installMessage.value?.second == true)
    }

    @Test fun `same endpoint changed during fetch cannot overwrite its replacement descriptor`() = test {
        val repo = Repository().apply { addons += addon(URL); gate = CompletableDeferred() }
        val vm = viewModel(repo); advanceUntilIdle()
        vm.onUrlChange(URL); vm.install(); vm.confirmUpdate(); runCurrent()
        repo.addons[0] = addon(URL, "peer-replacement")
        repo.gate.complete(Unit); advanceUntilIdle()
        assertTrue(repo.writes.isEmpty()); assertEquals("peer-replacement", repo.addons.single().rawDescriptorJson)
    }

    @Test fun `two presses before coroutine start admit only one install`() = test {
        val repo = Repository(); val vm = viewModel(repo); advanceUntilIdle()
        vm.onUrlChange(URL); vm.install(); vm.install(); advanceUntilIdle()
        assertEquals(1, repo.writes.size)
        assertEquals("Installed." to false, vm.installMessage.value)
        assertEquals("", vm.urlInput.value)
    }

    @Test fun `late response cannot clear a newly typed URL or display success for another owner`() = test {
        val repo = Repository().apply { gate = CompletableDeferred() }
        val vm = viewModel(repo); advanceUntilIdle()
        vm.onUrlChange(URL); vm.install(); runCurrent()
        repo.owner = repo.owner.copy(revision = 3)
        vm.onUrlChange("https://new-input.invalid/manifest.json")
        repo.gate.complete(Unit); advanceUntilIdle()
        assertEquals("https://new-input.invalid/manifest.json", vm.urlInput.value)
        assertNull(vm.installMessage.value); assertTrue(repo.writes.isEmpty())
    }

    @Test fun `manifest failure remains visible and keeps entered URL`() = test {
        val repo = Repository().apply { reject = true }
        val vm = viewModel(repo); advanceUntilIdle()
        vm.onUrlChange(URL); vm.install(); advanceUntilIdle()
        assertEquals("Fixture manifest rejected" to true, vm.installMessage.value)
        assertEquals(URL, vm.urlInput.value); assertFalse(vm.installing.value)
    }

    @Test fun `post commit receipt delivery ABA cannot clear input or claim success for replacement owner`() = test {
        val repo = Repository().apply { replaceAfterCommit = true }
        val vm = viewModel(repo); advanceUntilIdle()
        vm.onUrlChange(URL); vm.install(); advanceUntilIdle()
        assertEquals(1, repo.writes.size) // The original owner accepted the mutation before replacement.
        assertEquals(URL, vm.urlInput.value)
        assertNull(vm.installMessage.value)
    }

    companion object {
        private const val URL = "https://addon-fixture.invalid/manifest.json"
        private fun addon(url: String, descriptor: String = "original") = InstalledAddon(url, "Fixture", rawDescriptorJson = descriptor)
    }
}

/** Current-only API regression: an old render cannot adopt a newly loaded, descriptor-identical owner. */
@OptIn(ExperimentalCoroutinesApi::class)
class AddonsRenderedOwnerTest {
    private class Repository : CatalogRepository by PreviewCatalogRepository(0) {
        var owner = ContinueWatchingOwner("owner", "native-fixture", "account-fixture", true, 1)
        val item = InstalledAddon("https://addon-fixture.invalid/manifest.json", "Fixture", rawDescriptorJson = "identical")
        val writes = mutableListOf<String>()
        override fun continueWatchingOwner() = owner
        override fun addonManagementAccess() = AddonManagementAccess(owner, true)
        override fun ctxUpdates() = flowOf(Unit)
        override suspend fun installedAddons() = Result.success(listOf(item))
        override fun normalizedAddonUrl(raw: String) = raw
        private fun admit(target: AddonManagementTarget, action: String) = runCatching {
            requireCurrentAddonTarget(target, owner, listOf(item))
            writes += action
            owner
        }
        override suspend fun installAddon(url: String, target: AddonManagementTarget) = admit(target, "install")
        override suspend fun setAddonDisabled(target: AddonManagementTarget, disabled: Boolean) = admit(target, "visibility")
        override suspend fun applyAddonOrder(target: AddonManagementTarget, transportUrls: List<String>) = admit(target, "order")
        override suspend fun changeAddonUrl(target: AddonManagementTarget, newUrl: String) = admit(target, "replace")
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try { block() } finally { Dispatchers.resetMain() }
    }

    private fun viewModel(repository: Repository) = AddonsViewModel(repository,
        AddonHealthStore(probe = AddonHealthProbe { AddonProbeResult(200, 10) }, nowMillis = { 0L }))

    @Test fun `A rendered callbacks reject B loaded identical descriptor while legitimate B actions work`() = test {
        val repo = Repository(); val vm = viewModel(repo); advanceUntilIdle()
        val renderedA = vm.managementAccess.value.owner
        val renderedItem = repo.item
        repo.owner = repo.owner.copy(profileId = "guest", revision = 2)
        vm.load(); advanceUntilIdle()
        val renderedB = vm.managementAccess.value.owner
        assertNull(vm.captureManagementTarget(renderedItem, renderedA))
        vm.onUrlChange("https://new-fixture.invalid/manifest.json")
        vm.install(renderedA); vm.toggleAddon(renderedItem, renderedA)
        vm.applyOrder(listOf(renderedItem.transportUrl), renderedA); advanceUntilIdle()
        assertTrue("Old callbacks cannot adopt the new loaded owner", repo.writes.isEmpty())
        assertEquals(renderedB, vm.captureManagementTarget(renderedItem, renderedB)?.owner)
        vm.install(renderedB); advanceUntilIdle()
        vm.toggleAddon(renderedItem, renderedB); advanceUntilIdle()
        vm.applyOrder(listOf(renderedItem.transportUrl), renderedB); advanceUntilIdle()
        assertEquals(listOf("install", "visibility", "order"), repo.writes)
    }

    @Test fun `click captured A target cannot be rebound by a B dialog effect`() = test {
        val repo = Repository(); val vm = viewModel(repo); advanceUntilIdle()
        val target = requireNotNull(vm.captureManagementTarget(repo.item, vm.managementAccess.value.owner))
        repo.owner = repo.owner.copy(profileId = "guest", revision = 2)
        vm.load(); advanceUntilIdle()
        vm.onChangeUrlOpen(target)
        vm.changeAddonUrl(target, "https://replacement-fixture.invalid/manifest.json"); advanceUntilIdle()
        assertTrue(repo.writes.isEmpty())
        val legitimateB = requireNotNull(vm.captureManagementTarget(repo.item, vm.managementAccess.value.owner))
        vm.onChangeUrlOpen(legitimateB)
        vm.changeAddonUrl(legitimateB, "https://replacement-fixture.invalid/manifest.json"); advanceUntilIdle()
        assertEquals(listOf("replace"), repo.writes)
    }
}
