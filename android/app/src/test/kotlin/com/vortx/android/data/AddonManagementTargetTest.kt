package com.vortx.android.data

import com.vortx.android.model.InstalledAddon
import org.junit.Assert.*
import org.junit.Test

class AddonManagementTargetTest {
    private val owner = ContinueWatchingOwner("profile", "native", "account", true, 1)
    private val addon = InstalledAddon("https://fixture.invalid/manifest.json", "Fixture", rawDescriptorJson = "exact")
    private val target = AddonManagementTarget(owner, addon)
    @Test fun `target accepts its exact owner and descriptor without using display labels`() {
        requireCurrentAddonTarget(target, owner, listOf(addon.copy(name = "Renamed")))
    }
    @Test fun `every owner component and ABA revision is consequential`() {
        for (foreign in listOf(owner.copy(profileId = "other"), owner.copy(accountSlot = "other"),
            owner.copy(principal = "other"), owner.copy(usesEngineHistory = false), owner.copy(revision = 3))) {
            assertTrue(runCatching { requireCurrentAddonTarget(target, foreign, listOf(addon)) }.isFailure)
        }
    }
    @Test fun `removed changed or ambiguous descriptors are not current targets`() {
        for (installed in listOf(emptyList(), listOf(addon.copy(rawDescriptorJson = "changed")),
            listOf(addon.copy(transportUrl = "https://other.invalid/manifest.json")), listOf(addon, addon))) {
            assertTrue(runCatching { requireCurrentAddonTarget(target, owner, installed) }.isFailure)
        }
    }
}
