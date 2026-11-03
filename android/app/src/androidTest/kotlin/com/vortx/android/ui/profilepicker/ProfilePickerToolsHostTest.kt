package com.vortx.android.ui.profilepicker

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertDoesNotExist
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.core.app.ActivityOptionsCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vortx.android.sync.AccountFileRestoreExternalExclusion
import com.vortx.android.sync.AccountFileRestoreTransaction
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.PickerToolsModelHolder
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
import java.util.UUID

/** Production host/controller with synthetic download/preparation. No provider, account or network I/O.
 * System Back/focus and absent-SAF UI are bounded instrumentation coverage only, authored but unrun. */
@RunWith(AndroidJUnit4::class)
class ProfilePickerToolsHostTest {
    @get:Rule val compose = createComposeRule()
    private class Accounts(private val signedIn: Boolean) : PickerToolsAccounts {
        private val issuer = Any(); private val session = Any()
        private val account = VortXSyncManager.Account("10000000-0000-0000-0000-000000000001", "fixture@example.invalid", "Fixture", false)
        override val authorityRevision = 0L
        override val sessionMarker: Any = Unit
        override val changes = flowOf(Unit)
        override fun capture() = PickerAccountSnapshot(issuer, 0, 0, 1, session.takeIf { signedIn }, account.takeIf { signedIn })
        override fun isCurrent(original: PickerAccountSnapshot) = original.matchesAuthority(issuer, 0, 0) && original.matchesOwner(issuer, 1, session.takeIf { signedIn })
        var gets = 0
        override suspend fun download(original: PickerAccountSnapshot): ByteArray { gets++; return byteArrayOf(1, 2, 3) }
    }
    private class Fixture(restore: PickerToolsRestoreActions? = null, signedIn: Boolean = true) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val accounts = Accounts(signedIn)
        val policy = mutableStateOf(false)
        val controller = ProfilePickerToolsController(accounts, PickerToolsBackupPreparer { _, current ->
            check(current())
            object : PickerToolsPreparedBackup {
                override val byteCount = 3; override val sha256 = "fixture-only"; override fun close() = Unit
            }
        }, scope, restoreActions = restore)
        val model = ProfilePickerToolsViewModel(controller)
        fun close() { controller.close(); scope.cancel() }
    }
    private class RestoreActions : PickerToolsRestoreActions {
        override fun canSelect(original: PickerToolsActionGrant) = true
        var reads = 0
        var confirms = 0
        var closes = 0
        override suspend fun status(original: PickerToolsActionGrant, isCurrent: () -> Boolean) =
            VortXSyncManager.FileRestoreStatus.Missing
        override suspend fun read(original: PickerToolsActionGrant, input: PickerToolsRestoreInput,
            isCurrent: () -> Boolean): PickerToolsRestoreCandidate {
            assertTrue(isCurrent())
            assertEquals("SafRestoreInput", input.toString())
            reads++
            return object : PickerToolsRestoreCandidate {
                override val byteCount = 27
                override suspend fun confirm(): AccountFileRestoreTransaction.Result {
                    confirms++
                    return AccountFileRestoreTransaction.Result.NotSubmitted(AccountFileRestoreTransaction.Reason.UNSUPPORTED_FILE)
                }
                override fun close() { closes++ }
            }
        }
        override suspend fun verify(original: PickerToolsActionGrant, operationId: UUID, isCurrent: () -> Boolean):
            AccountFileRestoreTransaction.Result = error("unexpected verify")
    }

    private class RestoreRegistry(private val fail: Boolean = false) : ActivityResultRegistry(), ActivityResultRegistryOwner {
        override val activityResultRegistry: ActivityResultRegistry get() = this
        val launches = mutableListOf<Int>()
        override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I,
            options: ActivityOptionsCompat?) {
            assertTrue(contract is androidx.activity.result.contract.ActivityResultContracts.OpenDocument)
            assertArrayEquals(arrayOf("application/json", "application/octet-stream", "text/plain"), input as Array<*>)
            launches += requestCode
            if (fail) throw ActivityNotFoundException("synthetic absent document handler")
        }
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

    @Test fun restoreMissingSafActivityShowsSafeRefusalWithoutReading() {
        val actions = RestoreActions()
        val registry = RestoreRegistry(fail = true)
        val f = Fixture(actions)
        try {
            compose.setContent { CompositionLocalProvider(LocalActivityResultRegistryOwner provides registry) {
                VortXTheme { ProfilePickerToolsHost(f.model, isTv = false, diagnosticAdmission = { false }) {} }
            } }
            compose.onNodeWithTag("profile-picker-tools").performClick()
            compose.onNodeWithTag("picker-tools-restore").performScrollTo().performClick()
            compose.onNodeWithTag("picker-tools-restore-input").performScrollTo().performClick()
            compose.onNodeWithText(PickerToolsFailure.NO_FILE_PROVIDER.message).performScrollTo().assertIsDisplayed()
            assertEquals(1, registry.launches.size)
            assertEquals(0, actions.reads)
            assertEquals(0, actions.confirms)
            assertEquals(0, f.accounts.gets)
        } finally { f.close() }
    }

    @Test fun restoredRegistryReRegistersOriginalOpenDocumentAndOnlyExplicitDecisionSubmits() {
        val actions = RestoreActions()
        val original = RestoreRegistry()
        val activeRegistry = mutableStateOf(original)
        val f = Fixture(actions)
        try {
            compose.setContent { CompositionLocalProvider(LocalActivityResultRegistryOwner provides activeRegistry.value) {
                VortXTheme { ProfilePickerToolsHost(f.model, isTv = false, diagnosticAdmission = { false }) {} }
            } }
            compose.onNodeWithTag("profile-picker-tools").performClick()
            compose.onNodeWithTag("picker-tools-restore").performScrollTo().performClick()
            compose.onNodeWithTag("picker-tools-restore-input").performScrollTo().performClick()
            val request = checkNotNull(f.controller.state.value.restoreInput)
            val restored = RestoreRegistry()
            val requestCode = original.launches.single()
            compose.runOnIdle {
                val saved = Bundle().also { original.onSaveInstanceState(it) }
                restored.onRestoreInstanceState(saved)
                activeRegistry.value = restored
            }
            compose.onNodeWithTag("picker-tools-restore-input").performScrollTo().performClick()
            assertTrue(restored.launches.isEmpty())
            compose.runOnIdle {
                val result = Intent().setData(Uri.parse("content://fixture.invalid/selected-backup"))
                assertTrue(restored.dispatchResult(requestCode, Activity.RESULT_OK, result))
            }
            compose.onNodeWithTag("picker-tools-restore-confirm").performScrollTo().assertIsDisplayed()
            assertEquals(request, f.controller.state.value.restoreReview?.request)
            assertEquals(1, actions.reads)
            assertEquals(0, actions.confirms)
            compose.onNodeWithTag("picker-tools-restore-confirm").performClick()
            compose.onNodeWithText("This restore was not submitted.").performScrollTo().assertIsDisplayed()
            assertEquals(1, actions.confirms)
            assertEquals(1, actions.closes)
            assertEquals(0, f.accounts.gets)
        } finally { f.close() }
    }

    @Test fun signedOutToolsShowsOnlyExplicitRecoverySignInForRestoreEntry() {
        val f = Fixture(RestoreActions(), signedIn = false)
        var opened = 0
        try {
            compose.setContent { VortXTheme {
                ProfilePickerToolsHost(f.model, isTv = false, diagnosticAdmission = { false },
                    openRecoverySignIn = { original -> assertNull(original.account); opened++; true }) {}
            } }
            compose.onNodeWithTag("profile-picker-tools").performClick()
            compose.onNodeWithTag("picker-tools-restore").assertDoesNotExist()
            compose.onNodeWithTag("picker-tools-restore-verify").assertDoesNotExist()
            compose.onNodeWithTag("picker-tools-recovery-sign-in").performScrollTo().performClick()
            compose.waitUntil { opened == 1 }
            assertEquals(1, opened)
            assertEquals(0, f.accounts.gets)
        } finally { f.close() }
    }

    @Test fun twoActualActivityModelHoldersShareOneManagerRecoveryGateEvenAfterDelegateRemoval() {
        val instrumentation = InstrumentationRegistry.getInstrumentation().context
        val prefix = "picker-recovery-holder-${UUID.randomUUID()}-"
        val context = object : ContextWrapper(instrumentation) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int) =
                instrumentation.getSharedPreferences(prefix + name, mode)
        }
        val managerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val manager = VortXSyncManager(context, managerScope)
        val phone = PickerToolsModelHolder()
        val tv = PickerToolsModelHolder()
        try {
            // A nominal test collaborator that must never run. No account or provider operation is initiated.
            val external = AccountFileRestoreExternalExclusion { _, _, _ -> throw AssertionError("unexpected exclusion") }
            compose.runOnIdle {
                val a = phone.model(manager = manager, applicationContext = context, externalRestore = external)
                val b = tv.model(manager = manager, applicationContext = context, externalRestore = external)
                assertNotSame(a.controller, b.controller)
                assertTrue(a.controller.restoreAvailable)
                assertTrue(b.controller.restoreAvailable)
                assertSame(a.controller.recoveryBusy, b.controller.recoveryBusy)
                val successor = tv.model(manager = manager, applicationContext = context)
                assertNotSame(b.controller, successor.controller)
                assertFalse(successor.controller.restoreAvailable)
                assertSame(a.controller.recoveryBusy, successor.controller.recoveryBusy)
            }
        } finally {
            compose.runOnIdle { phone.model(null, context); tv.model(null, context) }
            managerScope.cancel()
        }
    }
}
