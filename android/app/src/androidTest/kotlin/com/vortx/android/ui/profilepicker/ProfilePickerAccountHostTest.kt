package com.vortx.android.ui.profilepicker

import android.content.Context
import android.content.ContextWrapper
import android.view.KeyEvent
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertDoesNotExist
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.viewModelScope
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.VortXCrypto
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.screens.VortXAccountScreen
import com.vortx.android.ui.tv.TvPickerVortXAccountScreen
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** Actual picker host, actual form and actual retained model; only transport/session setup is synthetic.
 * No diagnostic export is invoked, no real account is used, and no remote request is permitted. */
@RunWith(AndroidJUnit4::class)
class ProfilePickerAccountHostTest {
    @get:Rule val compose = createComposeRule()
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "M", isOwner = true)
    private val account = VortXSyncManager.Account("00000000-0000-0000-0000-000000000123", "fixture@example.invalid", "Fixture", false)
    private val key = ByteArray(32) { 17 }

    private inner class Fixture {
        private val prefix = "picker-account-${UUID.randomUUID()}-"
        private val instrumentContext = InstrumentationRegistry.getInstrumentation().context
        // Storage belongs to the instrumentation package with per-fixture filenames, never app credentials.
        private val context = object : ContextWrapper(instrumentContext) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int) =
                instrumentContext.getSharedPreferences(prefix + name, mode)
        }
        private val work = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val manager = VortXSyncManager(context, work)
        val holder = PickerAccountModelHolder()
        lateinit var model: com.vortx.android.ui.viewmodel.VortXAccountViewModel
        val roster = mutableStateOf<List<UserProfile>?>(listOf(owner))
        var retirements = 0
        private val transport: suspend (String, String, JSONObject?, String?) -> Pair<Int, JSONObject?> = { method, path, _, _ ->
            if (method == "GET" && path == "/v1/backup") 200 to JSONObject().put("version", 10).put("document",
                VortXCrypto.sealDocument(key, JSONObject().put("vortx", JSONObject()).toString().toByteArray(), account.id, 10, true))
            else 500 to null // QR/auth and every other request stay inside this synthetic collaborator.
        }
        init {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-a", account, key), 10, transport)
            manager.installUnavailableSessionRestoreTestSeam(); manager.sessionOwnerSnapshot()
            manager.installSessionRestoreTestSeam(null); manager.sessionOwnerSnapshot()
        }
        fun adopt(token: String = "fixture-a") {
            val session = VortXSyncManager.Session(token, account, key)
            manager.installSyncTestSeam(session, 10, transport)
            manager.installSessionRestoreTestSeam(session)
        }
        fun show(tv: Boolean = false) {
            compose.runOnIdle { model = checkNotNull(holder.model(manager)) }
            compose.setContent { VortXTheme {
                ProfilePickerAccountHost(manager, model,
                    retirePickerUi = { retirements++ },
                    diagnosticAdmission = { pickerDiagnosticExportAllowed(roster.value) },
                    accountScreen = { vm, back, signOut, admission, notice ->
                        if (tv) TvPickerVortXAccountScreen(vm, back, signOut, admission, notice)
                        else VortXAccountScreen(vm, back, onSignOutRequest = signOut,
                            diagnosticAdmission = admission, dismissalNotice = notice)
                    },
                    picker = { control -> control?.let {
                        TextButton(onClick = it.onClick, modifier = Modifier.testTag("picker-account-entry")) { Text(it.label) }
                    } },
                )
            } }
            compose.onNodeWithTag("picker-account-entry").performClick()
        }
        fun close() {
            compose.runOnIdle { holder.model(null) }
            runBlocking { manager.cancelSyncTestWork() }
            work.cancel()
        }
    }

    @Test fun protectedRosterAccountEntryCannotExposeDiagnosticSharingAndOpenRosterCan() {
        val f = Fixture()
        try {
            f.roster.value = listOf(owner.copy(pin = UserProfile.pinHash("1234", owner.id)))
            f.show()
            compose.onNodeWithText("Save or share diagnostic log").assertDoesNotExist()
            compose.runOnIdle { f.roster.value = listOf(owner) }
            compose.onNodeWithText("Save or share diagnostic log").assertExists()
            compose.runOnIdle { f.roster.value = null }
            compose.onNodeWithText("Save or share diagnostic log").assertDoesNotExist()
        } finally { f.close() }
    }

    @Test fun registrationBackBeforeSavedCodeAcknowledgementKeepsActualCardAndRetainedModel() {
        val f = Fixture()
        try {
            f.show()
            compose.runOnIdle {
                val original = f.manager.capturePickerCompletionOwner()
                f.adopt()
                val adopted = f.manager.capturePickerCompletionOwner()
                f.model.viewModelScope.launch {
                    f.model.completeRegistration(VortXSyncManager.RegisterResult(VortXSyncManager.AuthResult.Ok,
                        "fixture recovery code"), original, adopted)
                }
            }
            compose.waitUntil { f.model.recoveryCode.value != null && f.model.showReconcile.value }
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithText("fixture recovery code").assertIsDisplayed()
            compose.runOnIdle {
                assertTrue(f.model.pickerPresentationOpen.value)
                assertSame(f.model, f.holder.model(f.manager))
                assertEquals("fixture recovery code", f.model.recoveryCode.value)
                assertTrue(f.model.showReconcile.value)
            }
            // A same-account new Session is still a different completion owner; old code must disappear.
            compose.runOnIdle { f.adopt("fixture-replacement") }
            compose.waitUntil { !f.model.pickerPresentationOpen.value }
            compose.onNodeWithText("fixture recovery code").assertDoesNotExist()
            compose.runOnIdle { assertNull(f.model.recoveryCode.value); assertFalse(f.model.showReconcile.value) }
        } finally { f.close() }
    }

    @Test fun televisionSystemBackCannotDropUnacknowledgedRecoveryCode() {
        val f = Fixture()
        try {
            f.show(tv = true)
            compose.runOnIdle {
                val original = f.manager.capturePickerCompletionOwner()
                f.adopt()
                val adopted = f.manager.capturePickerCompletionOwner()
                f.model.viewModelScope.launch {
                    f.model.completeRegistration(VortXSyncManager.RegisterResult(VortXSyncManager.AuthResult.Ok,
                        "fixture recovery code"), original, adopted)
                }
            }
            compose.waitUntil { f.model.recoveryCode.value != null && f.model.showReconcile.value }
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue(f.model.pickerPresentationOpen.value)
                assertEquals("fixture recovery code", f.model.recoveryCode.value)
                assertTrue(f.model.showReconcile.value)
            }
        } finally { f.close() }
    }

    @Test fun signInBackBeforeReconcileKeepsChoiceUntilOriginalSessionChanges() {
        val f = Fixture()
        try {
            f.show()
            compose.runOnIdle {
                f.adopt()
                f.model.viewModelScope.launch { f.model.finishPostAuth { f.model.requireAccountReconcile() } }
            }
            compose.waitUntil { f.model.showReconcile.value }
            compose.onNodeWithContentDescription("Back").performClick()
            compose.runOnIdle { assertTrue(f.model.pickerPresentationOpen.value); assertTrue(f.model.showReconcile.value) }
            compose.onNodeWithTag("picker-account-entry").assertDoesNotExist()
            compose.runOnIdle { f.adopt("fixture-replacement") }
            compose.waitUntil { !f.model.pickerPresentationOpen.value }
            compose.onNodeWithTag("picker-account-entry").assertIsDisplayed()
            compose.runOnIdle { assertFalse(f.model.showReconcile.value); assertNull(f.model.recoveryCode.value) }
        } finally { f.close() }
    }
}
