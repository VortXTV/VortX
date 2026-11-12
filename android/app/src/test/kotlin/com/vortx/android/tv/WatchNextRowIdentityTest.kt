package com.vortx.android.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchNextRowIdentityTest {
    private val key = ByteArray(32) { 17 }
    private val oldAccount = "b7b602f9-41c0-44b7-a07e-948856a96391"
    private val newAccount = "464538dd-ec05-4f03-afce-8cf0ea898ac9"
    private val old = owner()

    @Test fun aConfirmedAccountCanRetireOnlyAttributableOtherAccountRowsBeforeMount() {
        val other = WatchNextRowIdentity.account(key, newAccount)
        assertTrue(WatchNextRowIdentity.belongsToOtherAccount(row(old), other))
        assertFalse(WatchNextRowIdentity.belongsToOtherAccount(row(old), old.account))
        assertFalse(WatchNextRowIdentity.belongsToOtherAccount(row(old),
            WatchNextRowIdentity.account(ByteArray(32) { 18 }, newAccount)))
        assertFalse(WatchNextRowIdentity.belongsToOtherAccount("vortx-cw:movie:tt1", other))
        assertFalse(WatchNextRowIdentity.belongsToOtherAccount("vortx-cw:v1:corrupt", other))
    }

    @Test fun completedMountRetiresOtherProfilesAndRelinksOfTheSameProfile() {
        for (successor in listOf(owner(profile = "other-profile"), owner(scope = "other-scope"),
            owner(kind = "shared"), owner(value = "different-streaming-account"), owner(revision = 2),
            owner(transaction = "another-transaction"))
        ) {
            assertEquals(old.account, successor.account)
            assertNotEquals(old.binding, successor.binding)
            assertTrue(WatchNextRowIdentity.belongsOutsideMount(row(old), successor))
            assertFalse(WatchNextRowIdentity.belongsOutsideMount(row(successor), successor))
        }
        assertTrue(WatchNextRowIdentity.belongsOutsideMount("vortx-cw:movie:tt1", old))
        assertTrue(WatchNextRowIdentity.belongsOutsideMount("vortx-cw:v1:corrupt", old))
        assertTrue(WatchNextRowIdentity.belongsOutsideMount(row(old), null))
        assertFalse(WatchNextRowIdentity.belongsOutsideMount("vortx-cw:v2:future", old))
        assertFalse(WatchNextRowIdentity.belongsOutsideMount("another-app:tt1", old))
    }

    @Test fun sameTitleAndOwnerRemainStableAcrossRestartWithoutExposingIdentifiers() {
        val providerId = row(old)
        val reopened = WatchNextRowIdentity.owner(key.copyOf(), identity())
        assertEquals(providerId, row(reopened))
        assertTrue(WatchNextRowIdentity.belongsToMount(providerId, reopened))
        assertTrue(providerId.endsWith(":movie:provider:tt1"))
        for (privateValue in listOf(oldAccount, "private-scope", "current-profile",
            "private-streaming-account", "private-transaction")
        ) assertFalse(providerId.contains(privateValue))
    }

    private fun owner(scope: String = "private-scope", profile: String = "current-profile", kind: String = "own",
        value: String = "private-streaming-account", revision: Long = 1, transaction: String = "private-transaction",
    ) = WatchNextRowIdentity.owner(key, identity(scope, profile, kind, value, revision, transaction))

    private fun identity(scope: String = "private-scope", profile: String = "current-profile", kind: String = "own",
        value: String = "private-streaming-account", revision: Long = 1, transaction: String = "private-transaction",
    ) = WatchNextOwnerIdentity(oldAccount, scope, profile, kind, value, revision, transaction)

    private fun row(owner: WatchNextOwnerStamp) = WatchNextRowIdentity.providerId(owner, "movie", "provider:tt1")
}
