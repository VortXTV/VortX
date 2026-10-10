package com.vortx.android.ui.tv

import android.view.KeyEvent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertDoesNotExist
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vortx.android.profile.ProfileSelectionRequest
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.theme.VortXTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Focused launch-picker route coverage for the active-profile PIN fence. */
@RunWith(AndroidJUnit4::class)
class TvWhosWatchingPickerRouteTest {
    @get:Rule val compose = createComposeRule()

    private val owner = UserProfile(
        id = UserProfile.OWNER_ID,
        name = "Main",
        avatar = "M",
        isOwner = true,
        pin = UserProfile.pinHash("1234", UserProfile.OWNER_ID),
    )

    private fun show(gateway: PickerGateway) {
        compose.setContent {
            VortXTheme {
                Box(Modifier.width(1280.dp).height(720.dp)) {
                    TvProfilePicker(gateway, onDone = {})
                }
            }
        }
        compose.waitForIdle()
    }

    private fun enter(tag: String) {
        compose.onNodeWithTag(tag)
            .performSemanticsAction(SemanticsActions.RequestFocus)
            .performKeyInput { pressKey(Key.Enter) }
        compose.waitForIdle()
    }

    private fun unlockWith1234() {
        compose.onNodeWithText("1")
            .performSemanticsAction(SemanticsActions.RequestFocus)
            .performKeyInput { pressKey(Key.Enter) }
        compose.onNodeWithText("2")
            .performSemanticsAction(SemanticsActions.RequestFocus)
            .performKeyInput { pressKey(Key.Enter) }
        compose.onNodeWithText("3")
            .performSemanticsAction(SemanticsActions.RequestFocus)
            .performKeyInput { pressKey(Key.Enter) }
        compose.onNodeWithText("4")
            .performSemanticsAction(SemanticsActions.RequestFocus)
            .performKeyInput { pressKey(Key.Enter) }
        compose.onNodeWithText("Unlock")
            .performSemanticsAction(SemanticsActions.RequestFocus)
            .performKeyInput { pressKey(Key.Enter) }
        compose.waitForIdle()
    }

    private fun back() {
        androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitForIdle()
    }

    @Test
    fun lockedActiveEditRequiresPinBeforeEditor() {
        val gateway = PickerGateway(owner)
        show(gateway)

        enter("tv-picker-edit")
        compose.onNodeWithText("Enter PIN for Main").assertIsDisplayed()
        compose.onNodeWithTag("tv-profile-name").assertDoesNotExist()
        assertEquals(0, gateway.editorCaptureCalls)
        assertEquals(1, gateway.selectionAdmissionCaptureCalls)

        unlockWith1234()
        compose.onNodeWithTag("tv-profile-name").assertIsDisplayed()
        assertTrue(gateway.editorCaptureCalls >= 2)
    }

    @Test
    fun lockedActiveEditCancelRestoresEditFocusWithoutOpeningEditor() {
        val gateway = PickerGateway(owner)
        show(gateway)

        enter("tv-picker-edit")
        back()

        compose.onNodeWithTag("tv-picker-edit").assertIsFocused()
        compose.onNodeWithTag("tv-profile-name").assertDoesNotExist()
        assertEquals(0, gateway.editorCaptureCalls)
    }

    @Test
    fun activeEditUnlockRejectsProfileReplacedWhilePinWasOpen() {
        val gateway = PickerGateway(owner)
        show(gateway)

        enter("tv-picker-edit")
        gateway.replaceActive(owner.copy(name = "Replacement"))
        unlockWith1234()

        compose.onNodeWithText("The active profile changed. Open Edit again.").assertIsDisplayed()
        compose.onNodeWithTag("tv-profile-name").assertDoesNotExist()
        assertEquals(0, gateway.editorCaptureCalls)
    }

    @Test
    fun activeEditUnlockRejectsSameValueRosterReplacementWhilePinWasOpen() {
        val gateway = PickerGateway(owner)
        show(gateway)

        enter("tv-picker-edit")
        gateway.replaceRosterSameValue()
        unlockWith1234()

        compose.onNodeWithText("The active profile changed. Open Edit again.").assertIsDisplayed()
        compose.onNodeWithTag("tv-profile-name").assertDoesNotExist()
        assertEquals(0, gateway.editorCaptureCalls)
    }

    @Test
    fun lockedActiveBackCancelRestoresActiveFocusWithoutSelection() {
        val gateway = PickerGateway(owner)
        show(gateway)

        back()
        compose.onNodeWithText("Enter PIN for Main").assertIsDisplayed()
        back()

        compose.onNodeWithTag("tv-picker-${owner.id}").assertIsFocused()
        assertTrue(gateway.selectedIDs.isEmpty())
    }

    @Test
    fun lockedActiveBackRequiresPinAndUnlockAttemptsSelection() {
        val gateway = PickerGateway(owner)
        show(gateway)

        back()
        compose.onNodeWithText("Enter PIN for Main").assertIsDisplayed()
        unlockWith1234()

        assertEquals(listOf(owner.id), gateway.selectedIDs)
    }

    private class PickerGateway(initial: UserProfile) : TvProfileGateway {
        private var profiles = listOf(initial)
        private var active = initial.id
        private var admissionGeneration = 0
        var editorCaptureCalls = 0
        var selectionAdmissionCaptureCalls = 0
        val selectedIDs = mutableListOf<String>()

        fun replaceActive(replacement: UserProfile) {
            profiles = listOf(replacement)
            active = replacement.id
            admissionGeneration++
        }

        fun replaceRosterSameValue() {
            profiles = profiles.toList()
            admissionGeneration++
        }

        override fun read(): TvProfileGateway.Snapshot = TvProfileGateway.Snapshot(profiles, active)

        override fun capture(
            profile: UserProfile,
            adding: Boolean,
            selection: Boolean,
        ): TvProfileGateway.Admission? {
            if (selection) selectionAdmissionCaptureCalls++ else editorCaptureCalls++
            val before = read()
            val beforeGeneration = admissionGeneration
            if ((!selection && !adding && before.activeID != profile.id) ||
                (if (adding) before.profiles.any { it.id == profile.id } else before.profiles.none { it == profile })
            ) return null
            return TvProfileGateway.Admission {
                runCatching {
                    check(admissionGeneration == beforeGeneration)
                    check(read().activeID == before.activeID)
                    action()
                    true
                }.getOrDefault(false)
            }
        }

        override fun select(
            profile: UserProfile,
            admission: TvProfileGateway.Admission,
        ): Result<ProfileSelectionRequest> {
            val committed = admission.commit {
                active = profile.id
                selectedIDs += profile.id
            }
            return if (committed) {
                // Selection is intentionally not accepted by this fixture; the route must still prove that
                // the PIN gate reached the typed gateway boundary without self-dismissing on failure.
                Result.failure(IllegalStateException("test selection result"))
            } else {
                Result.failure(IllegalStateException("stale test admission"))
            }
        }

        override fun save(
            profile: UserProfile,
            adding: Boolean,
            admission: TvProfileGateway.Admission,
        ): Boolean = admission.commit {
            profiles = if (adding) profiles + profile else profiles.map { if (it.id == profile.id) profile else it }
        }

        override fun remove(profile: UserProfile, admission: TvProfileGateway.Admission): Boolean = admission.commit {
            profiles = profiles.filterNot { it.id == profile.id }
            if (active == profile.id) active = profiles.firstOrNull()?.id.orEmpty()
        }
    }
}
