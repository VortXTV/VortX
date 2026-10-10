package com.vortx.android.ui.tv

import android.view.KeyEvent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.theme.VortXTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual Compose routes, synthetic durable gateway only. No account, JNI, provider or playback is started. */
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class TvProfilesRouteTest {
    @get:Rule val compose = createComposeRule()
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "M", isOwner = true)
    private val other = UserProfile(name = "A very long profile name that must fit a short television viewport without hiding Save", avatar = "K", isKids = true)

    private fun enter(tag: String) {
        // Scroll the lazy parent before looking up an off-screen virtual child such as Save.
        val listTag = when {
            compose.onAllNodesWithTag("tv-profile-editor-list").fetchSemanticsNodes().isNotEmpty() -> "tv-profile-editor-list"
            compose.onAllNodesWithTag("tv-profile-list").fetchSemanticsNodes().isNotEmpty() -> "tv-profile-list"
            else -> null
        }
        if (listTag != null) compose.onNodeWithTag(listTag).performScrollToNode(hasTestTag(tag))
        else if (tag.startsWith("tv-picker-")) compose.onNodeWithTag(tag).performScrollTo()
        compose.onNodeWithTag(tag).performSemanticsAction(SemanticsActions.RequestFocus)
            .performKeyInput { pressKey(Key.Enter) }
        compose.waitForIdle()
    }

    private fun back() {
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitForIdle()
    }

    private fun management(gateway: FixtureGateway, active: String = owner.id) {
        gateway.active = active
        compose.setContent { VortXTheme { Box(Modifier.width(720.dp).height(360.dp)) { TvProfileManagement(gateway, onBack = {}) } } }
        compose.waitForIdle()
    }

    @Test fun activeEditSaveReadsBackAndPreservesOtherProfileHistory() {
        val gateway = FixtureGateway(listOf(owner, other))
        val otherHistory = gateway.history.getValue(other.id)
        val otherLibrary = gateway.library.getValue(other.id)
        management(gateway)
        enter("tv-profile-${owner.id}")
        compose.onNodeWithTag("tv-profile-name").performTextReplacement("Main renamed")
        enter("tv-profile-save")
        assertEquals("Main renamed", gateway.reload().profiles.single { it.id == owner.id }.name)
        assertEquals(otherHistory, gateway.history.getValue(other.id))
        assertEquals(otherLibrary, gateway.library.getValue(other.id))
        assertTrue(gateway.history.getValue(owner.id).isNotEmpty())
        compose.onNodeWithTag("tv-profile-${owner.id}").assertIsFocused()
    }

    @Test fun pickerAddPersistsReloadsAndBackReturnsFocusToAdd() {
        val gateway = FixtureGateway(listOf(owner, other))
        compose.setContent { VortXTheme { TvProfilePicker(gateway, onDone = {}) } }
        enter("tv-picker-add")
        compose.onNodeWithTag("tv-profile-name").performTextReplacement("New viewer")
        enter("tv-profile-save")
        assertEquals(3, gateway.reload().profiles.size)
        assertEquals("New viewer", gateway.reload().profiles.last().name)
        compose.onNodeWithTag("tv-picker-add").assertIsFocused()
        enter("tv-picker-add")
        back()
        compose.onNodeWithTag("tv-picker-add").assertIsFocused()
        assertEquals(3, gateway.reload().profiles.size)
    }

    @Test fun permittedDeleteConfirmsThroughGatewayAndDoesNotTouchPeerHistory() {
        val gateway = FixtureGateway(listOf(owner, other))
        val ownerHistory = gateway.history.getValue(owner.id)
        management(gateway, other.id)
        enter("tv-profile-${other.id}")
        enter("tv-profile-delete")
        // Back from the confirmation restores the actual invoking Delete control.
        back()
        compose.onNodeWithTag("tv-profile-delete").assertIsFocused()
        enter("tv-profile-delete")
        enter("tv-profile-confirm-delete")
        assertEquals(listOf(owner.id), gateway.reload().profiles.map { it.id })
        assertTrue(other.id in gateway.tombstones)
        assertEquals(ownerHistory, gateway.history.getValue(owner.id))
        compose.onNodeWithTag("tv-profile-${owner.id}").assertIsFocused()
    }

    @Test fun ownerAndLastProfileCannotBeDeleted() {
        val gateway = FixtureGateway(listOf(owner))
        management(gateway)
        enter("tv-profile-${owner.id}")
        compose.onNodeWithTag("tv-profile-delete").assertDoesNotExist()
        compose.onNodeWithTag("tv-profile-editor-list").performScrollToNode(hasText("The main or last profile cannot be deleted."))
        compose.onNodeWithText("The main or last profile cannot be deleted.").assertIsDisplayed()
        assertTrue(gateway.tombstones.isEmpty())
    }

    @Test fun lastNonOwnerProfileCannotBeDeleted() {
        val gateway = FixtureGateway(listOf(other))
        management(gateway, other.id)
        enter("tv-profile-${other.id}")
        compose.onNodeWithTag("tv-profile-delete").assertDoesNotExist()
        assertTrue(gateway.tombstones.isEmpty())
    }

    @Test fun lockedInactiveProfileRequiresExactPinBeforeItCanBeEdited() {
        val locked = other.copy(pin = UserProfile.pinHash("1234", other.id))
        val gateway = FixtureGateway(listOf(owner, locked))
        management(gateway)
        enter("tv-profile-${locked.id}")
        assertEquals(owner.id, gateway.active)
        compose.onNodeWithText("0").performSemanticsAction(SemanticsActions.RequestFocus).performKeyInput {
            repeat(4) { pressKey(Key.Enter) }
        }
        compose.onNodeWithText("Unlock").performSemanticsAction(SemanticsActions.RequestFocus).performKeyInput { pressKey(Key.Enter) }
        compose.waitForIdle()
        assertEquals(owner.id, gateway.active)
        compose.onNodeWithText("Wrong PIN").assertIsDisplayed()
        back()
        compose.onNodeWithTag("tv-profile-${locked.id}").assertIsFocused()
        enter("tv-profile-${locked.id}")
        // Real D-pad movement from the focused first keypad key enters 1, 2, 3, then 4.
        compose.onNodeWithText("1").performKeyInput {
            pressKey(Key.Enter); pressKey(Key.DirectionRight); pressKey(Key.Enter)
            pressKey(Key.DirectionRight); pressKey(Key.Enter)
            pressKey(Key.DirectionLeft); pressKey(Key.DirectionLeft); pressKey(Key.DirectionDown); pressKey(Key.Enter)
        }
        compose.onNodeWithText("Unlock").performSemanticsAction(SemanticsActions.RequestFocus).performKeyInput { pressKey(Key.Enter) }
        compose.waitForIdle()
        assertEquals(locked.id, gateway.active)
        enter("tv-profile-${locked.id}")
        compose.onNodeWithTag("tv-profile-name").assertIsDisplayed()
    }

    @Test fun staleAdmissionCannotSaveAndBackRestoresProfileFocus() {
        val gateway = FixtureGateway(listOf(owner, other))
        management(gateway)
        enter("tv-profile-${owner.id}")
        compose.onNodeWithTag("tv-profile-name").performTextReplacement("Rejected stale edit")
        gateway.revision++
        enter("tv-profile-save")
        assertEquals("Main", gateway.reload().profiles.first().name)
        compose.onNodeWithTag("tv-profile-editor-list").performScrollToNode(hasText("Changes could not be confirmed. Reopen this profile before trying again."))
        compose.onNodeWithText("Changes could not be confirmed. Reopen this profile before trying again.").assertIsDisplayed()
        back()
        compose.onNodeWithTag("tv-profile-${owner.id}").assertIsFocused()
    }

    @Test fun settingsProfilesRouteBackRestoresTheInvokingEntry() {
        compose.setContent { VortXTheme { TvSettingsScreen(repo = PreviewCatalogRepository()) } }
        compose.onNodeWithText("Profiles").performScrollTo().performSemanticsAction(SemanticsActions.RequestFocus)
            .performKeyInput { pressKey(Key.Enter) }
        compose.waitForIdle()
        back()
        compose.onNodeWithText("Profiles").assertIsFocused()
    }

    private class FixtureGateway(initial: List<UserProfile>) : TvProfileGateway {
        private var encoded = UserProfile.encodeRoster(initial)
        var active = initial.first().id
        var revision = 0
        val history = initial.associate { it.id to listOf("history-${it.id}") }.toMutableMap()
        val library = initial.associate { it.id to listOf("library-${it.id}") }
        val tombstones = mutableSetOf<String>()
        fun reload() = TvProfileGateway.Snapshot(checkNotNull(UserProfile.decodeRoster(encoded)), active)
        override fun read() = reload()
        override fun capture(profile: UserProfile, adding: Boolean, selection: Boolean): TvProfileGateway.Admission? {
            val before = read(); val version = revision
            if (!selection && !adding && before.activeID != profile.id) return null
            if (if (adding) before.profiles.any { it.id == profile.id } else before.profiles.none { it == profile }) return null
            return TvProfileGateway.Admission { action ->
                if (version != revision || active != before.activeID) false else runCatching { action(); true }.getOrDefault(false)
            }
        }
        override fun select(profile: UserProfile, admission: TvProfileGateway.Admission): String? =
            if (admission.commit { active = profile.id; revision++ }) null else "Profile changed"
        override fun save(profile: UserProfile, adding: Boolean, admission: TvProfileGateway.Admission): Boolean = admission.commit {
            encoded = UserProfile.encodeRoster(if (adding) read().profiles + profile else read().profiles.map { if (it.id == profile.id) profile else it })
            revision++
        }
        override fun remove(profile: UserProfile, admission: TvProfileGateway.Admission): Boolean = admission.commit {
            check(!profile.isOwner && read().profiles.size > 1)
            val retained = read().profiles.filter { it.id != profile.id }
            tombstones += profile.id; encoded = UserProfile.encodeRoster(retained)
            if (active == profile.id) active = retained.first().id
            revision++
        }
    }
}
