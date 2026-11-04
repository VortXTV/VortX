package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class AuxiliaryPrefsRestorePhysicalEvidenceTest {
    @get:Rule val files = TemporaryFolder()

    @Test fun physicalBackingsRetireAcrossAttemptsAndNeverRequalifyExistingOrUnknownFiles() = withIsolatedPristinePreferenceFence {
        val appData = files.newFolder()
        val prefsDirectory = File(appData, "shared_prefs")
        assertTrue(prefsDirectory.mkdir())
        val revisionContext = RevisionContext()
        val app = object : ContextWrapper(revisionContext) {
            override fun getDataDir(): File = appData
            override fun isDeviceProtectedStorage(): Boolean = false
        }
        fun open(family: NativeSettingsFence.RestoreAuxiliaryBacking) =
            NativeSettingsFence.open(app, family.fileName, Context.MODE_PRIVATE) {
                revisionContext.getSharedPreferences(family.fileName, Context.MODE_PRIVATE)
            }

        val state = NativeSettingsFence.RestoreAuxiliaryBacking.SYNC_STATE
        val statePrefs = open(state)
        val witness = checkNotNull(NativeSettingsFence.capturePristineRestoreBacking(statePrefs, state))
        assertTrue(witness())
        val (ordinarySettings, _) = NativeSettingsFence.capture { Unit }
        assertTrue(statePrefs.edit().remove("pendingPush.synthetic").commit())
        assertFalse(witness())
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(open(state), state))
        NativeSettingsFence.withCurrent(ordinarySettings) { Unit }

        val dirty = NativeSettingsFence.RestoreAuxiliaryBacking.DIRTY_SETTINGS
        val priorRollback = File(prefsDirectory, "${dirty.fileName}.xml.bak")
        priorRollback.writeText("synthetic rollback")
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(open(dirty), dirty))
        assertTrue(priorRollback.delete())
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(open(dirty), dirty))

        val addon = NativeSettingsFence.RestoreAuxiliaryBacking.ADDON_PREFS
        val addonPrefs = open(addon)
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(addonPrefs, state))
        val unknownSibling = File(prefsDirectory, "${addon.fileName}.xml.stage")
        unknownSibling.writeText("synthetic unknown")
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(addonPrefs, addon))
        assertTrue(unknownSibling.delete())
        assertNull(NativeSettingsFence.capturePristineRestoreBacking(open(addon), addon))
    }
}
