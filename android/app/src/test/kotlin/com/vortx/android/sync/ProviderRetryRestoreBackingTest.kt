package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.security.AccountFileProviderWriters
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
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

    @Test fun strictEmptyExistingQueueIsInspectedWithoutOpeningThenRequiresTheActualCache() =
        withIsolatedPristinePreferenceFence {
            val root = temporary.newFolder()
            val context = context(root)
            val file = existingXml(root, """<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
                <map><string name="queue">[]</string></map>
            """.trimIndent())
            val bytes = Files.readAllBytes(file)
            NativeSettingsFence.preparePristineRestoreBacking(context, queue) {
                error("Existing queue must not be opened for proof")
            }
            val proof = checkNotNull(NativeSettingsFence.captureProviderRetryRestoreBacking())
            assertTrue(proof())
            val backing = memoryQueue()
            assertTrue(backing.edit().putString("queue", "[]").commit())
            val ordinary = NativeSettingsFence.open(context, queue.fileName, Context.MODE_PRIVATE) { backing }
            assertTrue(proof())
            assertTrue(checkNotNull(NativeSettingsFence.captureProviderRetryRestoreBacking())())
            assertTrue(ordinary.edit().putString("queue", "[]").commit())
            assertFalse(proof())
            assertNull(NativeSettingsFence.captureProviderRetryRestoreBacking())
            assertTrue(Files.readAllBytes(file).contentEquals(bytes))
        }

    @Test fun unknownOrOccupiedXmlNeverQualifiesEvenAfterReplacement() {
        for (document in listOf(
            """<map><string name="queue">[{}]</string></map>""",
            """<map><string name="queue">[ ]</string></map>""",
            """<map><string name="queue">[]</string><string name="queue">[]</string></map>""",
            """<map><string name="unknown">[]</string></map>""",
            """<map><string name="queue">&#91;&#93;</string></map>""",
            """<map/><!-- hidden -->""",
            """<map xmlns="urn:unknown"/>""",
            """<!DOCTYPE map><map/>""",
            """<map/><map/>""",
            """<map>""",
        )) withIsolatedPristinePreferenceFence {
            val root = temporary.newFolder()
            val context = context(root)
            val file = existingXml(root, document)
            NativeSettingsFence.preparePristineRestoreBacking(context, queue) {
                error("Unverified queue must not be opened for proof")
            }
            assertNull(NativeSettingsFence.captureProviderRetryRestoreBacking())
            Files.write(file, "<map/>".toByteArray())
            assertNull(NativeSettingsFence.captureProviderRetryRestoreBacking())
        }
    }

    @Test fun emptyFileCannotOverrideAnInconsistentCacheOrFailedTerminalWrite() {
        for (failedCommit in listOf(false, true)) withIsolatedPristinePreferenceFence {
            val root = temporary.newFolder()
            val context = context(root)
            existingXml(root, "<map />")
            NativeSettingsFence.preparePristineRestoreBacking(context, queue) { error("Unrequested open") }
            val proof = checkNotNull(NativeSettingsFence.captureProviderRetryRestoreBacking())
            val backing = memoryQueue()
            if (!failedCommit) backing.edit().putString("queue", "[]").commit() // Different map, still logically empty.
            val wrapped = object : SharedPreferences by backing {
                override fun edit(): SharedPreferences.Editor {
                    val actual = backing.edit()
                    return object : SharedPreferences.Editor by actual {
                        override fun commit(): Boolean {
                            actual.commit()
                            return false
                        }
                    }
                }
            }
            val ordinary = NativeSettingsFence.open(context, queue.fileName, Context.MODE_PRIVATE) { wrapped }
            if (failedCommit) {
                assertTrue(proof())
                assertFalse(ordinary.edit().putString("queue", "[{}]").commit())
            }
            assertFalse(proof())
            assertNull(NativeSettingsFence.captureProviderRetryRestoreBacking())
        }
    }

    @Test fun strictEmptyProbeRefusesAReplacementAndEveryUnresolvedSibling() {
        for (sibling in listOf(null, ".bak", ".new", ".unknown")) withIsolatedPristinePreferenceFence {
            val root = temporary.newFolder()
            val context = context(root)
            val file = existingXml(root, "<map/>")
            if (sibling != null) Files.write(file.resolveSibling(file.fileName.toString() + sibling), byteArrayOf(1))
            NativeSettingsFence.preparePristineRestoreBacking(context, queue) { error("Unrequested open") }
            if (sibling != null) {
                assertNull(NativeSettingsFence.captureProviderRetryRestoreBacking())
            } else {
                val proof = checkNotNull(NativeSettingsFence.captureProviderRetryRestoreBacking())
                val replaced = Files.createTempFile(file.parent, "new", ".xml")
                Files.write(replaced, Files.readAllBytes(file))
                Files.move(replaced, file, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
                assertNull(NativeSettingsFence.captureProviderRetryRestoreBacking())
                assertFalse(proof())
            }
        }
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test fun writerIsCountedBeforeStartAndUntilCancellationCleanupFinishes() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler) + Job())
        val finish = CompletableDeferred<Unit>()
        try {
            val reservation = checkNotNull(AccountFileProviderWriters.tryReserve())
            try {
                assertNull(AccountFileProviderWriters.launchWriter(scope) { error("Reserved writer started") })
            } finally { AccountFileProviderWriters.release(reservation) }

            var started = false
            val neverStarted = checkNotNull(AccountFileProviderWriters.launchWriter(scope) { started = true })
            assertNull(AccountFileProviderWriters.tryReserve())
            neverStarted.cancel()
            runCurrent()
            assertFalse(started)
            AccountFileProviderWriters.release(checkNotNull(AccountFileProviderWriters.tryReserve()))

            val cancelling = checkNotNull(AccountFileProviderWriters.launchWriter(scope) {
                try { CompletableDeferred<Unit>().await() }
                finally { withContext(NonCancellable) { finish.await() } }
            })
            runCurrent()
            cancelling.cancel()
            runCurrent()
            assertNull(AccountFileProviderWriters.tryReserve())
            finish.complete(Unit)
            runCurrent()
            AccountFileProviderWriters.release(checkNotNull(AccountFileProviderWriters.tryReserve()))
        } finally {
            finish.complete(Unit)
            scope.cancel()
            runCurrent()
        }
    }

    private fun existingXml(root: File, document: String): java.nio.file.Path {
        val directory = Files.createDirectory(root.toPath().resolve("shared_prefs"))
        return Files.write(directory.resolve(queue.fileName + ".xml"), document.toByteArray())
    }

    private fun context(root: File): Context = object : ContextWrapper(null) {
        override fun getDataDir(): File = root
        override fun isDeviceProtectedStorage() = false
    }

    private fun memoryQueue(): SharedPreferences =
        RevisionContext().getSharedPreferences(queue.fileName, Context.MODE_PRIVATE)
}
