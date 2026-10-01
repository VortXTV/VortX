package com.vortx.android.nzb

import com.vortx.android.debrid.DebridOwnerScope
import com.vortx.android.debrid.DebridOwnerToken
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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

    @Test fun logoutAndLoginOfTheSameAccountProfileKeepsTheDurableEncryptedNamespace() {
        val account = DebridOwnerScope.Account("account-a")
        val beforeLogout = NzbIndexerStore.Scope(DebridOwnerToken(account, 7), "profile-a")
        val restoredLogin = NzbIndexerStore.Scope(DebridOwnerToken(account, 8), "profile-a")
        val encryptedRecords = mutableMapOf(beforeLogout.storageIdentity to "encrypted-config-and-key")

        assertEquals(beforeLogout.storageIdentity, restoredLogin.storageIdentity)
        assertEquals("encrypted-config-and-key", encryptedRecords[restoredLogin.storageIdentity])
        assertFalse(nzbStoreScopeIsCurrent(beforeLogout, restoredLogin.owner, "profile-a"))
    }

    @Test fun accountAndProfileNamespacesAreIsolated() {
        val accountA = NzbIndexerStore.Scope(DebridOwnerToken(DebridOwnerScope.Account("account-a"), 1), "profile-a")
        val accountB = NzbIndexerStore.Scope(DebridOwnerToken(DebridOwnerScope.Account("account-b"), 1), "profile-a")
        val secondProfile = NzbIndexerStore.Scope(DebridOwnerToken(DebridOwnerScope.Account("account-a"), 1), "profile-b")

        assertNotEquals(accountA.storageIdentity, accountB.storageIdentity)
        assertNotEquals(accountA.storageIdentity, secondProfile.storageIdentity)
    }

    @Test fun editorRevisionMustStillMatchTheReadDocument() {
        assertTrue(nzbReadMatchesRevision(NzbIndexerStore.Read.Missing, expectedRevision = null))
        assertFalse(nzbReadMatchesRevision(NzbIndexerStore.Read.Missing, expectedRevision = 1))
        assertTrue(nzbReadMatchesRevision(NzbIndexerStore.Read.Ready(NzbIndexerStore.Document(4, emptyList())), expectedRevision = 4))
        assertFalse(nzbReadMatchesRevision(NzbIndexerStore.Read.Ready(NzbIndexerStore.Document(5, emptyList())), expectedRevision = 4))
    }
}
