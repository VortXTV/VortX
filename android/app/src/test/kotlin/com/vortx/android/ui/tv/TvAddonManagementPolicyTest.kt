package com.vortx.android.ui.tv

import com.vortx.android.model.InstalledAddon
import org.junit.Assert.*
import org.junit.Test

class TvAddonManagementPolicyTest {
    private val addon = InstalledAddon("https://fixture.invalid/manifest.json", "Fixture", isConfigurable = true, rawDescriptorJson = "{}")
    @Test fun `ordinary addons expose configure replace and removal to their owner`() {
        assertEquals(TvAddonManagementActions(true, true, true), tvAddonManagementActions(addon, true))
    }
    @Test fun `shared profiles retain configuration but cannot mutate account membership`() {
        assertEquals(TvAddonManagementActions(true, false, false), tvAddonManagementActions(addon, false))
    }
    @Test fun `official endpoints cannot change and protected addons cannot be removed`() {
        assertEquals(TvAddonManagementActions(true, false, true), tvAddonManagementActions(addon.copy(isOfficial = true), true))
        assertEquals(TvAddonManagementActions(true, false, false), tvAddonManagementActions(addon.copy(isProtected = true), true))
        assertFalse(tvAddonManagementActions(addon.copy(isConfigurable = false), true).configure)
    }
}
