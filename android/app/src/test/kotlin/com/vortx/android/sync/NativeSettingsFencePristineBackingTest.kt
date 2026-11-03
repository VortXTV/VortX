package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class NativeSettingsFencePristineBackingTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun exactFirstOpenMintsProofAndAnEditIrrevocablyRetiresIt() = isolatedFirstOpen {
        val root = temporary.newFolder()
        val backing = preferences()
        assertFalse(File(root, "shared_prefs").exists())
        val wrapper = open(root, backing)
        assertSame(wrapper, open(root, backing))
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(backing))

        val current = checkNotNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))
        assertTrue(current())
        assertTrue(wrapper.edit().putString("theme", "fixture").commit())
        assertFalse(current())
        wrapper.edit().remove("theme").apply()
        assertTrue(wrapper.all.isEmpty())
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))
    }

    @Test fun attemptedFailedCommitRetiresProofWithoutChangingTheBacking() = isolatedFirstOpen {
        val root = temporary.newFolder()
        val memory = preferences()
        val backing = object : SharedPreferences by memory {
            override fun edit(): SharedPreferences.Editor {
                val editor = memory.edit()
                return object : SharedPreferences.Editor by editor {
                    override fun commit(): Boolean = false
                }
            }
        }
        val wrapper = open(root, backing)
        val current = checkNotNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))
        assertTrue(current())
        assertFalse(wrapper.edit().putString("theme", "fixture").commit())
        assertTrue(wrapper.all.isEmpty())
        assertFalse(current())
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))
    }

    @Test fun preexistingPrimaryOrRollbackCannotBecomePristineWhenPlatformRemovesIt() {
        for (name in listOf("vortx_settings.xml", "vortx_settings.xml.bak")) isolatedFirstOpen {
            val root = temporary.newFolder()
            val directory = Files.createDirectory(root.toPath().resolve("shared_prefs"))
            val old = Files.write(directory.resolve(name), byteArrayOf(1))
            val backing = preferences()
            var opens = 0
            val wrapper = NativeSettingsFence.open(context(root), SETTINGS, Context.MODE_PRIVATE) {
                opens++
                Files.delete(old)
                backing
            }
            assertEquals(1, opens)
            assertFalse(Files.exists(old))
            assertNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))
            assertSame(wrapper, open(root, backing))
            assertNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))
        }
    }

    @Test fun explicitProofRejectsUnexpectedSiblingsAndReplacedDirectory() = isolatedFirstOpen {
        val root = temporary.newFolder()
        val backing = preferences()
        val directory = root.toPath().resolve("shared_prefs")
        val wrapper = open(root, backing)
        checkNotNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))

        for (name in listOf("vortx_settings.xml", "vortx_settings.xml.new", "vortx_settings.xml.unknown")) {
            val suspect = Files.write(directory.resolve(name), byteArrayOf(1))
            assertNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))
            Files.delete(suspect)
        }
        Files.move(directory, root.toPath().resolve("old-prefs"))
        Files.createDirectory(directory)
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))
    }

    @Test fun differentSettingsWrapperRetiresTheOriginalWithoutMintingReplacement() = isolatedFirstOpen {
        val root = temporary.newFolder()
        val original = open(root, preferences())
        val current = checkNotNull(NativeSettingsFence.capturePristineRestoreBacking(original))
        assertTrue(current())

        val replacement = open(root, preferences())
        assertFalse(current())
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(original))
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(replacement))
    }

    @Test fun preloadedMemoryCannotProvePristineEvenWithoutADiskCarrier() = isolatedFirstOpen {
        val root = temporary.newFolder()
        val backing = preferences()
        assertTrue(backing.edit().putString("theme", "fixture").commit())
        val wrapper = open(root, backing)
        assertEquals("fixture", wrapper.getString("theme", null))
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))
    }

    private fun open(root: File, backing: SharedPreferences): SharedPreferences =
        NativeSettingsFence.open(context(root), SETTINGS, Context.MODE_PRIVATE) {
            Files.createDirectories(root.toPath().resolve("shared_prefs"))
            backing
        }

    private fun context(root: File): Context = object : ContextWrapper(null) {
        override fun getDataDir(): File = root
        override fun isDeviceProtectedStorage(): Boolean = false
    }

    private fun preferences(): SharedPreferences = RevisionContext().getSharedPreferences(SETTINGS, Context.MODE_PRIVATE)

    // Each case models a different process's first open. Preserve the surrounding test JVM's state.
    private fun isolatedFirstOpen(test: () -> Unit) {
        val fence = NativeSettingsFence
        fun field(name: String) = fence.javaClass.getDeclaredField(name).apply { isAccessible = true }
        synchronized(field("lock").get(fence)) {
            val fields = listOf("settingsOpened", "originalRestoreBacking", "revision").map(::field)
            val previous = fields.map { it.get(fence) }
            @Suppress("UNCHECKED_CAST")
            val wrappers = field("wrappers").get(fence) as MutableMap<SharedPreferences, Any>
            val previousWrappers = java.util.IdentityHashMap(wrappers)
            try {
                fields[0].setBoolean(fence, false)
                fields[1].set(fence, null)
                fields[2].setLong(fence, 0)
                wrappers.clear()
                test()
            } finally {
                wrappers.clear()
                wrappers.putAll(previousWrappers)
                fields.zip(previous).forEach { (field, value) -> field.set(fence, value) }
            }
        }
    }

    private companion object {
        const val SETTINGS = "vortx_settings"
    }
}
