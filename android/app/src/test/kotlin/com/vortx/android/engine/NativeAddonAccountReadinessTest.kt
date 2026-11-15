package com.vortx.android.engine

import com.vortx.android.data.AddonAccountReadiness
import com.vortx.android.data.AddonAccountSetupRequiredException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeAddonAccountReadinessTest {
    @Test
    fun `unopened account reports setup and refuses install before manifest processing`() = runBlocking {
        val repo = NativeCatalogRepository(sessionProvider = { error("fixture-private-detail") })

        assertEquals(AddonAccountReadiness.SetupRequired, repo.addonAccountReadiness().first())
        val failure = repo.installAddon("not a manifest URL").exceptionOrNull()
        assertTrue(failure is AddonAccountSetupRequiredException)
        assertNull(failure?.message)
        assertNull(failure?.cause)
        assertTrue(repo.addonManagementSnapshot().exceptionOrNull() is AddonAccountSetupRequiredException)
    }

    @Test
    fun `account checkout cancellation is not an add-on setup error`() = runBlocking {
        val repo = NativeCatalogRepository(sessionProvider = { throw CancellationException("fixture-cancelled") })

        val failure = runCatching { repo.installAddon("not a manifest URL") }.exceptionOrNull()
        assertTrue(failure is CancellationException)
    }
}
