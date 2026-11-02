package com.vortx.android.ui.profilepicker

import android.view.KeyEvent
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertDoesNotExist
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.ProfilePickerToolsViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.flowOf
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Production host/controller with synthetic download/preparation. No provider, account or network I/O.
 * System Back/focus and absent-SAF UI are bounded instrumentation coverage only, authored but unrun. */
@RunWith(AndroidJUnit4::class)
class ProfilePickerToolsHostTest {
    @get:Rule val compose = createComposeRule()
    private class Accounts : PickerToolsAccounts {
        private val issuer = Any(); private val session = Any()
        private val account = VortXSyncManager.Account("10000000-0000-0000-0000-000000000001", "fixture@example.invalid", "Fixture", false)
        override val authorityRevision = 0L
        override val sessionMarker: Any = Unit
        override val changes = flowOf(Unit)
        override fun capture() = PickerAccountSnapshot(issuer, 0, 0, 1, session, account)
        override fun isCurrent(original: PickerAccountSnapshot) = original.matchesAuthority(issuer, 0, 0) && original.matchesOwner(issuer, 1, session)
        var gets = 0
        override suspend fun download(original: PickerAccountSnapshot): ByteArray { gets++; return byteArrayOf(1, 2, 3) }
    }
    private class Fixture {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val accounts = Accounts()
        val policy = mutableStateOf(false)
        val controller = ProfilePickerToolsController(accounts, PickerToolsBackupPreparer { _, current ->
            check(current())
            object : PickerToolsPreparedBackup {
                override val byteCount = 3; override val sha256 = "fixture-only"; override fun close() = Unit
            }
        }, scope)
        val model = ProfilePickerToolsViewModel(controller)
        fun close() { controller.close(); scope.cancel() }
    }
    @Test fun televisionToolsIsAvailableOverBusyPickerAndSystemBackReturnsFocusWithoutOpeningProfile() {
        val f = Fixture(); var pickerCompositions = 0
        try {
            compose.setContent { VortXTheme {
                ProfilePickerToolsHost(f.model, isTv = true, diagnosticAdmission = { f.policy.value }, canOpenTree = { false }) {
                    pickerCompositions++; Text("Opening profiles…")
                }
            } }
            compose.onNodeWithText("Opening profiles…").assertIsDisplayed()
            compose.onNodeWithTag("profile-picker-tools").performClick()
            compose.onNodeWithTag("picker-tools-back").assertIsDisplayed()
            compose.onNodeWithTag("picker-tools-diagnostics").assertDoesNotExist()
            compose.onNodeWithText("Repair backup").assertDoesNotExist(); compose.onNodeWithText("Restore backup").assertDoesNotExist()
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            compose.waitForIdle()
            compose.onNodeWithTag("profile-picker-tools").assertIsDisplayed().assertIsFocused()
            compose.onNodeWithText("Opening profiles…").assertIsDisplayed()
            assertEquals(0, f.accounts.gets); assertTrue(pickerCompositions > 0)
        } finally { f.close() }
    }
    @Test fun unavailableSafActivityUsesFixedExplanationAndDoesNotAttemptAnotherDownload() {
        val f = Fixture()
        try {
            compose.setContent { VortXTheme {
                ProfilePickerToolsHost(f.model, isTv = true, diagnosticAdmission = { f.policy.value }, canOpenTree = { false }) {}
            } }
            compose.onNodeWithTag("profile-picker-tools").performClick()
            compose.onNodeWithTag("picker-tools-download").performClick()
            compose.waitUntil { f.controller.state.value.phase == PickerToolsPhase.AWAITING_DESTINATION }
            compose.onNodeWithTag("picker-tools-destination").performScrollTo().performClick()
            compose.waitUntil { f.controller.state.value.phase == PickerToolsPhase.IDLE }
            compose.onNodeWithText(PickerToolsFailure.NO_FILE_PROVIDER.message).performScrollTo().assertIsDisplayed()
            assertEquals(1, f.accounts.gets)
        } finally { f.close() }
    }
    @Test fun protectedOrUnavailableRosterNeverShowsDiagnosticExportInPhoneTools() {
        val f = Fixture()
        try {
            compose.setContent { VortXTheme {
                ProfilePickerToolsHost(f.model, isTv = false, diagnosticAdmission = { f.policy.value }, canOpenTree = { false }) {}
            } }
            compose.onNodeWithTag("profile-picker-tools").performClick()
            compose.onNodeWithTag("picker-tools-diagnostics").assertDoesNotExist()
            compose.runOnIdle { f.policy.value = true }
            compose.onNodeWithTag("picker-tools-diagnostics").assertExists()
            compose.runOnIdle { f.policy.value = false }
            compose.onNodeWithTag("picker-tools-diagnostics").assertDoesNotExist()
            assertEquals(0, f.accounts.gets)
        } finally { f.close() }
    }
}
