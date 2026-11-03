package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class ProviderRetryRestoreBackingTest {
    @get:Rule val temporary = TemporaryFolder()
    private val queue = NativeSettingsFence.RestoreAuxiliaryBacking.PROVIDER_RETRY_QUEUE

    @Test fun preparedEmptyQueueCanBeInspectedWithoutOpeningAndAnEditRetiresIt() = withIsolatedPristinePreferenceFence {
        val root = temporary.newFolder()
        val context = context(root)
        val backing = memoryQueue()
        var platformOpens = 0
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(queue))
        repeat(2) {
            NativeSettingsFence.preparePristineRestoreBacking(context, queue) {
                platformOpens++
                Files.createDirectories(root.toPath().resolve("shared_prefs"))
                backing
            }
        }
        assertEquals(1, platformOpens)
        val proof = checkNotNull(NativeSettingsFence.capturePristineRestoreBacking(queue))
        assertTrue(proof())
        assertEquals(1, platformOpens)
        val ordinary = NativeSettingsFence.open(context, queue.fileName, Context.MODE_PRIVATE) { backing }
        assertTrue(ordinary.edit().putString("queue", "[]").commit())
        assertFalse(proof())
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(queue))
    }

    @Test fun existingOrUnknownBackingIsNeverOpenedByPreparationOrRequalifiedLater() {
        for (suffix in listOf(".xml", ".xml.bak", ".xml.interrupted")) withIsolatedPristinePreferenceFence {
            val root = temporary.newFolder()
            val context = context(root)
            val directory = Files.createDirectory(root.toPath().resolve("shared_prefs"))
            val evidence = Files.write(directory.resolve(queue.fileName + suffix), byteArrayOf(7))
            val backing = memoryQueue()
            var platformOpens = 0
            NativeSettingsFence.preparePristineRestoreBacking(context, queue) {
                platformOpens++
                backing
            }
            assertEquals(0, platformOpens)
            assertEquals(7.toByte(), Files.readAllBytes(evidence).single())
            assertNull(NativeSettingsFence.capturePristineRestoreBacking(queue))

            // Even disappearance outside the fence cannot upgrade the original refusal.
            Files.delete(evidence)
            NativeSettingsFence.open(context, queue.fileName, Context.MODE_PRIVATE) {
                platformOpens++
                backing
            }
            assertEquals(1, platformOpens)
            assertNull(NativeSettingsFence.capturePristineRestoreBacking(queue))
        }
    }

    @Test fun ordinaryFirstOpenCannotMintStartupQueueProvenance() = withIsolatedPristinePreferenceFence {
        val root = temporary.newFolder()
        val context = context(root)
        val backing = memoryQueue()
        NativeSettingsFence.open(context, queue.fileName, Context.MODE_PRIVATE) {
            Files.createDirectories(root.toPath().resolve("shared_prefs"))
            backing
        }
        NativeSettingsFence.preparePristineRestoreBacking(context, queue) {
            error("An ordinary first open cannot be replaced")
        }
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(queue))
    }

    private fun context(root: File): Context = object : ContextWrapper(null) {
        override fun getDataDir(): File = root
        override fun isDeviceProtectedStorage() = false
    }

    private fun memoryQueue(): SharedPreferences =
        RevisionContext().getSharedPreferences(queue.fileName, Context.MODE_PRIVATE)
}
