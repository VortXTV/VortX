package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class NativeSettingsFenceRestoreExclusionTest {
    @get:Rule val temporary = TemporaryFolder()
    private val owner = SessionOwnerSnapshot.Account("fixture-owner", 3)

    @Test fun heldLaneRefusesBothTerminalsAndTypedIngressBeforeEffects() = isolated {
        val prefs = open()
        val pending = prefs.edit().putString("fixture.pending", "original intent")
        val stale = prefs.edit().putInt("fixture.stale", 4)
        val current = checkNotNull(NativeSettingsFence.capturePristineRestoreBacking(prefs))
        var published = false
        var retired: NativeSettingsFence.HeldRestoreFlatSettings? = null
        val value = NativeSettingsFence.withRestoreFlatSettingsExclusion(owner, {}) { hold ->
            retired = hold
            hold.requireCurrent(owner)
            assertThrows(IllegalStateException::class.java) { hold.requireCurrent(owner.copy(generation = 4)) }
            assertThrows(NativeSettingsFence.RestoreFlatSettingsBusy::class.java) { pending.apply() }
            assertThrows(NativeSettingsFence.RestoreFlatSettingsBusy::class.java) { stale.commit() }
            assertNull(NativeSettingsFence.tryFlatSettingsMutation { published = true })
            assertFalse(published)
            assertTrue(prefs.all.isEmpty())
            assertTrue(current())
            "complete"
        }
        assertEquals("complete", value)
        assertThrows(IllegalStateException::class.java) { checkNotNull(retired).requireCurrent(owner) }
        pending.apply()
        assertEquals("original intent", prefs.getString("fixture.pending", null))
        assertFalse(current())
    }

    @Test fun cancellationDrainsTheStructuredHolderBeforeWritersResume() = isolated {
        val prefs = open()
        var retired: NativeSettingsFence.HeldRestoreFlatSettings? = null
        var rejectedInsideDrain = false
        val restore = launch(start = CoroutineStart.UNDISPATCHED) {
            NativeSettingsFence.withRestoreFlatSettingsExclusion(owner, {}) { hold ->
                retired = hold
                try {
                    awaitCancellation()
                } finally {
                    rejectedInsideDrain = NativeSettingsFence.tryFlatSettingsMutation { Unit } == null
                }
            }
        }
        assertNotNull(retired)
        restore.cancelAndJoin()
        assertTrue(rejectedInsideDrain)
        assertNotNull(NativeSettingsFence.tryFlatSettingsMutation {
            prefs.edit().putString("fixture.after", "saved").apply()
        })
        assertEquals("saved", prefs.getString("fixture.after", null))
        assertThrows(kotlinx.coroutines.CancellationException::class.java) { checkNotNull(retired).requireCurrent(owner) }
    }

    @Test fun retainedPreAdmissionEditKeepsItsQueuedNotification() = isolated {
        val prefs = open()
        val previous = NativeSettingsFence.queuedNotificationsForTest
        val delivery = mutableListOf<() -> Unit>()
        NativeSettingsFence.queuedNotificationsForTest = delivery
        var observed = false
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "fixture.changed") observed = true
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        try {
            assertTrue(prefs.edit().putBoolean("fixture.changed", true).commit())
            assertFalse(observed)
            var entered = false
            try {
                NativeSettingsFence.withRestoreFlatSettingsExclusion(owner, {}) {
                    entered = true
                    Unit
                }
                error("Edited backing admitted")
            } catch (refusal: AccountFileRestoreTransaction.Refusal) {
                assertEquals(AccountFileRestoreTransaction.Reason.LOCAL_STATE_UNVERIFIABLE, refusal.reason)
            }
            assertFalse(entered)
            delivery.forEach { it() }
            assertTrue(observed)
            assertTrue(prefs.getBoolean("fixture.changed", false))
        } finally {
            prefs.unregisterOnSharedPreferenceChangeListener(listener)
            NativeSettingsFence.queuedNotificationsForTest = previous
        }
    }

    @Test fun queuedAndSuspendedBackgroundWriterExcludeRestoreThroughCancellationDrain() = isolated {
        open()
        val entered = CompletableDeferred<Unit>()
        val releaseDrain = CompletableDeferred<Unit>()
        var deniedInDrain = false
        val writer = checkNotNull(NativeSettingsFence.launchFlatSettingsMutation(this) {
            entered.complete(Unit)
            try {
                awaitCancellation()
            } finally {
                // Use an active context to test membership rather than cancellation refusal.
                releaseDrain.complete(Unit)
                withContext(NonCancellable) {
                    deniedInDrain = NativeSettingsFence.withRestoreFlatSettingsExclusion(owner, {}) { Unit } == null
                }
            }
        })
        assertFalse(entered.isCompleted)
        assertNull(NativeSettingsFence.withRestoreFlatSettingsExclusion(owner, {}) { Unit })
        entered.await()
        assertNull(NativeSettingsFence.withRestoreFlatSettingsExclusion(owner, {}) { Unit })
        writer.cancelAndJoin()
        assertTrue(releaseDrain.isCompleted)
        assertTrue(deniedInDrain)
        assertNotNull(NativeSettingsFence.withRestoreFlatSettingsExclusion(owner, {}) { Unit })
    }

    @Test fun restoreRefusesNewBackgroundWriterBeforeItsFirstEffectAndCancelledParentDoesNotLeak() = isolated {
        open()
        var firstEffect = false
        assertNotNull(NativeSettingsFence.withRestoreFlatSettingsExclusion(owner, {}) {
            assertNull(NativeSettingsFence.launchFlatSettingsMutation(this) { firstEffect = true })
            assertFalse(firstEffect)
            Unit
        })
        val cancelled = Job().apply { cancel() }
        val unavailable = CoroutineScope(coroutineContext + cancelled)
        val child = checkNotNull(NativeSettingsFence.launchFlatSettingsMutation(unavailable) { firstEffect = true })
        child.join()
        assertFalse(firstEffect)
        assertNotNull(NativeSettingsFence.withRestoreFlatSettingsExclusion(owner, {}) { Unit })
    }

    private fun open(): SharedPreferences {
        val root = temporary.newFolder()
        val context = object : ContextWrapper(null) {
            override fun getDataDir(): File = root
            override fun isDeviceProtectedStorage() = false
        }
        return NativeSettingsFence.open(context, "vortx_settings", Context.MODE_PRIVATE) {
            Files.createDirectories(root.toPath().resolve("shared_prefs"))
            RevisionContext().getSharedPreferences("vortx_settings", Context.MODE_PRIVATE)
        }
    }

    // These deterministic callbacks share the isolated JVM fixture thread and suspend only on
    // cancellation. No independently running settings work is hidden by the fixture monitor.
    private fun isolated(test: suspend CoroutineScope.() -> Unit) =
        withIsolatedPristinePreferenceFence { runBlocking { test() } }
}
