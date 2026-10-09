package com.vortx.android.ui.screens

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
import com.vortx.android.ui.viewmodel.AddonsViewModel
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

/** Runs the phone row's production capture seam and the accepted ViewModel; no provider requests. */
@OptIn(ExperimentalCoroutinesApi::class)
class PhoneAddonChangeUrlTargetTest {
    private class Repository : CatalogRepository by PreviewCatalogRepository(0) {
        var owner = ContinueWatchingOwner("owner", "native-fixture", "account-fixture", true, 1)
        var addon = InstalledAddon(OLD_URL, "Fixture", rawDescriptorJson = "original")
        var gate = CompletableDeferred(Unit)
        var reject = false
        val submitted = mutableListOf<AddonManagementTarget>()
        val writes = mutableListOf<Pair<String, ContinueWatchingOwner>>()
        override fun continueWatchingOwner() = owner
        override fun addonManagementAccess() = AddonManagementAccess(owner, true)
        override fun ctxUpdates() = flowOf(Unit)
        override suspend fun installedAddons() = Result.success(listOf(addon))
        override suspend fun changeAddonUrl(target: AddonManagementTarget, newUrl: String) = runCatching {
            submitted += target
            requireCurrentAddonTarget(target, owner, listOf(addon))
            gate.await()
            check(!reject) { "Fixture replacement rejected" }
            requireCurrentAddonTarget(target, owner, listOf(addon))
            writes += newUrl to target.owner
            addon = addon.copy(transportUrl = newUrl, rawDescriptorJson = "replacement")
            owner = owner.copy(revision = owner.revision + 1)
            owner
        }
    }

    private fun TestScope.viewModel(repo: Repository) = AddonsViewModel(
        repo,
        AddonHealthStore(probe = AddonHealthProbe { AddonProbeResult(200, 10) }, nowMillis = { testScheduler.currentTime }),
    )

    private fun test(block: suspend TestScope.() -> Unit) = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try { block() } finally { Dispatchers.resetMain() }
    }

    @Test fun `phone tap captures exact owner and descriptor then closes only on accepted replacement`() = test {
        val repo = Repository(); val vm = viewModel(repo); advanceUntilIdle()
        val renderedOwner = vm.managementAccess.value.owner
        val target = requireNotNull(capturePhoneAddonChangeUrlTarget(vm, repo.addon, renderedOwner))
        assertEquals(AddonManagementTarget(renderedOwner, repo.addon), target)
        vm.onChangeUrlOpen(target)
        vm.changeAddonUrl(target, NEW_URL); advanceUntilIdle()
        assertEquals(listOf(target), repo.submitted)
        assertEquals(listOf(NEW_URL to renderedOwner), repo.writes)
        assertEquals(1, vm.changeUrlDone.value)
        assertFalse(vm.changingUrl.value)
    }

    @Test fun `retained A row cannot adopt B loaded with an identical descriptor`() = test {
        val repo = Repository(); val vm = viewModel(repo); advanceUntilIdle()
        val renderedOwner = vm.managementAccess.value.owner
        val renderedAddon = repo.addon
        repo.owner = repo.owner.copy(profileId = "guest", revision = 2)
        vm.load(); advanceUntilIdle()
        assertNull(capturePhoneAddonChangeUrlTarget(vm, renderedAddon, renderedOwner))
        assertTrue(repo.submitted.isEmpty())
        assertTrue(repo.writes.isEmpty())
        val newRenderedOwner = vm.managementAccess.value.owner
        assertEquals(newRenderedOwner, capturePhoneAddonChangeUrlTarget(vm, repo.addon, newRenderedOwner)?.owner)
    }

    @Test fun `B dialog effect cannot rebind a target captured by the A row tap`() = test {
        val repo = Repository(); val vm = viewModel(repo); advanceUntilIdle()
        val target = requireNotNull(capturePhoneAddonChangeUrlTarget(vm, repo.addon, vm.managementAccess.value.owner))
        repo.owner = repo.owner.copy(principal = "replacement-account", revision = 2)
        vm.load(); advanceUntilIdle()
        vm.onChangeUrlOpen(target)
        vm.changeAddonUrl(target, NEW_URL); advanceUntilIdle()
        assertEquals(listOf(target), repo.submitted)
        assertTrue(repo.writes.isEmpty())
        assertEquals(0, vm.changeUrlDone.value)
        assertNull(vm.changeUrlMessage.value)
    }

    @Test fun `owner replacement before dispatcher starts cannot mutate through the phone dialog`() = test {
        val repo = Repository(); val vm = viewModel(repo); advanceUntilIdle()
        val target = requireNotNull(capturePhoneAddonChangeUrlTarget(vm, repo.addon, vm.managementAccess.value.owner))
        vm.onChangeUrlOpen(target)
        vm.changeAddonUrl(target, NEW_URL)
        repo.owner = repo.owner.copy(profileId = "guest", revision = 2)
        advanceUntilIdle()
        assertEquals(listOf(target), repo.submitted)
        assertTrue(repo.writes.isEmpty())
        assertEquals(OLD_URL, repo.addon.transportUrl)
        assertEquals(0, vm.changeUrlDone.value)
    }

    @Test fun `suspended phone replacement rejects profile ABA or descriptor retirement without dismissing`() = test {
        for (retirement in listOf("profile", "aba", "descriptor")) {
            val repo = Repository(); val vm = viewModel(repo); advanceUntilIdle()
            val target = requireNotNull(capturePhoneAddonChangeUrlTarget(vm, repo.addon, vm.managementAccess.value.owner))
            repo.gate = CompletableDeferred()
            vm.onChangeUrlOpen(target)
            vm.changeAddonUrl(target, NEW_URL); runCurrent()
            assertTrue(vm.changingUrl.value)
            when (retirement) {
                "profile" -> repo.owner = repo.owner.copy(profileId = "guest", revision = 2)
                "aba" -> repo.owner = repo.owner.copy(revision = 3)
                else -> repo.addon = repo.addon.copy(rawDescriptorJson = "peer-replacement")
            }
            repo.gate.complete(Unit); advanceUntilIdle()
            assertEquals(listOf(target), repo.submitted)
            assertTrue("$retirement must reject replacement", repo.writes.isEmpty())
            assertEquals(0, vm.changeUrlDone.value)
            assertFalse(vm.changingUrl.value)
            assertEquals(OLD_URL, repo.addon.transportUrl)
        }
    }

    @Test fun `failed same owner ACK leaves the phone dialog open with its original target`() = test {
        val repo = Repository().apply { reject = true }; val vm = viewModel(repo); advanceUntilIdle()
        val target = requireNotNull(capturePhoneAddonChangeUrlTarget(vm, repo.addon, vm.managementAccess.value.owner))
        vm.onChangeUrlOpen(target)
        vm.changeAddonUrl(target, NEW_URL); advanceUntilIdle()
        assertEquals(listOf(target), repo.submitted)
        assertTrue(repo.writes.isEmpty())
        assertEquals("Fixture replacement rejected" to true, vm.changeUrlMessage.value)
        assertEquals(0, vm.changeUrlDone.value)
        assertEquals(target.addon, repo.addon)
    }

    companion object {
        private const val OLD_URL = "https://addon-fixture.invalid/manifest.json"
        private const val NEW_URL = "https://replacement-fixture.invalid/manifest.json"
    }
}
