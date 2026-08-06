package com.vortx.android.skip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SkipConfigKeyContractTest {

    @Test
    fun `credential keys exactly match Apple and retain the three legacy migrations`() {
        assertEquals(
            listOf(
                SkipCredentialKey("vortx.apikey.skipdb", "vortx.skip.skipdbKey"),
                SkipCredentialKey("vortx.skip.customurl", "vortx.skip.customUrl"),
                SkipCredentialKey("vortx.apikey.customskip", "vortx.skip.customKey"),
            ),
            SkipConfig.credentialKeys,
        )
        assertFalse(SkipConfig.credentialKeys.any { it.current == SkipConfig.PROVIDER_KEY })
    }
}
