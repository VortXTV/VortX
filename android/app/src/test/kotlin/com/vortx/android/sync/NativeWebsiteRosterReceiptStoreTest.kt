package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NativeWebsiteRosterReceiptStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private val accountId = UUID.randomUUID().toString()
    private val anotherAccount = UUID.randomUUID().toString()
    private val key = ByteArray(32) { it.toByte() }
    private val field = "websiteRosterDenialReceipt.$accountId"
    private val backingName = NativeSettingsFence.RestoreAuxiliaryBacking.SYNC_STATE.fileName

    @Test fun firstReceiptSurvivesNewManagerAndCannotBeReplaced() {
        val prefs = preferences()
        var commits = 0
        val store = NativeWebsiteRosterReceiptStore(withCommit(prefs) { editor -> commits++; editor.commit() })
        val first = evidence()
        assertEquals(NativeWebsiteRosterReceiptStore.State.Absent, store.load(accountId, key))
        assertEquals(first.encode(), encoded(store.retainFirst(accountId, key, first)))
        assertEquals(first.encode(), prefs.all[field])

        val reopened = NativeWebsiteRosterReceiptStore(prefs)
        assertEquals(first.encode(), encoded(reopened.load(accountId, key)))
        assertEquals(first.encode(), encoded(store.retainFirst(accountId, key, first)))
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.retainFirst(accountId, key, evidence(22)))
        assertEquals(NativeWebsiteRosterReceiptStore.State.Absent, reopened.load(anotherAccount, key))
        assertEquals(first.encode(), encoded(reopened.load(accountId, key)))
        assertEquals(1, commits)
        assertEquals(mapOf(field to first.encode()), prefs.all)
    }

    @Test fun invalidReadOrPresentDataCannotBeTreatedAsAbsence() {
        val prefs = preferences()
        val store = NativeWebsiteRosterReceiptStore(prefs)
        val unreadable = object : SharedPreferences by prefs {
            override fun getAll(): MutableMap<String, *> = throw IOException("synthetic read error")
        }
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable,
            NativeWebsiteRosterReceiptStore(unreadable).load(accountId, key))
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable,
            NativeWebsiteRosterReceiptStore(unreadable).retainFirst(accountId, key, evidence()))
        assertTrue(prefs.all.isEmpty())
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable,
            store.retainFirst(accountId, key, evidence(account = anotherAccount)))
        assertTrue(prefs.all.isEmpty())

        assertTrue(prefs.edit().putInt(field, 1).commit())
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.load(accountId, key))
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.retainFirst(accountId, key, evidence()))
        assertEquals(1, prefs.all[field])

        val malformed = "unknown:v3"
        assertTrue(prefs.edit().putString(field, malformed).commit())
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.load(accountId, key))
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.retainFirst(accountId, key, evidence()))
        assertEquals(malformed, prefs.all[field])

        assertTrue(prefs.edit().putString(field, evidence().encode()).commit())
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.load(accountId, ByteArray(32)))
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.load(accountId, ByteArray(31)))
    }

    @Test fun failedCommitWithMutatedCacheRemainsUnavailableAcrossStoreInstances() {
        val prefs = preferences()
        var commits = 0
        val store = NativeWebsiteRosterReceiptStore(withCommit(prefs) { editor ->
            commits++
            assertTrue(editor.commit()) // Model the cache change before a failing disk write.
            false
        })
        val first = evidence()
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.retainFirst(accountId, key, first))
        assertEquals(first.encode(), prefs.all[field])
        val reopened = NativeWebsiteRosterReceiptStore(prefs)
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, reopened.load(accountId, key))
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, reopened.retainFirst(accountId, key, first))
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.retainFirst(accountId, key, evidence(22)))
        assertEquals(NativeWebsiteRosterReceiptStore.State.Absent, reopened.load(anotherAccount, key))
        assertEquals(1, commits)
    }

    @Test fun anInFlightCommitIsUnavailableToReentrantReaders() {
        val prefs = preferences()
        val anotherStore = NativeWebsiteRosterReceiptStore(prefs)
        var readDuring: NativeWebsiteRosterReceiptStore.State? = null
        var writeDuring: NativeWebsiteRosterReceiptStore.State? = null
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, changed ->
            if (changed == field) {
                readDuring = anotherStore.load(accountId, key)
                writeDuring = anotherStore.retainFirst(accountId, key, evidence(22))
            }
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        try {
            val first = evidence()
            assertEquals(first.encode(), encoded(NativeWebsiteRosterReceiptStore(prefs).retainFirst(accountId, key, first)))
            assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, readDuring)
            assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, writeDuring)
            assertEquals(first.encode(), encoded(anotherStore.load(accountId, key)))
        } finally {
            prefs.unregisterOnSharedPreferenceChangeListener(listener)
        }
    }

    @Test fun aSuccessfulCommitWithoutExactReadbackIsStillUnavailable() {
        val prefs = preferences()
        val first = evidence()
        val different = evidence(22)
        val store = NativeWebsiteRosterReceiptStore(withCommit(prefs) { editor ->
            assertTrue(editor.commit())
            assertTrue(prefs.edit().putString(field, different.encode()).commit())
            true
        })
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable, store.retainFirst(accountId, key, first))
        assertEquals(different.encode(), prefs.all[field])
        assertEquals(NativeWebsiteRosterReceiptStore.State.Unavailable,
            NativeWebsiteRosterReceiptStore(prefs).load(accountId, key))
    }

    @Test fun theReceiptInTheExistingSyncBackingRetiresPristineRestoreEvidence() =
        withIsolatedPristinePreferenceFence {
            val root = temporary.newFolder()
            val context = object : ContextWrapper(null) {
                override fun getDataDir(): File = root
                override fun isDeviceProtectedStorage() = false
            }
            val prefs = NativeSettingsFence.open(context, backingName, Context.MODE_PRIVATE) {
                Files.createDirectories(root.toPath().resolve("shared_prefs"))
                preferences()
            }
            val backing = NativeSettingsFence.RestoreAuxiliaryBacking.SYNC_STATE
            val pristine = checkNotNull(NativeSettingsFence.capturePristineRestoreBacking(prefs, backing))
            assertTrue(pristine())
            val first = evidence()
            val store = NativeWebsiteRosterReceiptStore(prefs)
            assertEquals(first.encode(), encoded(store.retainFirst(accountId, key, first)))
            assertEquals(first.encode(), prefs.all[field])
            assertFalse(pristine())
            assertNull(NativeSettingsFence.capturePristineRestoreBacking(prefs, backing))
        }

    private fun preferences(): SharedPreferences = RevisionContext().getSharedPreferences(backingName, Context.MODE_PRIVATE)

    private fun encoded(state: NativeWebsiteRosterReceiptStore.State) =
        (state as NativeWebsiteRosterReceiptStore.State.Present).receipt.encode()

    private fun evidence(base: Long = 21, account: String = accountId) =
        NativeWebsiteRosterDenialReceipt.create(account, key, base, byteArrayOf(1), base + 1, byteArrayOf(2))

    private fun withCommit(prefs: SharedPreferences, commit: (SharedPreferences.Editor) -> Boolean): SharedPreferences =
        object : SharedPreferences by prefs {
            override fun edit(): SharedPreferences.Editor {
                val actual = prefs.edit()
                return object : SharedPreferences.Editor by actual {
                    override fun putString(key: String?, value: String?) = apply { actual.putString(key, value) }
                    override fun commit(): Boolean = commit(actual)
                }
            }
        }
}
