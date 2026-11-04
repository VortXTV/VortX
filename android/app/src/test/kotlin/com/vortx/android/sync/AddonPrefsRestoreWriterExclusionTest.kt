package com.vortx.android.sync

import com.vortx.android.data.AddonPrefsStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AddonPrefsRestoreWriterExclusionTest {
    @Test fun exactHeldWriterBlocksAllInstancesAndRetiresOnSameAccountReactivation() {
        val context = RevisionContext()
        val manager = AddonPrefsStore(context)
        val direct = AddonPrefsStore(context)
        val owner = SessionOwnerSnapshot.Account("10000000-0000-0000-0000-000000000001", 1L)
        val first = "https://one.example.invalid/manifest.json"
        val second = "https://two.example.invalid/manifest.json"
        AddonPrefsStore.activateAccount(owner.id)
        try {
            assertTrue(direct.setAppliedOrder(listOf(first)))
            val dirty = checkNotNull(direct.orderDirtyAt())
            val held = checkNotNull(manager.tryReserveRestoreWriter(owner))
            held.use {
                held.requireCurrent(owner)
                assertNull(direct.tryReserveRestoreWriter(owner))
                assertFalse(direct.setAppliedOrder(listOf(second)))
                direct.clearPushedOrderDirty(dirty)
                direct.setDisabled(first, true)
                assertEquals(listOf(first), direct.appliedOrder())
                assertEquals(dirty, direct.orderDirtyAt())
                assertFalse(direct.isDisabled(first))
                AddonPrefsStore.activateAccount(owner.id)
                assertTrue(runCatching { held.requireCurrent(owner) }.isFailure)
                assertFalse(direct.setAppliedOrder(listOf(second)))
            }
            assertTrue(direct.setAppliedOrder(listOf(second)))
            direct.setDisabled(first, true)
            assertTrue(direct.isDisabled(first))
            val successor = checkNotNull(manager.tryReserveRestoreWriter(owner.copy(generation = 2L)))
            successor.use {
                held.close()
                successor.requireCurrent(owner.copy(generation = 2L))
                assertFalse(direct.setAppliedOrder(listOf(first)))
            }
            assertTrue(direct.setAppliedOrder(listOf(first)))
        } finally { AddonPrefsStore.activateAccount(null) }
    }
}
