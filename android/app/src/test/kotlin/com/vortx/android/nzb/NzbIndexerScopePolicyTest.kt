package com.vortx.android.nzb

import com.vortx.android.debrid.DebridOwnerScope
import com.vortx.android.debrid.DebridOwnerToken
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NzbIndexerScopePolicyTest {
    @Test fun ownerGenerationAndProfileMustBothMatch() {
        val account = DebridOwnerScope.Account("account-a")
        val captured = NzbIndexerStore.Scope(DebridOwnerToken(account, 7), "profile-a")
        assertTrue(nzbStoreScopeIsCurrent(captured, DebridOwnerToken(account, 7), "profile-a"))
        assertFalse(nzbStoreScopeIsCurrent(captured, DebridOwnerToken(account, 8), "profile-a"))
        assertFalse(nzbStoreScopeIsCurrent(captured, DebridOwnerToken(account, 7), "profile-b"))
        assertFalse(nzbStoreScopeIsCurrent(captured, null, "profile-a"))
    }
}
