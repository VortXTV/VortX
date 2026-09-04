package com.vortx.android.usenet

import com.vortx.android.debrid.DebridOwnerScope
import com.vortx.android.debrid.DebridOwnerToken
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UsenetCredentialOwnerPolicyTest {
    private val ownerA1 = DebridOwnerToken(DebridOwnerScope.Account("account-a"), 1)
    private val ownerA2 = DebridOwnerToken(DebridOwnerScope.Account("account-a"), 2)
    private val ownerB = DebridOwnerToken(DebridOwnerScope.Account("account-b"), 1)

    @Test fun `A and B receive isolated credential keys`() {
        assertNotEquals(key(ownerA1), key(ownerB))
    }

    @Test fun `same account generation race is rejected`() {
        assertFalse(UsenetCredentialOwnerPolicy.permits(ownerA1, ownerA2))
    }

    @Test fun `unknown owner fails closed`() {
        assertFalse(UsenetCredentialOwnerPolicy.permits(ownerA1, null))
        assertFalse(UsenetCredentialOwnerPolicy.permits(null, ownerA1))
    }

    @Test fun `save isolation only permits captured A`() {
        assertTrue(UsenetCredentialOwnerPolicy.permits(ownerA1, ownerA1))
        assertFalse(UsenetCredentialOwnerPolicy.permits(ownerA1, ownerB))
    }

    @Test fun `clear isolation only permits captured B`() {
        assertTrue(UsenetCredentialOwnerPolicy.permits(ownerB, ownerB))
        assertFalse(UsenetCredentialOwnerPolicy.permits(ownerB, ownerA1))
    }

    private fun key(owner: DebridOwnerToken) =
        UsenetCredentialOwnerPolicy.storageKey(UsenetProviderStore.PREFIX, owner)
}
