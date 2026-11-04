package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.profile.ProfileStore
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

    @Test fun profileRetirementLeavesTheAbsentDefaultOffPreferenceUntouched() = isolatedFirstOpen {
        val root = temporary.newFolder()
        val wrapper = open(root, preferences())
        val profileContext = object : ContextWrapper(null) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                assertEquals(SETTINGS, name)
                assertEquals(Context.MODE_PRIVATE, mode)
                return wrapper
            }
        }
        val constructor = ProfileStore::class.java.getDeclaredConstructor(Context::class.java)
        constructor.isAccessible = true
        val profiles = constructor.newInstance(profileContext)
        val key = ScrobbleService.KEY_TRAKT_CONTINUE_WATCHING
        val pristine = checkNotNull(NativeSettingsFence.capturePristineRestoreBacking(wrapper))

        profiles.clearNativeProjection()
        assertFalse(wrapper.contains(key))
        assertTrue(pristine())

        assertTrue(wrapper.edit().putBoolean(key, true).commit())
        profiles.clearNativeProjection()
        assertTrue(wrapper.contains(key))
        assertFalse(wrapper.getBoolean(key, true))
        assertFalse(pristine())
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

    private fun isolatedFirstOpen(test: () -> Unit) = withIsolatedPristinePreferenceFence(test)

    private companion object {
        const val SETTINGS = "vortx_settings"
    }
}

/** Each case models a separate process's first open. Retain the other tests' actual wrapper identities. */
internal fun withIsolatedPristinePreferenceFence(test: () -> Unit) {
    val fence = NativeSettingsFence
    fun field(name: String) = fence.javaClass.getDeclaredField(name).apply { isAccessible = true }
    synchronized(field("lock").get(fence)) {
        val opened = field("openedBackings")
        val revision = field("revision")
        val retry = field("originalEmptyRetryQueue")
        val previousRetry = retry.get(fence)
        val previousOpened = opened.get(fence)
        val previousRevision = revision.getLong(fence)
        @Suppress("UNCHECKED_CAST")
        val originals = field("originalRestoreBackings").get(fence) as MutableMap<String, Any>
        val previousOriginals = originals.toMap()
        @Suppress("UNCHECKED_CAST")
        val wrappers = field("wrappers").get(fence) as MutableMap<SharedPreferences, Any>
        val previousWrappers = java.util.IdentityHashMap(wrappers)
        try {
            opened.set(fence, emptySet<String>())
            revision.setLong(fence, 0L)
            retry.set(fence, null)
            originals.clear()
            wrappers.clear()
            test()
        } finally {
            wrappers.clear()
            wrappers.putAll(previousWrappers)
            originals.clear()
            originals.putAll(previousOriginals)
            revision.setLong(fence, previousRevision)
            retry.set(fence, previousRetry)
            opened.set(fence, previousOpened)
        }
    }
}
